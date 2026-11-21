// git-cross — crossed directories (gitdir patches since v0.5.0).
//
// Architecture (see specs/003-gitdir-patches/plan.md):
//
//	.cross/worktrees/<remote>/<local_path_underscored>/   standalone BARE gitdir
//	  (the ".git content": objects, refs, remotes, sparse config, rerere)
//	<local_path>/                                        THE CROSS: plain files
//	  inside the primary repo, tracked by the primary as normal blobs.
//
// No rsync, no linked git worktrees, no remotes in the primary repo.
// Upstream git operations run through GIT_DIR/GIT_WORK_TREE (the passthrough):
//
//	git cross <git-args...>              inside a crossed directory
//	                                     (unknown subcommands fall through);
//	git cross wt [path]                   alias of cd (not the passthrough)
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"unicode/utf8"

	"github.com/fatih/color"
	"github.com/olekukonko/tablewriter"
	"github.com/spf13/cobra"
)

const (
	MetadataRelPath  = ".cross/metadata.json"
	CrossfileRelPath = "Crossfile"
	GitdirRoot       = ".cross/worktrees"
)

// crossVersion is the single source of truth for the binary version: shown by
// `git cross --version` and printed once in the update summary whenever a
// cross was skipped, so stale-binary situations (raw git errors where a
// friendly gate should be) are self-diagnosing.
const crossVersion = "0.6.1"

// crossEnvLoaded reports whether this shell carries git-cross's own upstream
// context, i.e. `eval "$(git cross env)"` / the gxenv wrapper loaded GIT_DIR
// pointing into the .cross/worktrees/ mirror area. Such a GIT_DIR must be
// IGNORED when git-cross looks for the PRIMARY repo: with it set, git's
// `--show-toplevel` answers the crossed dir and every git-cross command would
// lose the registry (which lives in the primary repo).
func crossEnvLoaded() bool {
	gd := strings.TrimSpace(os.Getenv("GIT_DIR"))
	if gd == "" {
		return false
	}
	if !filepath.IsAbs(gd) {
		if abs, err := filepath.Abs(gd); err == nil {
			gd = abs
		}
	}
	gd = filepath.ToSlash(filepath.Clean(gd))
	return strings.Contains(gd, "/"+GitdirRoot+"/") || strings.HasSuffix(gd, "/"+GitdirRoot)
}

// gitEnvWithoutCross returns the environment minus a loaded cross context, for
// child git processes that must see the PRIMARY repo.
func gitEnvWithoutCross() []string {
	env := make([]string, 0, len(os.Environ()))
	for _, kv := range os.Environ() {
		name, _, _ := strings.Cut(kv, "=")
		switch name {
		case "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_PREFIX":
			continue
		}
		env = append(env, kv)
	}
	return env
}

func getRepoRoot() (string, error) {
	c := exec.Command("git", "rev-parse", "--show-toplevel")
	if crossEnvLoaded() {
		c.Env = gitEnvWithoutCross()
	}
	out, err := c.Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

func getMetadataPath() (string, error) {
	root, err := getRepoRoot()
	if err != nil {
		return "", err
	}
	return filepath.Join(root, MetadataRelPath), nil
}

func getCrossfilePath() (string, error) {
	root, err := getRepoRoot()
	if err != nil {
		return "", err
	}
	return filepath.Join(root, CrossfileRelPath), nil
}

// ------------------------------------------------------------------ model ---

type RemoteEntry struct {
	Name string `json:"name"`
	URL  string `json:"url"`
}

type Patch struct {
	Remote     string `json:"remote"`
	RemoteURL  string `json:"remote_url"`
	RemotePath string `json:"remote_path"`
	LocalPath  string `json:"local_path"`
	Worktree   string `json:"worktree"`
	Gitdir     string `json:"gitdir"`
	Branch     string `json:"branch"`
}

type Metadata struct {
	Remotes []RemoteEntry `json:"remotes"`
	Patches []Patch       `json:"patches"`
}

type patchSpec struct {
	Remote         string
	RemotePath     string
	Branch         string
	BranchProvided bool
}

func parsePatchSpec(spec string) (patchSpec, error) {
	parts := strings.Split(spec, ":")
	if len(parts) < 2 {
		return patchSpec{}, fmt.Errorf("invalid spec. Use remote[:branch]:remote_path")
	}

	remote := parts[0]
	remotePath := parts[len(parts)-1]
	branch := ""
	branchProvided := false

	switch len(parts) {
	case 2:
		// remote:path
	case 3:
		branch = parts[1]
		branchProvided = branch != ""
	default:
		branch = parts[1]
		branchProvided = branch != ""
		remotePath = strings.Join(parts[2:], ":")
	}

	remotePath = strings.TrimPrefix(remotePath, "/")
	remotePath = strings.TrimSuffix(remotePath, "/")
	for _, component := range strings.Split(remotePath, "/") {
		if component == ".." {
			return patchSpec{}, fmt.Errorf("remote path must not traverse outside the repository")
		}
	}
	// Treat empty path (from "/") as "." meaning whole repo root
	if remotePath == "" {
		remotePath = "."
	}

	return patchSpec{
		Remote:         remote,
		RemotePath:     remotePath,
		Branch:         branch,
		BranchProvided: branchProvided,
	}, nil
}

func canonicalSpec(spec patchSpec) string {
	if spec.Branch != "" {
		return fmt.Sprintf("%s:%s:%s", spec.Remote, spec.Branch, spec.RemotePath)
	}
	return fmt.Sprintf("%s:%s", spec.Remote, spec.RemotePath)
}

// patchGitdir returns the repo-relative gitdir path:
// .cross/worktrees/<remote>/<local_path with slashes replaced by underscores>.
func patchGitdir(remote, localPath string) string {
	lp := strings.ReplaceAll(strings.TrimPrefix(localPath, "./"), "/", "_")
	return GitdirRoot + "/" + remote + "/" + lp
}

func (p *Patch) gitdirAbs(root string) string {
	return filepath.Join(root, filepath.FromSlash(p.Gitdir))
}

// worktreePath is the repo-relative patch directory (the work tree git operates
// on). ADR-001: it is stored explicitly and equals local_path in v0.5.0; older
// metadata files without the field fall back to local_path.
func (p *Patch) worktreePath() string {
	if strings.TrimSpace(p.Worktree) != "" {
		return p.Worktree
	}
	return p.LocalPath
}

func (p *Patch) localAbs(root string) string {
	return filepath.Join(root, filepath.FromSlash(p.worktreePath()))
}

// remoteURL resolves a remote name to its URL from metadata remotes.
func remoteURL(meta Metadata, name string) string {
	for _, r := range meta.Remotes {
		if r.Name == name {
			return r.URL
		}
	}
	return ""
}

func upsertRemote(meta *Metadata, name, url string) {
	out := meta.Remotes[:0]
	for _, r := range meta.Remotes {
		if r.Name != name {
			out = append(out, r)
		}
	}
	meta.Remotes = append(out, RemoteEntry{Name: name, URL: url})
	sort.Slice(meta.Remotes, func(i, j int) bool { return meta.Remotes[i].Name < meta.Remotes[j].Name })
}

// ------------------------------------------------------------- git helpers ---

// runPatchGit builds a git command operating on a patch's upstream context:
// GIT_DIR = the patch gitdir, GIT_WORK_TREE = the patch directory.
func runPatchGit(root string, p *Patch, args ...string) *exec.Cmd {
	c := exec.Command("git", args...)
	c.Dir = root
	c.Env = append(os.Environ(),
		"GIT_DIR="+p.gitdirAbs(root),
		"GIT_WORK_TREE="+p.localAbs(root),
	)
	return c
}

// runGitdir builds a git command against a bare gitdir (--git-dir form).
func runGitdir(gdAbs string, args ...string) *exec.Cmd {
	c := exec.Command("git", append([]string{"--git-dir", gdAbs}, args...)...)
	return c
}

// patchWorktreeDirty reports whether the patch directory has modifications to
// TRACKED files. Untracked files are ignored on purpose: local-only files next
// to upstream content are a supported workflow and must not block an update.
func patchWorktreeDirty(root string, p *Patch) (bool, error) {
	// The PATCH DIR is the user's repo content (ADR-003): ask the user's repo, not
	// the mirror, whose index is only used when the work tree is first created.
	// Only UNSTAGED changes are dangerous: a cherry-pick merges into the index, so
	// staged content (e.g. files freshly added by `patch`) is never lost.
	cmd := exec.Command("git", "-C", root, "diff", "--quiet", "--", p.worktreePath())
	err := cmd.Run()
	if err == nil {
		return false, nil
	}
	if exit, ok := err.(*exec.ExitError); ok && exit.ExitCode() == 1 {
		return true, nil
	}
	return false, err
}

// landResult is the outcome of applying one upstream delta to a patch directory.
type landResult int

const (
	landFailed landResult = iota
	landUpdated
	landUptodate
	landDirty
	landPending
	landConflict
	landUntracked
)

// patchUntrackedCollisions lists UNTRACKED files under the crossed dir that the
// incoming delta would overwrite. Purely local untracked files are a supported
// workflow (see patchWorktreeDirty) and never appear here: only paths present
// in the BASE->THEIRS delta collide — the exact set git's cherry-pick would
// refuse to overwrite, reported here with guidance BEFORE any work begins,
// instead of a raw "would be overwritten by merge" after the fetch/import.
// The untracked listing uses `git ls-files -o --exclude-standard`, NOT
// `git status`: status honors status.showUntrackedFiles=no and goes silently
// blind (user-reported on 0.6.1), and it collapses whole untracked dirs.
// ls-files lists repo-relative FILE paths directly — including files shadowed
// by an uncommitted staged deletion (in HEAD, dropped from the index) — and
// --exclude-standard skips ignored files, matching git's apply behavior (an
// ignored file is overwritten without complaint). The delta paths are
// tree-relative; both sides are prefixed with the canonicalized worktree
// path (no "./" forms) before comparing.
func patchUntrackedCollisions(root string, p *Patch, gdAbs, baseRev, theirsTreeish string) []string {
	wt := filepath.ToSlash(filepath.Clean(p.worktreePath()))
	prefix := wt + "/"
	if wt == "." || wt == "" || wt == "/" {
		prefix = ""
	}
	out, err := exec.Command("git", "-C", root, "ls-files", "-o", "--exclude-standard", "-z",
		"--", filepath.FromSlash(wt)).Output()
	if err != nil {
		return nil
	}
	var untracked []string
	for _, u := range strings.Split(string(out), "\x00") {
		if u = strings.TrimSpace(filepath.ToSlash(u)); u != "" {
			untracked = append(untracked, u)
		}
	}
	if len(untracked) == 0 {
		return nil
	}
	deltaOut, derr := runGitdir(gdAbs, "diff-tree", "--name-only", "--no-commit-id", "-r", baseRev, theirsTreeish).Output()
	if derr != nil {
		return nil // cannot prove a collision: let cherry-pick decide (status quo)
	}
	delta := map[string]bool{}
	for _, f := range strings.Split(string(deltaOut), "\n") {
		if f = strings.TrimSpace(filepath.ToSlash(f)); f != "" {
			delta[prefix+f] = true
		}
	}
	var hit []string
	for _, u := range untracked {
		if delta[u] {
			hit = append(hit, u)
		}
	}
	sort.Strings(hit)
	return hit
}

// patchUnmerged reports the unmerged paths git left under the patch path. This is
// the pending-conflict signal: `cherry-pick -n` does NOT write CHERRY_PICK_HEAD.
func patchUnmerged(root string, p *Patch) []string {
	out, err := exec.Command("git", "-C", root, "ls-files", "-u", "--", p.worktreePath()).Output()
	if err != nil {
		return nil
	}
	seen := map[string]bool{}
	var paths []string
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if line == "" {
			continue
		}
		fields := strings.SplitN(line, "\t", 2)
		if len(fields) != 2 || seen[fields[1]] {
			continue
		}
		seen[fields[1]] = true
		paths = append(paths, fields[1])
	}
	return paths
}

// patchDiffersFromUpstream reports whether the patch directory differs from the
// mirrored upstream HEAD. It compares ONLY the mapped subtree (remote_path) using
// a throwaway index, so the mirror's sparse index — written once, when the work
// tree is created — never has to be kept in sync.
func patchDiffersFromUpstream(root string, p *Patch) (bool, error) {
	idx, err := os.CreateTemp("", "cross-stat-")
	if err != nil {
		return false, err
	}
	idxPath := idx.Name()
	idx.Close()
	os.Remove(idxPath)
	defer os.Remove(idxPath)

	gdAbs := p.gitdirAbs(root)
	env := append(os.Environ(), "GIT_INDEX_FILE="+idxPath)
	readTree := exec.Command("git", "--git-dir="+gdAbs, "read-tree", "HEAD")
	readTree.Env = env
	if err := readTree.Run(); err != nil {
		return false, err
	}
	pathspec := p.RemotePath
	if pathspec == "" || pathspec == "/" {
		pathspec = "."
	}
	// `git diff HEAD` (not diff-index): it refreshes the stat cache of the throwaway
	// index, so fresh read-tree entries are not reported as modified.
	// The mirror is a BARE clone: without --work-tree git refuses the diff
	// ("fatal: this operation must be run in a work tree", exit 128) — a failure
	// that used to be swallowed as "Clean" (v0.5.1 bugfix).
	// D3(c): a subdir cross's HEAD tree already IS the upstream subtree — no
	// pathspec (and no sparse caveat); whole-repo crosses keep the pathspec.
	args := []string{"diff", "--quiet", "HEAD"}
	if pathspec == "." {
		args = append(args, "--", ".")
	}
	check := exec.Command("git", append([]string{"--git-dir=" + gdAbs, "--work-tree=" + p.localAbs(root)}, args...)...)
	check.Env = env
	check.Dir = p.localAbs(root)
	if err := check.Run(); err == nil {
		return false, nil
	} else if exit, ok := err.(*exec.ExitError); ok && exit.ExitCode() == 1 {
		return true, nil
	} else {
		return false, err
	}
}

// upstreamDeltaCommit synthesizes a commit in the USER's repo whose single parent
// holds the mirror tree at baseRev (prefixed with the patch path) and whose tree
// holds the mirror tree at theirsRev. cherry-picking it -n applies exactly the
// upstream delta to the patch directory, path-restricted, without ever writing to
// the mirror and without needing a committer identity.
func upstreamDeltaCommit(root string, p *Patch, baseRev, theirsRev string) (string, error) {
	prefix := filepath.ToSlash(p.worktreePath()) + "/"

	buildTree := func(rev string) (string, error) {
		idx, err := os.CreateTemp("", "cross-idx-")
		if err != nil {
			return "", err
		}
		idxPath := idx.Name()
		idx.Close()
		os.Remove(idxPath) // let git create a fresh index at this path
		defer os.Remove(idxPath)

		cmd := exec.Command("git", "-C", root, "read-tree", "--prefix="+prefix, rev)
		cmd.Env = append(os.Environ(), "GIT_INDEX_FILE="+idxPath)
		cmd.Stderr = os.Stderr
		if err := cmd.Run(); err != nil {
			return "", fmt.Errorf("read-tree %s: %w", rev, err)
		}
		wt := exec.Command("git", "-C", root, "write-tree")
		wt.Env = append(os.Environ(), "GIT_INDEX_FILE="+idxPath)
		out, err := wt.Output()
		if err != nil {
			return "", fmt.Errorf("write-tree %s: %w", rev, err)
		}
		return strings.TrimSpace(string(out)), nil
	}

	baseTree, err := buildTree(baseRev)
	if err != nil {
		return "", err
	}
	theirsTree, err := buildTree(theirsRev)
	if err != nil {
		return "", err
	}
	baseCmd := exec.Command("git", "-C", root, "commit-tree", baseTree, "-m", "cross: upstream base")
	baseCmd.Stderr = os.Stderr
	baseOut, err := baseCmd.Output()
	if err != nil {
		return "", fmt.Errorf("commit-tree base: %w", err)
	}
	deltaCmd := exec.Command("git", "-C", root, "commit-tree", theirsTree, "-p",
		strings.TrimSpace(string(baseOut)), "-m", "cross: upstream delta")
	deltaCmd.Stderr = os.Stderr
	deltaOut, err := deltaCmd.Output()
	if err != nil {
		return "", fmt.Errorf("commit-tree delta: %w", err)
	}
	return strings.TrimSpace(string(deltaOut)), nil
}

// advanceMirror moves the mirror's branch to the landed revision. Called only once
// the patch directory actually reflects that revision, so a re-run never replays
// an already-applied delta.
func advanceMirror(root string, p *Patch, rev string) {
	gdAbs := p.gitdirAbs(root)
	if p.RemotePath != "." && p.RemotePath != "/" {
		// D3(c) (ADR-004): advance to the SYNTHESIZED subtree tip — never the
		// real upstream commit (the two histories are disjoint) — and move the
		// markers. Index refresh below also fixes the v0.5.x stale-index wart
		// where cross-ctx `git status` showed noise after every update.
		// The synthesis builds on the SYNTHESIZED marker (not on the branch:
		// user commits must never end up inside the upstream chain).
		tip, err := synthesizeSubtree(gdAbs, p.RemotePath,
			"refs/remotes/origin/"+p.Branch+" ^"+upstreamRef(p.Branch), synthRef(p.Branch))
		if err != nil {
			logWarn(fmt.Sprintf("could not re-synthesize %s: %v", p.LocalPath, err))
			return
		}
		if tip != "" {
			if err := runGitdir(gdAbs, "update-ref", "refs/heads/"+p.Branch, tip).Run(); err != nil {
				logWarn(fmt.Sprintf("could not advance the subtree branch for %s: %v", p.LocalPath, err))
				return
			}
			_ = runGitdir(gdAbs, "update-ref", synthRef(p.Branch), tip).Run()
		}
		_ = runGitdir(gdAbs, "update-ref", upstreamRef(p.Branch), rev).Run()
	} else if err := runGitdir(gdAbs, "update-ref", "refs/heads/"+p.Branch, rev).Run(); err != nil {
		logWarn(fmt.Sprintf("could not advance the mirror ref for %s: %v", p.LocalPath, err))
		return
	}
	// Refresh the mirror index (index only, no -u: the work tree is the user's
	// dir, already updated by the landed delta).
	_ = runGitdir(gdAbs, "read-tree", "HEAD").Run()
}

// ------------------------------------------------------- subtree (ADR-004) ---

const emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

func synthRef(branch string) string    { return "refs/cross/synthesized/" + branch }
func upstreamRef(branch string) string { return "refs/cross/upstream/" + branch }

// synthesizeSubtree builds (or extends) the re-rooted history of remotePath:
// one synthesized commit per source commit that CHANGES the subtree
// (outside-only commits are skipped), each carrying the subtree tree of the
// source commit, the ORIGINAL message, and the original author+committer
// identity and raw dates — so re-runs are deterministic (identical hashes;
// lab-proven, mirrors `git subtree split` semantics). baseTip is the
// synthesized commit to build on ("" for a full walk); walkRange is a
// rev-list range ("<rev>" or "<rev> ^<rev>"). Returns "" when nothing changed.
func synthesizeSubtree(gdAbs, remotePath, walkRange, baseTip string) (string, error) {
	list := exec.Command("git", append([]string{"--git-dir", gdAbs, "rev-list", "--reverse", "--topo-order"}, strings.Fields(walkRange)...)...)
	out, err := list.Output()
	if err != nil {
		return "", fmt.Errorf("rev-list %s: %w", walkRange, err)
	}
	last := baseTip
	lastT := ""
	if last != "" {
		if o, terr := runGitdir(gdAbs, "rev-parse", last+"^{tree}").Output(); terr == nil {
			lastT = strings.TrimSpace(string(o))
		} else {
			return "", fmt.Errorf("cannot resolve the synthesis base %s", last)
		}
	}
	newTip := ""
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		rev := strings.TrimSpace(line)
		if rev == "" {
			continue
		}
		T := emptyTree
		if o, terr := runGitdir(gdAbs, "rev-parse", "-q", "--verify", rev+":"+remotePath).Output(); terr == nil {
			T = strings.TrimSpace(string(o))
		}
		if T == lastT {
			continue // outside-only change: not part of the subtree history
		}
		// Pin identity+authorship from the source commit (deterministic synthesis).
		id, ierr := runGitdir(gdAbs, "show", "-s", "--format=%an%x00%ae%x00%aD%x00%cn%x00%ce%x00%cD", rev).Output()
		if ierr != nil {
			return "", fmt.Errorf("cannot read the identity of %s: %w", rev, ierr)
		}
		parts := strings.Split(strings.TrimSpace(string(id)), "\x00")
		if len(parts) != 6 {
			return "", fmt.Errorf("unexpected identity format for %s", rev)
		}
		msg, merr := runGitdir(gdAbs, "show", "-s", "--format=%B", rev).Output()
		if merr != nil {
			return "", fmt.Errorf("cannot read the message of %s: %w", rev, merr)
		}
		ct := exec.Command("git", "--git-dir", gdAbs, "commit-tree", T, "-F", "-")
		if last != "" {
			ct.Args = append(ct.Args, "-p", last)
		}
		ct.Env = append(os.Environ(),
			"GIT_AUTHOR_NAME="+parts[0], "GIT_AUTHOR_EMAIL="+parts[1], "GIT_AUTHOR_DATE="+parts[2],
			"GIT_COMMITTER_NAME="+parts[3], "GIT_COMMITTER_EMAIL="+parts[4], "GIT_COMMITTER_DATE="+parts[5])
		ct.Stdin = bytes.NewReader(msg)
		co, cerr := ct.Output()
		if cerr != nil {
			return "", fmt.Errorf("commit-tree for %s: %w", rev, cerr)
		}
		last = strings.TrimSpace(string(co))
		lastT = T
		newTip = last
	}
	return newTip, nil
}

// writeCrossGuards installs the hooks that keep plain git from mixing the two
// histories a subdirectory cross carries (ADR-004 command audit). Only
// git-cross's own rebases (target under refs/cross/) are allowed through.
func writeCrossGuards(gdAbs string) error {
	hooks := filepath.Join(gdAbs, "hooks")
	if err := os.MkdirAll(hooks, 0o755); err != nil {
		return err
	}
	preRebase := `#!/bin/sh
# git-cross (ADR-004): subdirectory cross — only git-cross's own rebases
# (targets under refs/cross/) may run; a plain pull -r / rebase would rebase
# the subtree history onto the REAL upstream history (tree-shape mismatch).
case "$1" in
  refs/cross/*) exit 0 ;;
  *)
    echo "git-cross: this is a subdirectory cross." >&2
    echo "git-cross: plain git pull/rebase would rebase its subtree history onto the real upstream." >&2
    echo "git-cross: use: git cross pull -r" >&2
    exit 1 ;;
esac
`
	prePush := `#!/bin/sh
# git-cross (ADR-004): subdirectory cross — a plain push would overwrite the
# upstream branch with the subtree history. git-cross's own graft push is
# marked via the environment and allowed through.
if [ "$CROSS_PUSH_GRAFT" = "1" ]; then exit 0; fi
echo "git-cross: this is a subdirectory cross." >&2
echo "git-cross: a plain push would overwrite the upstream with the subtree history." >&2
echo "git-cross: use: git cross push" >&2
exit 1
`
	for name, body := range map[string]string{"pre-rebase": preRebase, "pre-push": prePush} {
		if err := os.WriteFile(filepath.Join(hooks, name), []byte(body), 0o755); err != nil {
			return err
		}
	}
	return nil
}

// ensureGitdirIdentity gives the bare gitdir a commit identity so plain
// cross-ctx commits/rebases work (a bare clone has none).
func ensureGitdirIdentity(gdAbs string) {
	if c := runGitdir(gdAbs, "config", "--get", "user.email"); c.Run() == nil {
		return
	}
	_ = runGitdir(gdAbs, "config", "user.name", "git-cross").Run()
	_ = runGitdir(gdAbs, "config", "user.email", "git-cross@localhost").Run()
}

// subtreeGuards runs the legacy-gitdir + lineage checks shared by update,
// pull and push for subdirectory crosses, and lazily re-attaches HEAD to the
// cross branch (a rebase/merge finished under a bare GIT_DIR + external work
// tree always ends detached — git never moves the branch; the user's manual
// `git rebase --continue` after a conflicted pull needs this catch-up).
func subtreeGuards(gdAbs, localPath, branch string) (oldMark string, err error) {
	// Defense-in-depth: a stray `core.worktree`/`core.bare=false` in the gitdir
	// (e.g. written by an ad-hoc raw git invocation) silently breaks portability
	// (absolute path) and flips git's work-tree rules. git-cross always passes
	// the work tree explicitly — restore the pristine bare config.
	if w, werr := runGitdir(gdAbs, "config", "--get", "core.worktree").Output(); werr == nil && strings.TrimSpace(string(w)) != "" {
		_ = runGitdir(gdAbs, "config", "--unset", "core.worktree").Run()
		_ = runGitdir(gdAbs, "config", "core.bare", "true").Run()
	}
	if err := runGitdir(gdAbs, "symbolic-ref", "--quiet", "HEAD").Run(); err != nil {
		_ = runGitdir(gdAbs, "update-ref", "refs/heads/"+branch, "HEAD").Run()
		_ = runGitdir(gdAbs, "symbolic-ref", "HEAD", "refs/heads/"+branch).Run()
	}
	markOut, merr := runGitdir(gdAbs, "rev-parse", "-q", "--verify", upstreamRef(branch)).Output()
	if merr != nil {
		return "", fmt.Errorf("%s: pre-0.6 subdir gitdir (no synthesis markers); run: git cross update (it re-adopts pre-0.6 subdir gitdirs)", localPath)
	}
	// Lineage: the synthesized chain is DISJOINT from the real upstream history
	// by construction. A branch sharing ANY ancestor with origin/<b> was re-pointed
	// at real history by a raw git command. Backward moves INSIDE the synth
	// chain stay legal (the rerere-replay flow rewinds the mirror on purpose).
	if base, berr := runGitdir(gdAbs, "merge-base", "refs/heads/"+branch,
		"refs/remotes/origin/"+branch).Output(); berr == nil && strings.TrimSpace(string(base)) != "" {
		return "", fmt.Errorf("%s: the cross branch no longer descends from the synthesized history (a raw git command re-pointed it?); re-adopt: git cross del %s && git cross update", localPath, localPath)
	}
	return strings.TrimSpace(string(markOut)), nil
}

// crossPullSubtree intercepts `git cross pull` for a subdirectory cross:
// fetch -> incremental synthesis -> same-shape rebase (ADR-004). Plain-args
// forms beyond [-r|--rebase] are refused (they could target the real history).
func crossPullSubtree(root string, p *Patch, rest []string) error {
	rebase := false
	for _, a := range rest {
		switch a {
		case "-r", "--rebase":
			rebase = true
		default:
			return fmt.Errorf("git cross pull for a subdirectory cross supports only [-r|--rebase] (got: %q); the plain passthrough is guarded because it would rebase the subtree history onto the real upstream", strings.Join(rest, " "))
		}
	}
	gdAbs := p.gitdirAbs(root)
	if _, err := subtreeGuards(gdAbs, p.LocalPath, p.Branch); err != nil {
		return err
	}
	// The synthesis base is the SYNTHESIZED marker (the upstream marker guards
	// the return of subtreeGuards is a REAL commit — building on it would mix
	// the two histories and trip the lineage check).
	synthMark := strings.TrimSpace(string(runGitdirOut(gdAbs, "rev-parse", "-q", "--verify", synthRef(p.Branch))))
	if synthMark == "" {
		return fmt.Errorf("%s: pre-0.6 subdir gitdir (no synthesis markers); run: git cross update (it re-adopts pre-0.6 subdir gitdirs)", p.LocalPath)
	}
	if fetch := runGitdir(gdAbs, "fetch", "-q", "--no-recurse-submodules", "origin",
		fmt.Sprintf("+refs/heads/%s:refs/remotes/origin/%s", p.Branch, p.Branch)); fetch.Run() != nil {
		return fmt.Errorf("git fetch failed for %s (%s)", p.Remote, p.RemoteURL)
	}
	revOut, err := runGitdir(gdAbs, "rev-parse", "refs/remotes/origin/"+p.Branch).Output()
	if err != nil {
		return err
	}
	rev := strings.TrimSpace(string(revOut))
	tip, err := synthesizeSubtree(gdAbs, p.RemotePath,
		"refs/remotes/origin/"+p.Branch+" ^"+upstreamRef(p.Branch), synthMark)
	if err != nil {
		return err
	}
	if tip == "" {
		logInfo(fmt.Sprintf("%s is already up to date", p.LocalPath))
		return nil
	}
	// Already integrated (e.g. the user just finished a conflicted pull with
	// `git rebase --continue`): just move the markers, no rebase needed.
	if runGitdir(gdAbs, "merge-base", "--is-ancestor", tip, "refs/heads/"+p.Branch).Run() == nil {
		_ = runGitdir(gdAbs, "update-ref", upstreamRef(p.Branch), rev).Run()
		_ = runGitdir(gdAbs, "update-ref", synthRef(p.Branch), tip).Run()
		logInfo(fmt.Sprintf("%s is already up to date", p.LocalPath))
		return nil
	}
	// The rebase/merge runs in the gitdir with the crossed dir as the work
	// tree — the pre-rebase hook allows it (target under refs/cross/).
	// Markers move ONLY on success (a failed/conflicted pull must not leave
	// them ahead of the branch — the next run would walk nothing).
	heads := strings.TrimSpace(string(runGitdirOut(gdAbs, "rev-parse", "refs/heads/"+p.Branch)))
	if heads == synthMark && rebase {
		// No local commits: a no-op `rebase --onto` would leave the branch
		// behind — fast-forward it and materialize the new content instead.
		if err := runGitdir(gdAbs, "update-ref", "refs/heads/"+p.Branch, tip).Run(); err != nil {
			return fmt.Errorf("cannot advance the subtree branch for %s: %w", p.LocalPath, err)
		}
		_ = runGitdir(gdAbs, "symbolic-ref", "HEAD", "refs/heads/"+p.Branch).Run()
		mt := exec.Command("git", "--git-dir", gdAbs, "--work-tree", p.localAbs(root), "read-tree", "-mu", "HEAD")
		if out, merr := mt.CombinedOutput(); merr != nil {
			return fmt.Errorf("cannot update the crossed dir (uncommitted local edits? commit or stash them first): %s", strings.TrimSpace(string(out)))
		}
	} else {
		var c *exec.Cmd
		if rebase {
			// The upstream arg is the marker BY NAME (refs/cross/…) — the pre-rebase
			// hook's allow-rule matches the ref name, not a raw SHA.
			c = exec.Command("git", "--git-dir", gdAbs, "--work-tree", p.localAbs(root),
				"rebase", "--onto", tip, synthRef(p.Branch), "refs/heads/"+p.Branch)
		} else {
			c = exec.Command("git", "--git-dir", gdAbs, "--work-tree", p.localAbs(root),
				"merge", tip)
		}
		c.Stdin, c.Stdout, c.Stderr = os.Stdin, os.Stdout, os.Stderr
		if err := c.Run(); err != nil {
			if ee, ok := err.(*exec.ExitError); ok {
				// A conflict: git's own markers/instructions are already on screen;
				// rerere records the resolution in the gitdir.
				os.Exit(ee.ExitCode())
			}
			return err
		}
		// The rebase/merge finished DETACHED (bare GIT_DIR quirk): move the
		// result onto the branch, re-attach HEAD, refresh the index.
		_ = runGitdir(gdAbs, "update-ref", "refs/heads/"+p.Branch, "HEAD").Run()
		_ = runGitdir(gdAbs, "symbolic-ref", "HEAD", "refs/heads/"+p.Branch).Run()
		_ = runGitdir(gdAbs, "read-tree", "HEAD").Run()
	}
	_ = runGitdir(gdAbs, "update-ref", upstreamRef(p.Branch), rev).Run()
	_ = runGitdir(gdAbs, "update-ref", synthRef(p.Branch), tip).Run()
	logSuccess(fmt.Sprintf("Pulled %s (subtree re-rooted, %s)", p.LocalPath, p.RemotePath))
	return nil
}

// crossPushSubtree intercepts `git cross push` for a subdirectory cross and
// performs the graft (ADR-004): upstream's tree with ONLY remotePath
// replaced by the local subtree, committed on top of the fetched upstream
// tip, then a normal push. Refuses when upstream also changed remotePath
// since the last update (pull first, then push).
func crossPushSubtree(root string, p *Patch, rest []string) error {
	for _, a := range rest {
		if a != "origin" {
			return fmt.Errorf("git cross push for a subdirectory cross takes no extra arguments (got: %q) — it grafts the subtree onto upstream %s and pushes", a, p.Remote)
		}
	}
	gdAbs := p.gitdirAbs(root)
	if _, err := subtreeGuards(gdAbs, p.LocalPath, p.Branch); err != nil {
		return err
	}
	markT := strings.TrimSpace(string(runGitdirOut(gdAbs, "rev-parse", synthRef(p.Branch)+"^{tree}")))
	headT := strings.TrimSpace(string(runGitdirOut(gdAbs, "rev-parse", "refs/heads/"+p.Branch+"^{tree}")))
	if markT == "" || headT == "" {
		return fmt.Errorf("%s: cannot resolve the cross trees", p.LocalPath)
	}
	if markT == headT {
		logInfo(fmt.Sprintf("%s has nothing to push (no local commits on the cross)", p.LocalPath))
		return nil
	}
	if fetch := runGitdir(gdAbs, "fetch", "-q", "--no-recurse-submodules", "origin",
		fmt.Sprintf("+refs/heads/%s:refs/remotes/origin/%s", p.Branch, p.Branch)); fetch.Run() != nil {
		return fmt.Errorf("git fetch failed for %s (%s)", p.Remote, p.RemoteURL)
	}
	U := strings.TrimSpace(string(runGitdirOut(gdAbs, "rev-parse", "refs/remotes/origin/"+p.Branch)))
	if U == "" {
		return fmt.Errorf("%s: cannot resolve the upstream tip", p.LocalPath)
	}
	// The upstream's current subtree state:
	upT := emptyTree
	if o, terr := runGitdir(gdAbs, "rev-parse", "-q", "--verify", U+":"+p.RemotePath).Output(); terr == nil {
		upT = strings.TrimSpace(string(o))
	}
	if upT == headT {
		// Already pushed (or identical): nothing to graft.
		logInfo(fmt.Sprintf("%s has nothing to push (upstream %s:%s already has this content)", p.LocalPath, p.Remote, p.RemotePath))
		return nil
	}
	// Safety: if upstream also changed remotePath since the last marker, a
	// wholesale graft would silently discard those upstream changes.
	if upT != markT {
		return fmt.Errorf("%s: upstream also changed %s since your last update — run: git cross pull -r first (then push)", p.LocalPath, p.RemotePath)
	}
	// The graft runs in a throwaway index inside the gitdir (all objects live
	// there: the upstream tree and the local subtree).
	idx, err := os.CreateTemp("", "cross-graft-")
	if err != nil {
		return err
	}
	idxPath := idx.Name()
	idx.Close()
	os.Remove(idxPath)
	defer os.Remove(idxPath)
	env := append(os.Environ(), "GIT_INDEX_FILE="+idxPath)
	// The graft commands name the work tree explicitly: read-tree --prefix and
	// update-index refuse to run without one, and the gitdir must stay portable
	// (no core.worktree config — the pair comes from the invocation, per ADR-001).
	run := func(args ...string) (string, error) {
		c := exec.Command("git", append([]string{"--git-dir", gdAbs, "--work-tree", p.localAbs(root)}, args...)...)
		c.Env = env
		out, rerr := c.Output()
		return strings.TrimSpace(string(out)), rerr
	}
	// The graft (git 2.53 read-tree refuses "-m --prefix" — "Which one?"):
	// seed the temp index with the upstream tree, REMOVE the remote_path
	// entries via update-index --index-info, then place the local subtree at
	// the prefix. An empty local subtree = the path vanishes upstream.
	if _, err := run("read-tree", U+"^{tree}"); err != nil {
		return fmt.Errorf("graft: read-tree upstream: %w", err)
	}
	ls := exec.Command("git", "--git-dir", gdAbs, "ls-tree", "-r", "--name-only", U+"^{tree}", "--", p.RemotePath+"/")
	ls.Env = env
	lsOut, lerr := ls.Output()
	if lerr != nil {
		return fmt.Errorf("graft: ls-tree: %w", lerr)
	}
	var info bytes.Buffer
	for _, pth := range strings.Split(string(lsOut), "\n") {
		if pth = strings.TrimSpace(pth); pth != "" {
			fmt.Fprintf(&info, "0 %s\t%s\n", strings.Repeat("0", 40), pth)
		}
	}
	if info.Len() > 0 {
		ui := exec.Command("git", "--git-dir", gdAbs, "--work-tree", p.localAbs(root), "update-index", "--index-info")
		ui.Env = env
		ui.Stdin = &info
		if out, uerr := ui.CombinedOutput(); uerr != nil {
			return fmt.Errorf("graft: update-index removals: %s", strings.TrimSpace(string(out)))
		}
	}
	if _, err := run("read-tree", "--prefix="+p.RemotePath+"/", headT); err != nil {
		return fmt.Errorf("graft: read-tree --prefix: %w", err)
	}
	G, err := run("write-tree")
	if err != nil || G == "" {
		return fmt.Errorf("graft: write-tree: %w", err)
	}
	ct := exec.Command("git", "-c", "user.name=git-cross", "-c", "user.email=git-cross@localhost",
		"--git-dir", gdAbs, "commit-tree", G, "-p", U,
		"-m", fmt.Sprintf("git-cross: %s -> %s:%s", p.LocalPath, p.Remote, p.RemotePath))
	co, cerr := ct.Output()
	if cerr != nil {
		return fmt.Errorf("graft: commit-tree: %w", cerr)
	}
	C := strings.TrimSpace(string(co))
	push := exec.Command("git", "--git-dir", gdAbs, "push", "origin",
		C+":refs/heads/"+p.Branch)
	push.Env = append(os.Environ(), "CROSS_PUSH_GRAFT=1") // the pre-push hook lets the graft through
	push.Stdin, push.Stdout, push.Stderr = os.Stdin, os.Stdout, os.Stderr
	if err := push.Run(); err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			os.Exit(ee.ExitCode())
		}
		return err
	}
	logSuccess(fmt.Sprintf("Pushed %s (grafted onto %s:%s; nothing outside %s touched)", p.LocalPath, p.Remote, p.RemotePath, p.RemotePath))
	return nil
}

// runGitdirOut runs a gitdir command and returns its stdout (empty on error).
func runGitdirOut(gdAbs string, args ...string) []byte {
	out, err := runGitdir(gdAbs, args...).Output()
	if err != nil {
		return nil
	}
	return out
}

// applyUpstreamDelta runs the land+re-apply step for one patch (ADR-003).
func applyUpstreamDelta(root string, p *Patch, baseRev, theirsTreeish, theirsRev string, resolve bool) landResult {
	delta, err := upstreamDeltaCommit(root, p, baseRev, theirsTreeish)
	if err != nil {
		logError(fmt.Sprintf("%s: %v", p.LocalPath, err))
		return landFailed
	}
	args := []string{"cherry-pick", "-n"}
	if !resolve {
		// --no-resolve: upstream wins every collision; the patch dir lands as-is.
		args = append(args, "-X", "theirs")
	}
	args = append(args, delta)
	// Runs in the USER's repo: this is their content, their index, their rerere.
	cmd := exec.Command("git", append([]string{"-C", root}, args...)...)
	var buf bytes.Buffer
	cmd.Stdout, cmd.Stderr = &buf, &buf
	runErr := cmd.Run()

	if unmerged := patchUnmerged(root, p); len(unmerged) > 0 {
		return landConflict
	}
	if runErr != nil {
		// No unmerged paths. Either the delta was already applied (nothing to do)
		// or git refused for another reason; only the former is "up to date".
		if strings.Contains(buf.String(), "nothing to commit") ||
			strings.Contains(buf.String(), "previous cherry-pick is now empty") {
			advanceMirror(root, p, theirsRev)
			return landUptodate
		}
		logError(fmt.Sprintf("%s: cherry-pick failed: %s", p.LocalPath, strings.TrimSpace(buf.String())))
		return landFailed
	}
	return landUpdated
}

// landUpstream is the guarded pass-3 step: refuse uncommitted edits, skip pending
// conflicts, otherwise apply the upstream delta and advance the mirror on success.
func landUpstream(root string, p *Patch, rev string, resolve bool) landResult {
	if len(patchUnmerged(root, p)) > 0 {
		return landPending
	}
	dirty, err := patchWorktreeDirty(root, p)
	if err != nil {
		logError(fmt.Sprintf("%s: cannot inspect the work tree: %v", p.LocalPath, err))
		return landFailed
	}
	if dirty {
		return landDirty
	}
	gdAbs := p.gitdirAbs(root)
	baseOut, err := runGitdir(gdAbs, "rev-parse", "HEAD").Output()
	if err != nil {
		logError(fmt.Sprintf("%s: cannot resolve the mirror HEAD: %v", p.LocalPath, err))
		return landFailed
	}
	baseRev := strings.TrimSpace(string(baseOut))
	theirsTreeish := rev
	if p.RemotePath != "." && p.RemotePath != "/" {
		// D3(c) (ADR-004): the mirror branch is SYNTHESIZED — its hashes are
		// disjoint from the real upstream, so the up-to-date check uses the
		// marker, and the delta's "theirs" side is the upstream SUBTREE.
		if _, gerr := subtreeGuards(gdAbs, p.LocalPath, p.Branch); gerr != nil {
			logError(gerr.Error())
			return landFailed
		}
		markOut, _ := runGitdir(gdAbs, "rev-parse", "-q", "--verify", upstreamRef(p.Branch)).Output()
		if strings.TrimSpace(string(markOut)) == rev {
			return landUptodate
		}
		// A vanished upstream path = the empty subtree = wholesale deletion.
		if to, terr := runGitdir(gdAbs, "rev-parse", "-q", "--verify", rev+":"+p.RemotePath).Output(); terr == nil {
			theirsTreeish = strings.TrimSpace(string(to))
		} else {
			theirsTreeish = emptyTree
		}
	} else if baseRev == rev {
		return landUptodate
	}
	if err := runGitdir(gdAbs, "cat-file", "-e", baseRev+"^{tree}").Run(); err != nil {
		logError(fmt.Sprintf("%s: the mirror lacks the previous upstream tree (shallow/partial clone?); delete and re-set it", p.LocalPath))
		return landFailed
	}
	// Untracked files the delta would overwrite: git's own safety check,
	// surfaced as an EARLY refusal with guidance (0.6.1) instead of a raw
	// "would be overwritten by merge" cherry-pick error after the fetch.
	if hit := patchUntrackedCollisions(root, p, gdAbs, baseRev, theirsTreeish); len(hit) > 0 {
		logError(fmt.Sprintf("%s: untracked files would be overwritten by the update; commit or stage them first (git add <paths> && git commit), or remove them:", p.LocalPath))
		for _, f := range hit {
			fmt.Println("  " + f)
		}
		return landUntracked
	}
	// The USER's repo must own every object it will reference: a local fetch from
	// the mirror copies the needed objects without creating a remote or a lasting
	// ref (FETCH_HEAD only). Without this the user's index would point at blobs
	// that only exist in the mirror.
	for _, ref := range []string{
		"refs/heads/" + p.Branch,
		"refs/remotes/origin/" + p.Branch,
	} {
		// --no-recurse-submodules: `git fetch` defaults to on-demand recursion;
		// when the fetched upstream tree records a submodule pointer that is not
		// present locally, git tries to fetch it through the user's (possibly
		// stale, pre-migration) submodule URL, fails, and makes the WHOLE import
		// fetch exit 1 ("Errors during submodule fetch: <path>") even though the
		// superproject objects arrived fine. git-cross imports object graphs, not
		// submodule checkouts — the crossed dir holds plain files.
		fc := exec.Command("git", "-C", root, "fetch", "--no-tags", "--quiet", "--no-recurse-submodules", gdAbs, ref)
		fc.Stderr = os.Stderr
		if err := fc.Run(); err != nil {
			logError(fmt.Sprintf("%s: cannot import upstream objects from the mirror: %v", p.LocalPath, err))
			return landFailed
		}
	}
	res := applyUpstreamDelta(root, p, baseRev, theirsTreeish, rev, resolve)
	if res == landUpdated {
		advanceMirror(root, p, rev)
	}
	return res
}

func detectDefaultBranch(url string) (string, error) {
	if out, err := exec.Command("git", "ls-remote", "--symref", url, "HEAD").CombinedOutput(); err == nil {
		for _, line := range strings.Split(string(out), "\n") {
			if strings.HasPrefix(line, "ref: ") {
				parts := strings.Split(line, "\t")
				if len(parts) == 2 && parts[1] == "HEAD" {
					target := strings.TrimPrefix(parts[0], "ref: ")
					if strings.HasPrefix(target, "refs/heads/") {
						return strings.TrimPrefix(target, "refs/heads/"), nil
					}
				}
			}
		}
	}
	out, err := exec.Command("git", "ls-remote", "--heads", url).Output()
	if err != nil {
		return "", err
	}
	for _, candidate := range []string{"main", "master"} {
		if strings.Contains(string(out), "refs/heads/"+candidate+"\t") {
			return candidate, nil
		}
	}
	for _, line := range strings.Split(string(out), "\n") {
		if strings.HasPrefix(line, "refs/heads/") {
			return strings.TrimSuffix(strings.TrimPrefix(line, "refs/heads/"), "\tmain"), nil
		}
	}
	return "main", nil
}

// ensureRerere enables rerere in a git dir (primary repo or a patch gitdir);
// returns true when the setting was newly enabled.
func ensureRerere(gitArgs ...string) bool {
	base := append([]string{}, gitArgs...)
	base = append(base, "config", "--get", "rerere.enabled")
	if out, err := exec.Command("git", base...).Output(); err == nil {
		if strings.TrimSpace(string(out)) == "true" {
			return false
		}
	}
	set := append([]string{}, gitArgs...)
	set = append(set, "config", "rerere.enabled", "true")
	if err := exec.Command("git", set...).Run(); err != nil {
		logWarn(fmt.Sprintf("could not enable rerere: %v", err))
		return false
	}
	return true
}

// ------------------------------------------------------------------ output ---

func logInfo(msg string)    { color.New(color.Bold, color.FgBlue).Print("==> "); fmt.Println(msg) }
func logSuccess(msg string) { color.New(color.Bold, color.FgGreen).Print("==> "); fmt.Println(msg) }
func logWarn(msg string) {
	color.New(color.Bold, color.FgYellow).Fprint(os.Stderr, "==> WARNING: ")
	fmt.Fprintln(os.Stderr, msg)
}
func logError(msg string) {
	color.New(color.Bold, color.FgRed).Fprint(os.Stderr, "==> ERROR: ")
	fmt.Fprintln(os.Stderr, msg)
}

// envList splits a comma-separated environment variable into trimmed items.

// printPatchRows prints one row per patch: local_path <TAB> gitdir.
func printPatchRows(hint string) error { return printPatchRowsTo(os.Stdout, hint) }

// printPatchRowsTo is printPatchRows with a chosen stream: the interactive
// picker's caller reserves stdout for the chosen path, so a fallback listing
// (fzf missing) must go to stderr instead.
func printPatchRowsTo(w io.Writer, hint string) error {
	meta, err := loadMetadata()
	if err != nil {
		return err
	}
	if len(meta.Patches) == 0 {
		logInfo("No crosses configured.")
		return nil
	}
	if hint != "" {
		fmt.Fprintln(os.Stderr, hint)
	}
	if stdoutIsTerminal() {
		width := 0
		for _, p := range meta.Patches {
			if n := utf8.RuneCountInString(p.LocalPath); n > width {
				width = n
			}
		}
		for _, p := range meta.Patches {
			fmt.Fprintf(w, "%-*s  %s\n", width, p.LocalPath, p.Gitdir)
		}
		return nil
	}
	for _, p := range meta.Patches {
		fmt.Fprintf(w, "%s\t%s\n", p.LocalPath, p.Gitdir)
	}
	return nil
}

func printRawRows(rows [][]string) {
	if len(rows) == 0 {
		return
	}
	if !stdoutIsTerminal() {
		for _, row := range rows {
			fmt.Println(strings.Join(row, "\t"))
		}
		return
	}
	var widths []int
	for _, row := range rows {
		for i, col := range row {
			if i >= len(widths) {
				widths = append(widths, 0)
			}
			if n := utf8.RuneCountInString(col); n > widths[i] {
				widths[i] = n
			}
		}
	}
	for _, row := range rows {
		var b strings.Builder
		for i, col := range row {
			if i > 0 {
				b.WriteString("  ")
			}
			if i < len(row)-1 {
				fmt.Fprintf(&b, "%-*s", widths[i], col)
			} else {
				b.WriteString(col)
			}
		}
		fmt.Println(b.String())
	}
}

func stdoutIsTerminal() bool {
	info, err := os.Stdout.Stat()
	if err != nil {
		return false
	}
	return info.Mode()&os.ModeCharDevice != 0
}

// errPatchNotFound is returned after rows were already printed.
var errPatchNotFound = errors.New("cross not found")

// --------------------------------------------------------------- metadata ---

func loadMetadata() (Metadata, error) {
	var meta Metadata
	path, err := getMetadataPath()
	if err != nil {
		return meta, err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return meta, nil
		}
		return meta, err
	}
	if err := json.Unmarshal(data, &meta); err != nil {
		return meta, err
	}
	for i := range meta.Patches {
		meta.Patches[i].LocalPath = filepath.ToSlash(filepath.Clean(meta.Patches[i].LocalPath))
		if meta.Patches[i].Worktree != "" {
			meta.Patches[i].Worktree = filepath.ToSlash(filepath.Clean(meta.Patches[i].Worktree))
		}
		// Self-heal v0.4 leftovers: a worktree inside .cross/worktrees/ is the
		// old hidden checkout (e.g. ".cross/worktrees/infra_c30e3178"), never
		// the in-repo crossed dir. ADR-001: worktree == local_path since 0.5.0 —
		// coerce stale values so cd/passthrough/update target the crossed dir.
		if strings.HasPrefix(meta.Patches[i].Worktree, GitdirRoot+"/") || meta.Patches[i].Worktree == GitdirRoot {
			meta.Patches[i].Worktree = meta.Patches[i].LocalPath
		}
	}
	return meta, nil
}

func saveMetadata(meta Metadata) error {
	path, err := getMetadataPath()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(meta, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o644)
}

// ensureGitignore adds ".cross/" to .gitignore if not already present.
func ensureGitignore() {
	root, err := getRepoRoot()
	if err != nil {
		return
	}
	gi := filepath.Join(root, ".gitignore")
	data, err := os.ReadFile(gi)
	if err == nil {
		for _, line := range strings.Split(string(data), "\n") {
			if strings.TrimSpace(line) == ".cross/" || strings.TrimSpace(line) == ".cross" {
				return
			}
		}
	}
	f, err := os.OpenFile(gi, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	if len(data) > 0 && data[len(data)-1] != '\n' {
		f.WriteString("\n")
	}
	f.WriteString(".cross/\n")
}

func updateCrossfile(line string) error {
	path, err := getCrossfilePath()
	if err != nil {
		return err
	}
	line = strings.TrimSpace(line)
	data, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	content := string(data)
	lineWithoutPrefix := strings.TrimPrefix(line, "cross ")
	for _, l := range strings.Split(content, "\n") {
		trimmedL := strings.TrimSpace(l)
		if trimmedL == line || trimmedL == "cross "+line || trimmedL == lineWithoutPrefix {
			return nil
		}
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	if len(data) > 0 && data[len(data)-1] != '\n' {
		f.WriteString("\n")
	}
	if !strings.HasPrefix(line, "cross ") {
		_, err = f.WriteString("cross " + line + "\n")
	} else {
		_, err = f.WriteString(line + "\n")
	}
	return err
}

// updateCrossfileUseLine keeps exactly ONE `use` declaration per remote name:
// re-pointing a remote (git cross use <name> <new-url>) rewrites its existing
// line in place instead of appending a second one — a duplicate `use` line
// would make the Crossfile ambiguous (see the crossfileCommands validation).
func updateCrossfileUseLine(name, url string) error {
	path, err := getCrossfilePath()
	if err != nil {
		return err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return updateCrossfile("use " + name + " " + url) // not declared yet: append (creates the file)
		}
		return err
	}
	newLine := "cross use " + name + " " + url
	replaced := false
	var out []string
	for _, l := range strings.Split(string(data), "\n") {
		trimmed := strings.TrimSpace(l)
		if trimmed != "" && !strings.HasPrefix(trimmed, "#") {
			fields := strings.Fields(trimmed)
			if len(fields) >= 2 && (fields[0] == "git" || fields[0] == "just") && fields[1] == "cross" {
				fields = fields[2:]
			} else if len(fields) > 0 && fields[0] == "cross" {
				fields = fields[1:]
			}
			if len(fields) >= 2 && fields[0] == "use" && fields[1] == name {
				if !replaced {
					out = append(out, newLine)
					replaced = true
				}
				continue // drop any further duplicate declarations of this remote
			}
		}
		out = append(out, l)
	}
	if !replaced {
		return updateCrossfile("use " + name + " " + url) // not declared yet: append
	}
	return os.WriteFile(path, []byte(strings.Join(out, "\n")), 0o644)
}

func crossfileCommands(path string) ([][]string, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	// One declaration per key: a remote NAME (use) and a local_path (set).
	// Duplicates are ambiguous — two URLs for one remote name, two sources
	// for one crossed dir — and used to resolve silently (first/last line
	// wins). They are a validation error: the Crossfile is the source of truth.
	type declaration struct {
		line  int
		value string
	}
	remotes := make(map[string]declaration)
	crosses := make(map[string]declaration)

	var commands [][]string
	scanner := bufio.NewScanner(file)
	for lineNumber := 1; scanner.Scan(); lineNumber++ {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) >= 2 && (fields[0] == "git" || fields[0] == "just") && fields[1] == "cross" {
			fields = fields[2:]
		} else if len(fields) > 0 && fields[0] == "cross" {
			fields = fields[1:]
		}
		if len(fields) == 0 || (fields[0] != "use" && fields[0] != "set" && fields[0] != "patch") {
			return nil, fmt.Errorf("unsupported Crossfile command on line %d (update accepts only use and set declarations; 'patch' is the legacy keyword)", lineNumber)
		}
		if fields[0] == "use" && len(fields) == 3 {
			if prev, dup := remotes[fields[1]]; dup {
				return nil, fmt.Errorf("duplicate remote declaration '%s' in Crossfile: line %d (%s) and line %d (%s) — a remote name maps to exactly one URL; remove the stale line, or re-point with: git cross use %s <url>", fields[1], prev.line, prev.value, lineNumber, fields[2], fields[1])
			}
			remotes[fields[1]] = declaration{lineNumber, fields[2]}
		}
		if (fields[0] == "set" || fields[0] == "patch") && len(fields) >= 2 && len(fields) <= 3 {
			localPath := ""
			if len(fields) == 3 {
				localPath = fields[2]
			} else {
				spec := strings.Split(fields[1], ":")
				localPath = filepath.Base(spec[len(spec)-1])
			}
			localPath = filepath.ToSlash(filepath.Clean(localPath))
			if prev, dup := crosses[localPath]; dup {
				return nil, fmt.Errorf("duplicate cross declaration for '%s' in Crossfile: line %d (%s) and line %d (%s) — keep exactly one line — delete the stale one (git cross del %s also deletes the crossed dir)", localPath, prev.line, prev.value, lineNumber, fields[1], localPath)
			}
			crosses[localPath] = declaration{lineNumber, fields[1]}
		}
		commands = append(commands, fields)
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return commands, nil
}

// declaredLocalPaths returns the local paths a parsed Crossfile declares,
// mirroring update's own interpretation (`cross set <spec> [local_path]`, the
// local path defaulting to the remote path's base). The Crossfile is the
// source of truth for which crosses exist, so a registry entry it no longer
// declares is stale state: `wipe` drops it (crossed dirs stay — they are the
// user's files) and `update` warns about it.
func declaredLocalPaths(commands [][]string) (map[string]bool, error) {
	declared := map[string]bool{}
	for _, fields := range commands {
		if fields[0] != "set" && fields[0] != "patch" {
			continue
		}
		if len(fields) < 2 || len(fields) > 3 {
			return nil, fmt.Errorf("invalid set declaration in Crossfile: %s", strings.Join(fields, " "))
		}
		spec, err := parsePatchSpec(fields[1])
		if err != nil {
			return nil, err
		}
		localPath := filepath.Base(spec.RemotePath)
		if len(fields) == 3 {
			localPath = fields[2]
		}
		declared[filepath.ToSlash(filepath.Clean(localPath))] = true
	}
	return declared, nil
}

// undeclaredPatches lists registered crosses the Crossfile no longer declares.
func undeclaredPatches(commands [][]string, meta Metadata) []string {
	declared, err := declaredLocalPaths(commands)
	if err != nil {
		return nil
	}
	var stale []string
	for _, p := range meta.Patches {
		if !declared[filepath.ToSlash(filepath.Clean(p.LocalPath))] {
			stale = append(stale, p.LocalPath)
		}
	}
	sort.Strings(stale)
	return stale
}

// removeFromCrossfile removes cross lines matching a specific local_path
// using structured field matching (the local_path is the last field).
// 'patch' is the legacy Crossfile keyword for 'set'.
func removeFromCrossfile(localPath string) {
	path, err := getCrossfilePath()
	if err != nil {
		return
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	lines := strings.Split(string(data), "\n")
	var newLines []string
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		fields := strings.Fields(trimmed)
		isCrossLine := false
		for _, f := range fields {
			if f == "set" || f == "patch" {
				isCrossLine = true
				break
			}
		}
		if isCrossLine && len(fields) > 0 && filepath.ToSlash(filepath.Clean(fields[len(fields)-1])) == localPath {
			continue
		}
		newLines = append(newLines, line)
	}
	if err := os.WriteFile(path, []byte(strings.Join(newLines, "\n")), 0o644); err != nil {
		logError(fmt.Sprintf("Failed to update Crossfile: %v", err))
	}
}

// ------------------------------------------------------------ patch lookup ---

func repoRelativePath() (string, error) {
	root, err := getRepoRoot()
	if err != nil {
		return "", err
	}
	cwd, err := os.Getwd()
	if err != nil {
		return "", err
	}
	// Resolve logical paths ($PWD through a symlink) to the physical path git reports.
	if resolved, rerr := filepath.EvalSymlinks(cwd); rerr == nil {
		cwd = resolved
	}
	rel, err := filepath.Rel(root, cwd)
	if err != nil {
		return "", err
	}
	rel = filepath.ToSlash(rel)
	if rel == "." {
		return "", nil
	}
	return strings.Trim(rel, "/"), nil
}

func findPatchForPath(meta Metadata, rel string) *Patch {
	rel = strings.Trim(strings.TrimSpace(rel), "/")
	if rel == "" {
		return nil
	}
	rel = strings.Trim(filepath.ToSlash(filepath.Clean(rel)), "/")
	if rel == "" {
		return nil
	}
	var selected *Patch
	longest := -1
	for i := range meta.Patches {
		raw := strings.TrimSpace(meta.Patches[i].LocalPath)
		if raw == "" {
			continue
		}
		lp := strings.Trim(filepath.ToSlash(filepath.Clean(raw)), "/")
		if lp == "" {
			continue
		}
		if rel == lp || strings.HasPrefix(rel, lp+"/") {
			if len(lp) > longest {
				longest = len(lp)
				selected = &meta.Patches[i]
			}
		}
	}
	return selected
}

// cwdRepoRelative returns the repo-relative path of the USER's working directory.
// Git `!`-aliases (how `git cross` is usually installed) run the command from
// the REPO ROOT and export GIT_PREFIX = the caller's original CWD, root-relative
// with a trailing slash — use it when present, else the process CWD (direct
// invocation). Without this, every passthrough/`git cross <git-args>` run through
// the alias saw the repo root and failed with "not inside a crossed directory".
func cwdRepoRelative(root string) (string, error) {
	active := strings.Trim(filepath.ToSlash(filepath.Clean(os.Getenv("CROSS_ACTIVE"))), "/")
	if gp := strings.TrimSpace(os.Getenv("GIT_PREFIX")); gp != "" {
		rel := strings.Trim(filepath.ToSlash(filepath.Clean(gp)), "/")
		if active != "" && active != "." {
			// `eval "$(git cross env)"` is loaded: git's toplevel IS the crossed
			// dir, so GIT_PREFIX is relative to it, not to the primary repo root.
			if rel == "" || rel == "." {
				return active, nil
			}
			return active + "/" + rel, nil
		}
		return rel, nil
	}
	cwd, err := os.Getwd()
	if err != nil {
		return "", err
	}
	// Resolve logical paths ($PWD through a symlink) to the physical path git reports.
	if resolved, rerr := filepath.EvalSymlinks(cwd); rerr == nil {
		cwd = resolved
	}
	rel, err := filepath.Rel(root, cwd)
	if err != nil {
		return "", err
	}
	return strings.Trim(filepath.ToSlash(rel), "/"), nil
}

func findPatchForPathFromCWD(meta Metadata) (*Patch, error) {
	root, err := getRepoRoot()
	if err != nil {
		return nil, err
	}
	rel, err := cwdRepoRelative(root)
	if err != nil {
		return nil, err
	}
	return findPatchForPath(meta, rel), nil
}

// patchForEnv resolves the cross `git cross env` describes: an explicit path
// argument (repo-relative, absolute or a bare local_path), else the cross that
// contains the caller's working directory. nil means "no cross here".
func patchForEnv(meta *Metadata, args []string) (*Patch, error) {
	if len(args) == 0 || strings.TrimSpace(args[0]) == "" {
		return findPatchForPathFromCWD(*meta)
	}
	relPath, err := resolvePathToRepoRelative(args[0])
	if err != nil {
		return nil, err
	}
	if p := findPatchForPath(*meta, relPath); p != nil {
		return p, nil
	}
	clean := filepath.ToSlash(filepath.Clean(args[0]))
	for i := range meta.Patches {
		if meta.Patches[i].LocalPath == clean {
			return &meta.Patches[i], nil
		}
	}
	return nil, nil
}

// shellQuote single-quotes s for POSIX sh and fish (both read '\” as a
// literal quote), so paths with spaces or quotes survive `eval`/`source`.
func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// resolvePathToRepoRelative converts any path (relative, absolute, repo-relative)
// to a repo-relative path for matching against metadata.
func resolvePathToRepoRelative(inputPath string) (string, error) {
	if inputPath == "" {
		return "", nil
	}
	root, err := getRepoRoot()
	if err != nil {
		return "", err
	}
	cwd, err := os.Getwd()
	if err != nil {
		return "", err
	}
	var absPath string
	if filepath.IsAbs(inputPath) {
		absPath = inputPath
	} else {
		absPath = filepath.Join(cwd, inputPath)
	}
	absPath = filepath.Clean(absPath)
	if resolved, err := filepath.EvalSymlinks(absPath); err == nil {
		absPath = resolved
	}
	if rootResolved, err := filepath.EvalSymlinks(root); err == nil {
		root = rootResolved
	}
	relPath, err := filepath.Rel(root, absPath)
	if err != nil {
		return "", err
	}
	relPath = filepath.ToSlash(relPath)
	if strings.HasPrefix(relPath, "..") {
		return "", fmt.Errorf("path is outside repository: %s", inputPath)
	}
	if relPath == "." {
		return "", nil
	}
	return strings.Trim(relPath, "/"), nil
}

// ----------------------------------------------------------------- picker -----

func pickerWidth(meta *Metadata) int {
	width := 0
	for _, p := range meta.Patches {
		if n := len([]rune(p.LocalPath)); n > width {
			width = n
		}
	}
	width += 2
	if width < 16 {
		width = 16
	}
	if width > 48 {
		width = 48
	}
	return width
}

func pickerLabel(p Patch) string {
	label := p.Remote + ":" + p.RemotePath
	if p.Branch != "" && p.Branch != "main" {
		label += " (" + p.Branch + ")"
	}
	return label
}

func selectPatchInteractive(meta *Metadata) (*Patch, error) {
	if _, err := exec.LookPath("fzf"); err != nil {
		return nil, err
	}
	if len(meta.Patches) == 0 {
		return nil, nil
	}
	width := pickerWidth(meta)
	var b strings.Builder
	for _, p := range meta.Patches {
		b.WriteString(fmt.Sprintf("%-*s%s\t%s\n", width, p.LocalPath, pickerLabel(p), p.LocalPath))
	}
	cmd := exec.Command("fzf",
		"--delimiter", "\t",
		"--with-nth=1",
		"--prompt", "Select cross> ",
		"--header", fmt.Sprintf("%-*s%s", width, "LOCAL_PATH", "REMOTE:REMOTE_PATH"),
		"--height", "40%",
		"--border", "--select-1", "--exit-0",
	)
	cmd.Stdin = strings.NewReader(b.String())
	out, err := cmd.Output()
	selection := strings.TrimSpace(string(out))
	if err != nil || selection == "" {
		return nil, nil
	}
	parts := strings.Split(selection, "\t")
	var localPath string
	if len(parts) > 1 {
		localPath = strings.TrimSpace(parts[len(parts)-1])
	} else {
		fields := strings.Fields(selection)
		if len(fields) > 0 {
			localPath = fields[len(fields)-1]
		}
	}
	if localPath == "" {
		return nil, fmt.Errorf("unable to parse selection: %s", selection)
	}
	for i := range meta.Patches {
		if meta.Patches[i].LocalPath == localPath {
			return &meta.Patches[i], nil
		}
	}
	return nil, fmt.Errorf("selected cross not found: %s", localPath)
}

// crossDiffState reports the crossed dir's local divergence from the mirrored
// upstream HEAD (the old `stat` DIFF column): Clean / Modified / Missing Files
// / Missing GD.
func crossDiffState(root string, p *Patch) string {
	if _, lerr := os.Stat(p.localAbs(root)); os.IsNotExist(lerr) {
		return "Missing Files"
	}
	if _, gerr := os.Stat(p.gitdirAbs(root)); os.IsNotExist(gerr) {
		return "Missing GD"
	}
	differs, derr := patchDiffersFromUpstream(root, p)
	if derr != nil {
		return "Error" // the health diff itself failed: never a silent "Clean"
	}
	if differs {
		return "Modified"
	}
	return "Clean"
}

// crossHeadShort returns the short SHA of the upstream commit the mirror has
// checked out, or "-" when the gitdir is missing/unreadable.
func crossHeadShort(root string, p *Patch) string {
	gdAbs := p.gitdirAbs(root)
	if _, gerr := os.Stat(gdAbs); os.IsNotExist(gerr) {
		return "-"
	}
	out, err := runGitdir(gdAbs, "rev-parse", "--short", "HEAD").Output()
	sha := strings.TrimSpace(string(out))
	if err != nil || sha == "" {
		return "-"
	}
	return sha
}

// crossHasUncommitted reports whether the crossed dir has staged or unstaged
// changes. A re-adoption wipe destroys BOTH, so the caller stashes them first
// (or preserves the whole dir) instead of silently losing the user's work.
func crossHasUncommitted(root, localPath string) bool {
	out, err := exec.Command("git", "-C", root, "status", "--porcelain", "--", filepath.FromSlash(localPath)).Output()
	if err != nil {
		return true // cannot prove it is clean: stay on the safe side
	}
	return strings.TrimSpace(string(out)) != ""
}

// readoptChoice is the user's answer to the re-adoption prompt: skip (default),
// re-initialize from upstream (wipe the existing dir), stash uncommitted work
// and then re-initialize from upstream, or re-initialize while preserving the
// current crossed dir content.
type readoptChoice int

const (
	readoptDecline  readoptChoice = iota // skip: nothing is touched
	readoptWipe                          // re-initialize from upstream (dir wiped)
	readoptPreserve                      // re-initialize but preserve local (backup + copy back)
	readoptStash                         // stash uncommitted changes, then re-initialize (wipe)
)

// confirmReadopt asks what to do with an existing crossed dir whose .cross state
// was lost (the whole registry gone, or only its gitdir). Two ways to
// re-initialize: from upstream (the existing dir is wiped) or preserving local
// (the dir is moved aside, re-created from upstream, then the backup is copied
// back over it). A dirty dir adds a third, lossless way to pick the wipe: the
// uncommitted changes are stashed first, so `git stash apply` can bring them
// back into the freshly adopted cross. Anything but an explicit choice skips the
// cross (default No — the safe side). The ABSOLUTE path is shown so it is clear
// what gets re-initialized; --force auto-applies the wipe without prompting (it
// stashes first when the dir is dirty, never destroying uncommitted work).
func confirmReadopt(root, localPath string, dirty, force bool) (readoptChoice, error) {
	if localPath == "" || localPath == "." || localPath == ".." ||
		strings.HasPrefix(localPath, "../") || filepath.IsAbs(filepath.FromSlash(localPath)) {
		return readoptDecline, fmt.Errorf("refusing to clear unsafe path %q", localPath)
	}
	abs := filepath.Join(root, filepath.FromSlash(localPath))
	if filepath.Clean(abs) == filepath.Clean(root) || abs == string(filepath.Separator) {
		return readoptDecline, fmt.Errorf("refusing to clear the repository root")
	}
	if force {
		if dirty {
			return readoptStash, nil // --force never destroys uncommitted work
		}
		return readoptWipe, nil // --force: adopt (wipe) without asking
	}
	if dirty {
		fmt.Printf("'%s' exists but its .cross state is lost and it has uncommitted changes. Re-initialize how?\n", abs)
		fmt.Println("  [y] re-initialize from upstream (uncommitted changes stashed first)")
	} else {
		fmt.Printf("'%s' exists but its .cross state is lost. Re-initialize how?\n", abs)
		fmt.Println("  [y] re-initialize from upstream (existing dir wiped)")
	}
	fmt.Println("  [p] re-initialize but preserve local (existing dir backed up, then copied back)")
	fmt.Print("Choice [y/p/N]: ")
	var answer string
	if _, err := fmt.Scanln(&answer); err != nil {
		answer = "" // non-interactive (EOF) or empty input: default No
	}
	switch strings.ToLower(strings.TrimSpace(answer)) {
	case "y":
		if dirty {
			return readoptStash, nil
		}
		return readoptWipe, nil
	case "p":
		return readoptPreserve, nil
	}
	logWarn(fmt.Sprintf("Skipped %s (not confirmed; re-run with --force to adopt without asking)", localPath))
	return readoptDecline, nil
}

// stashCross parks a dirty crossed dir's changes in the primary repo's stash so
// a re-adoption wipe cannot lose them, and reports the stash entry to restore
// from. `-u` is required: when the whole registry is gone the crossed dir is
// usually untracked, and plain `stash push -- <path>` would save nothing.
func stashCross(root, localPath string) (string, error) {
	msg := fmt.Sprintf("git-cross: changes in %s before re-adoption", localPath)
	st := exec.Command("git", "-C", root, "stash", "push", "-u", "-m", msg, "--", filepath.FromSlash(localPath))
	var stderr bytes.Buffer
	st.Stderr = &stderr
	if err := st.Run(); err != nil {
		return "", fmt.Errorf("stashing uncommitted changes in %s failed: %s", localPath, strings.TrimSpace(stderr.String()))
	}
	if crossHasUncommitted(root, localPath) {
		// Conservative: never delete what the stash did not capture.
		return "", fmt.Errorf("%s still has uncommitted changes after stashing; refusing to delete them", localPath)
	}
	logInfo(fmt.Sprintf("Stashed uncommitted changes in %s (restore with: git stash apply \"stash@{0}\")", localPath))
	return "stash@{0}", nil
}

// removeGitdirTree deletes a path ONLY when it lives under .cross/worktrees/.
// Every wipe-side removal goes through it: wipe owns disposable state, never a
// crossed dir in the main working tree (that is `del` or the user's call).
func removeGitdirTree(root, relPath string) error {
	guard := filepath.Join(root, filepath.FromSlash(GitdirRoot))
	abs := relPath
	if !filepath.IsAbs(abs) {
		abs = filepath.Join(root, filepath.FromSlash(relPath))
	}
	abs = filepath.Clean(abs)
	rel, err := filepath.Rel(guard, abs)
	if err != nil || rel == "." || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return fmt.Errorf("refusing to delete outside %s: %s", GitdirRoot, relPath)
	}
	if _, serr := os.Stat(abs); os.IsNotExist(serr) {
		return nil
	}
	return os.RemoveAll(abs)
}

// forceClearDir removes a crossed dir so `update --force` can re-create the
// cross from upstream. Safety first: refuse anything that escapes the repo.
func forceClearDir(root, localPath string) error {
	if localPath == "" || localPath == "." || localPath == ".." ||
		strings.HasPrefix(localPath, "../") || filepath.IsAbs(filepath.FromSlash(localPath)) {
		return fmt.Errorf("refusing to clear unsafe path %q", localPath)
	}
	abs := filepath.Join(root, filepath.FromSlash(localPath))
	if filepath.Clean(abs) == filepath.Clean(root) {
		return fmt.Errorf("refusing to clear the repository root")
	}
	return os.RemoveAll(abs)
}

// copyTreeOver copies everything under src over dst: files present in src
// overwrite their dst counterparts, files that exist only in dst survive
// (union copy). Used to lay a backed-up crossed dir back over a fresh upstream
// checkout: local content wins, files new upstream stay.
func copyTreeOver(src, dst string) error {
	return filepath.Walk(src, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, rerr := filepath.Rel(src, path)
		if rerr != nil {
			return rerr
		}
		if rel == "." {
			return nil
		}
		target := filepath.Join(dst, rel)
		if info.IsDir() {
			return os.MkdirAll(target, info.Mode().Perm())
		}
		if info.Mode()&os.ModeSymlink != 0 {
			link, lerr := os.Readlink(path)
			if lerr != nil {
				return lerr
			}
			if rerr := os.Remove(target); rerr != nil && !os.IsNotExist(rerr) {
				return rerr
			}
			return os.Symlink(link, target)
		}
		if !info.Mode().IsRegular() {
			return nil // sockets/FIFOs/devices have no business in a crossed dir
		}
		in, ierr := os.Open(path)
		if ierr != nil {
			return ierr
		}
		defer in.Close()
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}
		out, oerr := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, info.Mode().Perm())
		if oerr != nil {
			return oerr
		}
		if _, cerr := io.Copy(out, in); cerr != nil {
			out.Close()
			return cerr
		}
		return out.Close()
	})
}

// readoptLostCross re-initializes one lost cross end to end: it checks for
// uncommitted work, asks how to proceed (wipe / stash-then-wipe / preserve),
// performs the destructive part and then runs adopt to re-create the cross from
// upstream. adopt runs INSIDE the preserve flow, so the backup copy lands over
// the fresh work tree. A dirty dir is never deleted: the prompt offers to stash
// the changes first (--force stashes too), and preserve keeps them in place
// through backup + copy-back. declined=true means the user skipped the cross.
func readoptLostCross(root, localPath string, force bool, adopt func() error) (declined bool, err error) {
	dirty := crossHasUncommitted(root, localPath)
	choice, cerr := confirmReadopt(root, localPath, dirty, force)
	if cerr != nil {
		return false, cerr
	}
	switch choice {
	case readoptDecline:
		return true, nil
	case readoptPreserve:
		if perr := readoptPreserving(root, localPath, adopt); perr != nil {
			return false, perr
		}
		logInfo(fmt.Sprintf("Re-adopting %s from upstream (local content preserved)", localPath))
		return false, nil
	case readoptStash:
		if _, serr := stashCross(root, localPath); serr != nil {
			return false, serr
		}
		if cerr := forceClearDir(root, localPath); cerr != nil {
			return false, cerr
		}
		logInfo(fmt.Sprintf("Re-adopting %s from upstream (uncommitted changes stashed, existing dir wiped)", localPath))
	default: // readoptWipe
		if cerr := forceClearDir(root, localPath); cerr != nil {
			return false, cerr
		}
		logInfo(fmt.Sprintf("Re-adopting %s from upstream (existing dir wiped)", localPath))
	}
	return false, adopt()
}

// readoptPreserving re-adopts a lost cross from upstream while preserving the
// crossed dir's current content: the dir is temporarily moved aside (a backup
// under .cross/, which is disposable and gitignored), the adopt callback
// re-creates the cross from upstream (the normal set flow), then the backup is
// copied back over the fresh work tree — local files win, files that are new
// upstream survive — the result is staged, and the backup is removed.
// On failure the backup is KEPT and its path is in the error: local content
// is never lost.
func readoptPreserving(root, localPath string, adopt func() error) error {
	if localPath == "" || localPath == "." || localPath == ".." ||
		strings.HasPrefix(localPath, "../") || filepath.IsAbs(filepath.FromSlash(localPath)) {
		return fmt.Errorf("refusing to preserve unsafe path %q", localPath)
	}
	localAbs := filepath.Join(root, filepath.FromSlash(localPath))
	crossDir := filepath.Join(root, filepath.FromSlash(".cross"))
	if err := os.MkdirAll(crossDir, 0o755); err != nil {
		return err
	}
	backup, err := os.MkdirTemp(crossDir, "backup-")
	if err != nil {
		return err
	}
	saved := filepath.Join(backup, filepath.Base(localAbs))
	if err := os.Rename(localAbs, saved); err != nil {
		os.RemoveAll(backup)
		return fmt.Errorf("backing up %s failed: %w", localPath, err)
	}
	if rel, rerr := filepath.Rel(root, saved); rerr == nil {
		logInfo(fmt.Sprintf("Backed up %s to %s (temporary)", localPath, filepath.ToSlash(rel)))
	}
	// Re-create the cross from upstream while the dir is parked aside.
	if err := adopt(); err != nil {
		return fmt.Errorf("re-adoption failed; local content kept at %s: %w", saved, err)
	}
	// Copy the backup back over the fresh upstream checkout (local wins).
	if err := copyTreeOver(saved, localAbs); err != nil {
		return fmt.Errorf("restoring local content failed; backup kept at %s: %w", saved, err)
	}
	// Stage the restored content so the index matches the work tree (set
	// staged the upstream materialization; the copy-back changed it).
	add := exec.Command("git", "add", filepath.FromSlash(localPath))
	add.Dir = root
	if add.Run() != nil {
		logWarn(fmt.Sprintf("git add %s failed", localPath))
	}
	if err := os.RemoveAll(backup); err != nil {
		logWarn(fmt.Sprintf("could not remove the temporary backup %s: %v", backup, err))
	}
	return nil
}

// -------------------------------------------------------------- passthrough --

// crossCommandNames are the subcommands (plus hidden aliases) a typo can hit.
var crossCommandNames = []string{
	"use", "set", "del", "cfg", "update", "resolve", "ls", "cd", "wt",
	"comp", "wipe", "env", "list", "completion", "init", "shell-init", "help",
}

// knownGitCommands keeps the crossed-dir hint for real git commands typed at
// the passthrough: `git cross status` outside a cross must NOT suggest 'stat'.
var knownGitCommands = map[string]bool{
	"status": true, "log": true, "diff": true, "add": true, "commit": true,
	"push": true, "pull": true, "fetch": true, "rebase": true, "merge": true,
	"branch": true, "tag": true, "checkout": true, "remote": true, "clone": true,
	"stash": true, "show": true, "grep": true, "restore": true, "switch": true,
	"rm": true, "mv": true, "reset": true, "clean": true, "init": true,
}

// suggestCrossCommand returns the closest git-cross command for a mistyped
// subcommand (prefix or embedded-subsequence match, e.g. "commp" -> "comp"),
// or "" when the input is not a plausible typo.
func suggestCrossCommand(input string) string {
	in := strings.TrimSpace(input)
	if len(in) < 2 || knownGitCommands[in] {
		return ""
	}
	best := ""
	for _, name := range crossCommandNames {
		if in == name {
			return "" // exact names never reach the passthrough, but be safe
		}
		if strings.HasPrefix(in, name) || strings.HasPrefix(name, in) || isSubsequence(name, in) {
			if len(name) > len(best) {
				best = name
			}
		}
	}
	return best
}

func isSubsequence(needle, haystack string) bool {
	i := 0
	for j := 0; j < len(haystack) && i < len(needle); j++ {
		if needle[i] == haystack[j] {
			i++
		}
	}
	return i == len(needle)
}

// gitPassthrough runs git with the patch's upstream context. It REQUIRES a patch
// directory: outside one there is no GIT_DIR/GIT_WORK_TREE to configure, so the
// command fails early instead of silently operating on the primary repo.
// Git's own exit status is propagated.
func gitPassthrough(args []string) error {
	// --debug (or CROSS_DEBUG=1): print the resolved context, the env git will
	// get, and the exact git invocation — for troubleshooting `git cross` aliases.
	debug := os.Getenv("CROSS_DEBUG") == "1"
	if len(args) > 0 && args[0] == "--debug" {
		debug = true
		args = args[1:]
	}
	var patch *Patch
	root, rerr := getRepoRoot()
	if rerr == nil {
		meta, _ := loadMetadata()
		if p, perr := findPatchForPathFromCWD(meta); perr == nil {
			patch = p
		}
	}
	if debug {
		cwd, _ := os.Getwd()
		rel, _ := cwdRepoRelative(root)
		fmt.Fprintf(os.Stderr, "[cross] cwd=%s GIT_PREFIX=%q rel=%q\n", cwd, os.Getenv("GIT_PREFIX"), rel)
		if patch != nil {
			fmt.Fprintf(os.Stderr, "[cross] patch=%s GIT_DIR=%s GIT_WORK_TREE=%s\n",
				patch.LocalPath, patch.gitdirAbs(root), patch.localAbs(root))
		} else {
			fmt.Fprintln(os.Stderr, "[cross] patch=<none> (no cross matches the working directory)")
		}
		fmt.Fprintf(os.Stderr, "[cross] git %s\n", strings.Join(args, " "))
	}
	if patch == nil {
		// A mistyped cross command (e.g. "commp") should say so and suggest
		// the closest command — not the generic crossed-dir hint.
		if len(args) > 0 {
			if sugg := suggestCrossCommand(args[0]); sugg != "" {
				logError(fmt.Sprintf("'%s' is not a git-cross command (did you mean: %s?)", args[0], sugg))
				fmt.Fprintln(os.Stderr, "  see: git cross --help    (inside a crossed dir, 'git cross <git-args>' runs git on its upstream)")
				os.Exit(1)
			}
		}
		logError("not inside a crossed directory: 'git cross <git-args>' runs git on the crossed dir's upstream and needs one")
		fmt.Fprintln(os.Stderr, "  cd into a crossed dir first:  xcd [path] (wrapper from: git cross comp; git cross cd prints the path)")
		fmt.Fprintln(os.Stderr, "  for THIS repository use plain `git` instead of `git cross`")
		os.Exit(1) // contextual failure: exits directly, no duplicate cobra "Error:" line
	}
	root, _ = getRepoRoot() // already resolved above (debug block); refresh in case getRepoRoot failed
	// D3(c) (ADR-004): subdirectory crosses intercept pull/push — the plain
	// passthrough forms would mix the synthesized and real histories.
	if patch != nil && len(args) > 0 && patch.RemotePath != "." && patch.RemotePath != "/" {
		switch args[0] {
		case "pull":
			return crossPullSubtree(root, patch, args[1:])
		case "push":
			return crossPushSubtree(root, patch, args[1:])
		}
	}
	c := runPatchGit(root, patch, args...)
	c.Stdin, c.Stdout, c.Stderr = os.Stdin, os.Stdout, os.Stderr
	if err := c.Run(); err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			os.Exit(exitErr.ExitCode())
		}
		return err
	}
	return nil
}

// ------------------------------------------------------- shell integration ---

const posixShellInit = `# git-cross shell wrappers (part of: eval "$(git cross comp bash|zsh)")
# xcd cds into a cross AND loads its upstream git context (opt out: GIT_CROSS_NO_AUTOENV=1)
#   xcd            pick a cross with fzf (also when you are already inside one)
#   xcd <path>     go to that cross
#   xcd -          ESCAPE: back to the previous dir, context unloaded
# Plain 'cd' out of the crossed dir unloads too (_git_cross_sync), and Ctrl-D just
# ends the shell — the context dies with it, nothing to undo.
xcd() { local p
    case "${1-}" in
        "") p="$(git cross cd --pick)" || return ;;
        -)  p=- ;;
        *)  p="$(git cross cd "$@")" || return ;;
    esac
    [ -n "$p" ] || return 0
    cd "$p" || return
    # quiet: "not inside a cross" is the normal case for 'xcd -' (it unloads)
    if [ -z "${GIT_CROSS_NO_AUTOENV-}" ]; then _git_cross_load 2>/dev/null; fi
}
gx() { if [ "$1" = "cd" ]; then shift; xcd "$@"; else git cross "$@"; fi; }   # short alias for git cross (gx cd changes directory)
cr() { git cross "$@"; }     # short alias for git cross: cr log --oneline
# --- gxenv / sync: plain 'git' speaks the crossed dir's UPSTREAM while loaded ---
#   gxenv [path]      load into THIS shell (the prompt gains a [cross] marker)
#   gxenv -u          unload from this shell (marker removed)
#   gxenv -s [path]   isolated nested shell instead (leave it to unload; unmarked)
# Leaving the crossed dir unloads automatically (_git_cross_sync): zsh via a chpwd
# hook, bash via an appended PROMPT_COMMAND (interactive shells only), fish via
# --on-variable PWD. The check is one shell pattern match — no subprocess.
# GIT_CROSS_MARKER: style of the prompt marker (export it to taste).
#   %r = remote name (falls back to the local path), %l = local path
#   default: GIT_CROSS_MARKER='[cross:%r]'   ->   "[cross:infra] "
_git_cross_mark() {
    local m="${GIT_CROSS_MARKER-[cross:%r]}" p_remote=%r p_local=%l
    # patterns via variables: a literal % in a zsh pattern is not matched
    m=${m//$p_remote/${CROSS_REMOTE:-${CROSS_ACTIVE-}}}
    m=${m//$p_local/${CROSS_ACTIVE-}}
    _GIT_CROSS_MARK="$m "
}
_git_cross_prompt_on() {
    _git_cross_prompt_off   # re-loading (another cross) re-marks; it never stacks
    _git_cross_mark
    if [ -n "${ZSH_VERSION-}" ]; then
        _git_cross_zsh_precmd_add
        _git_cross_zsh_precmd
    else
        _GIT_CROSS_PS1_SAVED="${PS1-}"
        PS1="${PS1-}${_GIT_CROSS_MARK}"
    fi
}
# zsh themes (powerlevel10k/starship/oh-my-zsh) rebuild PROMPT every prompt, so a
# one-shot append is wiped: this precmd hook runs AFTER them and appends if absent.
_git_cross_zsh_precmd() {
    case "${PROMPT-}" in
        *"${_GIT_CROSS_MARK-}") ;;
        *) PROMPT="${PROMPT-}${_GIT_CROSS_MARK-}" ;;
    esac
}
_git_cross_prompt_off() {
    if [ -n "${ZSH_VERSION-}" ]; then
        precmd_functions=(${precmd_functions:#_git_cross_zsh_precmd})
        case "${PROMPT-}" in
            *"${_GIT_CROSS_MARK-}") PROMPT="${PROMPT%"${_GIT_CROSS_MARK-}"}" ;;
        esac
    elif [ -n "${_GIT_CROSS_PS1_SAVED+x}" ]; then
        PS1="$_GIT_CROSS_PS1_SAVED"; unset _GIT_CROSS_PS1_SAVED
    fi
    return 0
}
_git_cross_unload() {
    eval "$(git cross env --unset)"
    _git_cross_prompt_off
    unset _GIT_CROSS_ROOT _GIT_CROSS_MARK
}
_git_cross_load() {
    _git_cross_unload
    local src
    src=$(git cross env "${1-}") || return 1
    eval "$src" || return 1
    _GIT_CROSS_ROOT="${GIT_WORK_TREE-}"
    _git_cross_prompt_on
}
_git_cross_sync() {
    [ -n "${_GIT_CROSS_ROOT-}" ] || return 0
    case "$PWD/" in
        "${_GIT_CROSS_ROOT%/}/"*) return 0 ;;
    esac
    _git_cross_unload
}
# zsh hook arrays are built in: no dependence on add-zsh-hook (which lives in
# zsh-common and is missing from stripped installs). Ours are appended LAST, so
# prompt decoration runs after the theme's own precmd.
_git_cross_zsh_chpwd_add() {
    case " ${chpwd_functions[*]-} " in *" _git_cross_sync "*) ;; *) chpwd_functions+=(_git_cross_sync) ;; esac
}
_git_cross_zsh_precmd_add() {
    case " ${precmd_functions[*]-} " in *" _git_cross_zsh_precmd "*) ;; *) precmd_functions+=(_git_cross_zsh_precmd) ;; esac
}
_git_cross_hook() {
    if [ -n "${ZSH_VERSION-}" ]; then
        _git_cross_zsh_chpwd_add
        return 0
    fi
    case "${PROMPT_COMMAND-}" in
        *_git_cross_sync*) ;;
        *) PROMPT_COMMAND="${PROMPT_COMMAND:+${PROMPT_COMMAND%;}; }_git_cross_sync" ;;
    esac
}
_git_cross_hook
gxenv() {
    local subshell=0
    case "${1-}" in
        -u|--unset) _git_cross_unload; return 0 ;;
        -s|--subshell) subshell=1; shift ;;
        -i|--in-place) shift ;;   # in-place is the default; kept for muscle memory
        -h|--help) echo 'usage: gxenv [-u|--unset|-s|--subshell|-i|--in-place] [path]'
            echo '  (default) load the cross upstream context into this shell'
            echo '  -s        do it in a nested shell instead (leave it to unload)'
            echo '  -u        unload from this shell'; return 0 ;;
    esac
    if [ "$subshell" = 1 ]; then
        local gd wt lp rm
        gd=$(git cross env --gitdir "$@") || return
        wt=$(git cross env --worktree "$@") || return
        lp=$(git cross env --local-path "$@") || return
        rm=$(git cross env --remote "$@") || return
        GIT_DIR=$gd GIT_WORK_TREE=$wt CROSS_ACTIVE=$lp CROSS_REMOTE=$rm "${SHELL:-/bin/sh}" -i
        return 0
    fi
    _git_cross_load "$@"
}
# optional git alias so 'git x add ./file' also works:
#   git config --global alias.x '!git cross'
`

const fishShellInit = `# git-cross shell wrappers (part of: git cross comp fish | source)
# xcd cds into a cross AND loads its upstream git context (opt out: set -gx GIT_CROSS_NO_AUTOENV 1)
#   xcd            pick a cross with fzf (also when you are already inside one)
#   xcd <path>     go to that cross
#   xcd -          ESCAPE: back to the previous dir, context unloaded
# Plain 'cd' out of the crossed dir unloads too (_git_cross_sync), and Ctrl-D just
# ends the shell — the context dies with it, nothing to undo.
function xcd --description 'cd into a crossed dir (no arg: picker; -: back) and load its context'
    set -l p
    switch "$argv[1]"
        case ''
            set p (git cross cd --pick); or return
        case '-'
            set p -
        case '*'
            set p (git cross cd $argv); or return
    end
    test -n "$p"; or return
    cd $p; or return
    # quiet: "not inside a cross" is the normal case for 'xcd -' (it unloads)
    if not set -q GIT_CROSS_NO_AUTOENV
        _git_cross_load 2>/dev/null
    end
end
function gx --description 'short alias for git cross (gx cd changes directory)'
    if begin; test (count $argv) -ge 1; and test $argv[1] = cd; end
        set -l rest $argv
        set -e rest[1]
        xcd $rest
    else
        git cross $argv
    end
end
function cr --description 'short alias for git cross'
    git cross $argv
end
# --- gxenv / sync: plain 'git' speaks the crossed dir's UPSTREAM while loaded ---
#   gxenv [path]      load into THIS fish (the prompt gains a [cross] marker)
#   gxenv -u          unload from this fish (marker removed)
#   gxenv -s [path]   isolated nested shell instead (leave it to unload; unmarked)
# Leaving the crossed dir unloads automatically (--on-variable PWD, a pure string
# comparison — no subprocess).
# GIT_CROSS_MARKER: style of the prompt marker (set -gx to taste).
#   %r = remote name (falls back to the local path), %l = local path
#   default: [cross:%r]   ->   "[cross:infra] "
function _git_cross_mark
    set -l m '[cross:%r]'
    if set -q GIT_CROSS_MARKER
        set m $GIT_CROSS_MARKER
    end
    set -l remote $CROSS_ACTIVE
    if set -q CROSS_REMOTE
        set remote $CROSS_REMOTE
    end
    set -g _GIT_CROSS_MARK (string replace -a '%r' $remote -- $m | string replace -a '%l' $CROSS_ACTIVE)" "
end
function _git_cross_prompt_on
    if set -q __git_cross_wrapped
        return 0
    end
    _git_cross_mark
    functions -c fish_prompt __git_cross_orig_prompt; or return 0
    function fish_prompt
        __git_cross_orig_prompt
        echo -n $_GIT_CROSS_MARK
    end
    set -g __git_cross_wrapped 1
end
function _git_cross_prompt_off
    if not set -q __git_cross_wrapped
        return 0
    end
    functions -e fish_prompt
    functions -c __git_cross_orig_prompt fish_prompt
    functions -e __git_cross_orig_prompt
    set -e __git_cross_wrapped
end
function _git_cross_unload
    git cross env --fish --unset | source
    _git_cross_prompt_off
    set -e _GIT_CROSS_ROOT _GIT_CROSS_MARK
end
function _git_cross_load
    _git_cross_unload
    git cross env --fish $argv | source
    set -q GIT_DIR; or return 1
    set -g _GIT_CROSS_ROOT $GIT_WORK_TREE
    _git_cross_prompt_on
end
function _git_cross_sync --on-variable PWD
    if not set -q _GIT_CROSS_ROOT
        return 0
    end
    switch $PWD/
        case "$_GIT_CROSS_ROOT/*"
            return 0
    end
    _git_cross_unload
end
function gxenv --description 'plain git in a crossed dir speaks to its upstream'
    switch "$argv[1]"
        case -u --unset
            _git_cross_unload
            return
        case -s --subshell
            set -l gd (git cross env --gitdir $argv[2..-1]); or return
            set -l wt (git cross env --worktree $argv[2..-1]); or return
            set -l lp (git cross env --local-path $argv[2..-1]); or return
            set -l rm (git cross env --remote $argv[2..-1]); or return
            GIT_DIR=$gd GIT_WORK_TREE=$wt CROSS_ACTIVE=$lp CROSS_REMOTE=$rm $SHELL -i
            return
        case -i --in-place
            set -e argv[1]
        case -h --help
            echo 'usage: gxenv [-u|--unset|-s|--subshell|-i|--in-place] [path]'
            echo '  (default) load the cross upstream context into this fish'
            echo '  -s        do it in a nested shell instead (leave it to unload)'
            echo '  -u        unload from this fish'
            return
    end
    _git_cross_load $argv
end
# optional git alias so 'git x add ./file' also works:
#   git config --global alias.x '!git cross'
`

func shellIntegrationHint() string {
	if strings.ToLower(filepath.Base(strings.TrimSpace(os.Getenv("SHELL")))) == "fish" {
		return "Shell integration (xcd + gx/cr aliases): git cross comp fish | source"
	}
	return `Shell integration (xcd + gx/cr aliases): eval "$(git cross comp)"`
}

// xcdHint tells interactive users how to actually change directories:
// a subprocess cannot cd the caller's shell — the xcd wrapper can.
func xcdHint() string {
	if strings.ToLower(filepath.Base(strings.TrimSpace(os.Getenv("SHELL")))) == "fish" {
		return "hint: only the path is printed (a subprocess cannot cd your shell); use 'xcd <path>' - from: git cross comp fish | source"
	}
	return `hint: only the path is printed (a subprocess cannot cd your shell); use 'xcd <path>' - from: eval "$(git cross comp)"`
}

const supportedShells = "fish, bash, zsh, powershell"

func resolveShell(args []string) (string, error) {
	var shell string
	if len(args) > 0 {
		shell = strings.ToLower(strings.TrimSpace(args[0]))
	} else if env := strings.TrimSpace(os.Getenv("SHELL")); env != "" {
		shell = strings.ToLower(filepath.Base(env))
	}
	if shell == "" {
		return "", fmt.Errorf("cannot detect shell from $SHELL; specify one: %s", supportedShells)
	}
	switch shell {
	case "fish", "bash", "zsh", "powershell", "pwsh":
		return shell, nil
	default:
		return "", fmt.Errorf("unsupported shell %q (supported: %s)", shell, supportedShells)
	}
}

// ------------------------------------------------------------------- main ----

func main() {
	cobra.EnableCommandSorting = false
	rootCmd := &cobra.Command{
		Use:          "git-cross",
		Version:      "0.5.0",
		Short:        "Manage crossed directories (upstream gitdirs + in-repo work trees)",
		SilenceUsage: true,
		Long: `Manage crossed directories: a cross vendors an upstream repository path
into your repo as plain files. Each cross keeps a standalone bare gitdir under
.cross/worktrees/<remote>/<patch>/ (the upstream ".git" content) while its work
tree is the crossed directory in your repo — plain files, tracked by your repo
like any other file. No rsync, no linked worktrees, no remotes in your repo.

update fetches every cross, then lands upstream in the crossed dir and re-applies
your committed changes on top (one three-way apply, rerere-aware). Unstaged edits
are refused; collisions stay as unmerged paths -> finish with: git cross resolve

Inside a crossed directory, use 'git cross <git command>' to perform its upstream
git operations (status, diff, log, push, pull, rebase, ...). Anywhere else, plain
'git' behaves as it would in your repo — 'git cross' is a wrapper for crossed
directories and fails early with a hint when there is no cross to operate on.

  xcd [path]                   cd into a crossed directory (wrapper from: git cross comp)

Crossed paths/dir operations: use, set, del, cfg, update, resolve.
git cross overview: ls, comp, wipe.

Configuration (git config):
  cross.depth        shallow clone depth used by 'set' (opt-in, e.g. 1)
  cross.filter       partial clone filter used by 'set' (opt-in, e.g. blob:none)

Shell integration (defines xcd + gxenv, plus the gx/cr short aliases for git cross):
  fish       git cross comp fish | source
  bash/zsh   eval "$(git cross comp)"

Inside a crossed dir, 'gxenv' opens a nested shell where plain 'git' speaks to
that cross's UPSTREAM (exit to unload); 'gxenv -i' loads it into the current
shell and 'gxenv -u' unloads it.`,
		Args:               cobra.ArbitraryArgs,
		DisableFlagParsing: true, // native git args (--oneline, -v, ...) belong to the passthrough
		RunE: func(cmd *cobra.Command, args []string) error {
			if len(args) == 0 {
				return printPatchRows("")
			}
			switch args[0] {
			case "-h", "--help":
				return cmd.Help()
			case "--version":
				fmt.Printf("git-cross version %s\n", crossVersion)
				return nil
			}
			return gitPassthrough(args)
		},
		CompletionOptions: cobra.CompletionOptions{DisableDefaultCmd: true},
	}
	rootCmd.AddGroup(
		&cobra.Group{ID: "crosses", Title: "Crossed paths/dir operations:"},
		&cobra.Group{ID: "overview", Title: "git cross overview:"},
	)
	rootCmd.SetHelpCommand(&cobra.Command{
		Use:     "help [command]",
		Short:   "Help about any command",
		GroupID: "overview",
		Run: func(c *cobra.Command, args []string) {
			target, _, err := c.Root().Find(args)
			if target == nil || err != nil {
				c.Printf("Unknown help topic %q\n", args)
				_ = c.Root().Usage()
				return
			}
			target.InitDefaultHelpFlag()
			_ = target.Help()
		},
	})

	// useRemote registers/validates a remote in metadata (no primary git remotes).
	// Re-pointing (same name, new URL) follows the URL everywhere it is
	// recorded — the Crossfile line, the metadata remote AND the per-patch
	// remote_url, plus every gitdir's origin — so later updates cannot keep
	// fetching the retired URL.
	useRemote := func(name, url string) error {
		if out, err := exec.Command("git", "ls-remote", "--heads", url).CombinedOutput(); err != nil {
			return fmt.Errorf("cannot reach remote %s: %s: %w", url, strings.TrimSpace(string(out)), err)
		}
		meta, err := loadMetadata()
		if err != nil {
			return err
		}
		if oldURL := remoteURL(meta, name); oldURL != "" && oldURL != url {
			logInfo(fmt.Sprintf("Re-pointing remote %s: %s -> %s (metadata, Crossfile and gitdir origins follow)", name, oldURL, url))
			root, rerr := getRepoRoot()
			if rerr != nil {
				return rerr
			}
			for i := range meta.Patches {
				if meta.Patches[i].Remote != name {
					continue
				}
				meta.Patches[i].RemoteURL = url
				gdAbs := meta.Patches[i].gitdirAbs(root)
				if _, serr := os.Stat(gdAbs); serr == nil {
					if rc := runGitdir(gdAbs, "remote", "set-url", "origin", url); rc.Run() != nil {
						logWarn(fmt.Sprintf("could not re-point origin in %s", meta.Patches[i].Gitdir))
					}
				}
			}
		}
		upsertRemote(&meta, name, url)
		if err := saveMetadata(meta); err != nil {
			return err
		}
		return updateCrossfileUseLine(name, url)
	}

	useCmd := &cobra.Command{
		Use:     "use [name] [url]",
		Short:   "Register an upstream remote in metadata (your git remotes are not touched)",
		GroupID: "crosses",
		Args:    cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			if err := useRemote(args[0], args[1]); err != nil {
				return err
			}
			logSuccess(fmt.Sprintf("Remote %s registered (%s).", args[0], args[1]))
			return nil
		},
	}

	setCmd := &cobra.Command{
		Use:     "set [spec] [local_path]",
		Short:   "Set a cross directory: vendor an upstream path into your repo (bare gitdir + in-repo work tree)",
		GroupID: "crosses",
		Args:    cobra.MinimumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			spec, err := parsePatchSpec(args[0])
			if err != nil {
				return err
			}

			localPath := ""
			if len(args) > 1 {
				localPath = args[1]
			}
			if localPath == "" {
				localPath = filepath.Base(spec.RemotePath)
			}
			localPath = filepath.ToSlash(filepath.Clean(localPath)) // "./mxc2" -> "mxc2"
			if localPath == "." {
				return fmt.Errorf("local_path is required when setting the whole repo (remote path '.')")
			}

			root, err := getRepoRoot()
			if err != nil {
				return err
			}

			meta, err := loadMetadata()
			if err != nil {
				return err
			}
			url := remoteURL(meta, spec.Remote)
			if url == "" {
				return fmt.Errorf("remote %s is not registered. Run: git cross use %s <url>", spec.Remote, spec.Remote)
			}

			if !spec.BranchProvided {
				logInfo("Autodetecting default branch...")
				branch, berr := detectDefaultBranch(url)
				if berr != nil {
					logError(fmt.Sprintf("Failed to detect branch: %v. Falling back to main.", berr))
					branch = "main"
				}
				spec.Branch = branch
				logInfo(fmt.Sprintf("Using branch: %s", spec.Branch))
			}
			if spec.Branch == "" {
				spec.Branch = "main"
			}

			gd := patchGitdir(spec.Remote, localPath)
			gdAbs := filepath.Join(root, filepath.FromSlash(gd))
			localAbs := filepath.Join(root, filepath.FromSlash(localPath))

			// Already registered? Suggest update instead of re-installing.
			for i := range meta.Patches {
				if meta.Patches[i].LocalPath == localPath {
					logInfo(fmt.Sprintf("Cross already registered at %s. Refresh it with: git cross update %s", localPath, localPath))
					return nil
				}
			}
			// Gitdir name collision from a different local_path? Refuse.
			for _, p := range meta.Patches {
				if p.Gitdir == gd && p.LocalPath != localPath {
					return fmt.Errorf("gitdir %s already used by another cross (%s). Delete it first: git cross del %s", gd, p.LocalPath, p.LocalPath)
				}
			}
			// Not registered but the dir is already there: never silently overwrite it.
			// update --force wipes it first, so this only fires on a direct `set`.
			if _, lerr := os.Stat(localAbs); lerr == nil {
				return fmt.Errorf("Local path %s exists but is not registered; refusing to overwrite it (add it to Crossfile and run: git cross update --force — or remove the directory)", localPath)
			}

			canonical := canonicalSpec(spec)
			logInfo(fmt.Sprintf("Setting cross %s -> %s", canonical, localPath))

			if _, err := os.Stat(gdAbs); os.IsNotExist(err) {
				logInfo(fmt.Sprintf("Cloning upstream into %s (bare)...", gd))
				cloneArgs := []string{"clone", "--bare"}
				// opt-in shallow/partial clone via git config cross.depth / cross.filter
				if depth, cerr := exec.Command("git", "-C", root, "config", "--get", "cross.depth").Output(); cerr == nil {
					if d := strings.TrimSpace(string(depth)); d != "" {
						cloneArgs = append(cloneArgs, "--depth", d)
					}
				}
				if filter, cerr := exec.Command("git", "-C", root, "config", "--get", "cross.filter").Output(); cerr == nil {
					if f := strings.TrimSpace(string(filter)); f != "" {
						cloneArgs = append(cloneArgs, "--filter", f)
					}
				}
				cloneArgs = append(cloneArgs, "--branch", spec.Branch, url, gdAbs)
				c := exec.Command("git", cloneArgs...)
				c.Dir = root
				c.Stdout, c.Stderr = os.Stdout, os.Stderr
				if err := c.Run(); err != nil {
					os.RemoveAll(gdAbs)
					return fmt.Errorf("git clone failed for %s (%s): %w", spec.Remote, url, err)
				}

				// Remember conflict resolutions in this standalone gitdir.
				if gc := runGitdir(gdAbs, "config", "rerere.enabled", "true"); gc.Run() != nil {
					logWarn("could not enable rerere in gitdir")
				}

				if spec.RemotePath != "." && spec.RemotePath != "/" {
					// D3(c) (ADR-004): re-root the cross at the upstream subtree. The
					// gitdir's branch becomes a synthesized subtree history (original
					// authorship and dates — deterministic; outside-only commits
					// skipped), so the crossed dir holds the subtree's CONTENT at
					// its root and the cross context (status/diff/log/pull -r)
					// stays sane. No sparse config: HEAD's tree already IS the filter.
					if tOut, terr := runGitdir(gdAbs, "cat-file", "-t",
						"refs/heads/"+spec.Branch+":"+spec.RemotePath).Output(); terr == nil {
						switch strings.TrimSpace(string(tOut)) {
						case "blob":
							os.RemoveAll(gdAbs)
							return fmt.Errorf("file-level remote_path (%s) is not supported yet — patch its parent directory (planned: 0.6.1)", spec.RemotePath)
						}
					} else {
						os.RemoveAll(gdAbs)
						return fmt.Errorf("remote path %s does not exist in %s:%s", spec.RemotePath, spec.Remote, spec.Branch)
					}
					realTip := strings.TrimSpace(string(runGitdirOut(gdAbs, "rev-parse", "refs/heads/"+spec.Branch)))
					tip, serr := synthesizeSubtree(gdAbs, spec.RemotePath, "refs/heads/"+spec.Branch, "")
					if serr != nil {
						return serr
					}
					if tip == "" {
						return fmt.Errorf("remote path %s produced no history in %s:%s", spec.RemotePath, spec.Remote, spec.Branch)
					}
					if uerr := runGitdir(gdAbs, "update-ref", "refs/heads/"+spec.Branch, tip).Run(); uerr != nil {
						return fmt.Errorf("could not install the subtree history for %s: %w", gd, uerr)
					}
					_ = runGitdir(gdAbs, "update-ref", synthRef(spec.Branch), tip).Run()
					_ = runGitdir(gdAbs, "update-ref", upstreamRef(spec.Branch), realTip).Run()
					if herr := writeCrossGuards(gdAbs); herr != nil {
						return herr
					}
					ensureGitdirIdentity(gdAbs)
					logInfo(fmt.Sprintf("Subtree cross: %s holds the content of %s:%s (re-rooted; synthesized history)", localPath, spec.Remote, spec.RemotePath))
				}

				if err := os.MkdirAll(localAbs, 0o755); err != nil {
					return err
				}
				// Materialize the work tree in place (no rsync).
				c = exec.Command("git", "--git-dir", gdAbs, "--work-tree", localAbs, "read-tree", "-mu", "HEAD")
				c.Dir = root
				if out, err := c.CombinedOutput(); err != nil {
					return fmt.Errorf("read-tree failed: %v\n%s", err, string(out))
				}
			} else if _, lerr := os.Stat(localAbs); os.IsNotExist(lerr) {
				// Orphaned gitdir (e.g. metadata was lost): re-materialize only.
				if spec.RemotePath != "." && spec.RemotePath != "/" {
					if _, merr := runGitdir(gdAbs, "rev-parse", "-q", "--verify", upstreamRef(spec.Branch)).Output(); merr != nil {
						return fmt.Errorf("orphaned pre-0.6 subdir gitdir at %s; remove it (rm -rf %s) and keep the Crossfile line, then: git cross update — or sweep orphans: git cross wipe", gd, gd)
					}
				}
				logInfo(fmt.Sprintf("Reusing existing gitdir %s", gd))
				if err := os.MkdirAll(localAbs, 0o755); err != nil {
					return err
				}
				c := exec.Command("git", "--git-dir", gdAbs, "--work-tree", localAbs, "read-tree", "-mu", "HEAD")
				c.Dir = root
				if out, err := c.CombinedOutput(); err != nil {
					return fmt.Errorf("read-tree failed: %v\n%s", err, string(out))
				}
			}

			ensureGitignore()

			// Primary tracks the patch files as normal files.
			add := exec.Command("git", "add", filepath.FromSlash(localPath))
			add.Dir = root
			if add.Run() != nil {
				logWarn(fmt.Sprintf("git add %s failed", localPath))
			}

			entry := Patch{
				Remote: spec.Remote, RemoteURL: url, RemotePath: spec.RemotePath,
				LocalPath: localPath, Worktree: localPath, Gitdir: gd, Branch: spec.Branch,
			}
			out := meta.Patches[:0]
			for _, p := range meta.Patches {
				if p.LocalPath != localPath {
					out = append(out, p)
				}
			}
			meta.Patches = append(out, entry)
			if err := saveMetadata(meta); err != nil {
				return err
			}

			if err := updateCrossfile(fmt.Sprintf("set %s %s", canonicalSpec(spec), localPath)); err != nil {
				return err
			}
			logSuccess("Cross set successfully.")
			return nil
		},
	}

	var noResolve, doResolve, doContinue, doAbort, force bool
	updateCmd := &cobra.Command{
		Use:     "update [path]",
		Short:   "Fetch upstream and land it in the crossed dir, re-applying your changes",
		GroupID: "crosses",
		Args:    cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			root, err := getRepoRoot()
			if err != nil {
				return err
			}
			if ensureRerere("-C", root) {
				logInfo("Enabled rerere: conflict resolutions are remembered for later updates.")
			}
			crossfile, err := getCrossfilePath()
			if err != nil {
				return err
			}
			meta, err := loadMetadata()
			if err != nil {
				return err
			}
			// The Crossfile is the source of truth for update. A missing or
			// emptied Crossfile while crosses are still registered means the
			// records were lost (hand edit, git revert of an uncommitted
			// Crossfile, ...) — refuse to run silently: every later update
			// would quietly degrade to "No crosses to update." while the
			// registered crosses rot. No git-cross command deletes records;
			// this guard makes the loss loud and recoverable.
			if _, serr := os.Stat(crossfile); serr != nil {
				if len(meta.Patches) > 0 {
					return fmt.Errorf("Crossfile is missing, but %d cross(es) are still registered; restore the records (git checkout -- Crossfile, if committed) or re-declare them: cross use <name> <url> + cross set <remote>[:<branch>]:<path> <local_path>", len(meta.Patches))
				}
				return fmt.Errorf("Crossfile not found — configure the repo first: git cross cfg")
			}
			commands, err := crossfileCommands(crossfile)
			if err != nil {
				return err
			}
			setDecls := 0
			for _, fields := range commands {
				if fields[0] == "set" || fields[0] == "patch" {
					setDecls++
				}
			}
			if setDecls == 0 && len(meta.Patches) > 0 {
				return fmt.Errorf("Crossfile has no cross declarations, but %d cross(es) are still registered; the records were lost — restore them (git checkout -- Crossfile, if committed) or re-declare: cross set <remote>[:<branch>]:<path> <local_path>", len(meta.Patches))
			}
			// Registry hygiene: entries the Crossfile no longer declares are
			// stale state (the Crossfile is the source of truth). update only
			// walks declared crosses, so they would silently linger in `ls`;
			// name them once and point at the cleanup (crossed dirs stay).
			if stale := undeclaredPatches(commands, meta); len(stale) > 0 {
				logWarn(fmt.Sprintf("%d registered cross(es) no longer declared in Crossfile (%s); clean up with: git cross wipe", len(stale), strings.Join(stale, ", ")))
			}
			selectedPath := ""
			declined := 0 // crosses not adopted: declined the y/N wipe prompt
			if len(args) > 0 {
				selectedPath, err = resolvePathToRepoRelative(args[0])
				if err != nil {
					return err
				}
			}
			// Pass 1: interpret the Crossfile, creating missing gitdirs/patches.
			// Nothing touches an existing work tree here.
			var targets []Patch
			for _, fields := range commands {
				if fields[0] == "use" {
					if len(fields) != 3 {
						return fmt.Errorf("invalid use declaration in Crossfile: %s", strings.Join(fields, " "))
					}
					if err := useRemote(fields[1], fields[2]); err != nil {
						return err
					}
					continue
				}
				if len(fields) < 2 || len(fields) > 3 {
					return fmt.Errorf("invalid set declaration in Crossfile: %s", strings.Join(fields, " "))
				}
				spec, err := parsePatchSpec(fields[1])
				if err != nil {
					return err
				}
				localPath := filepath.Base(spec.RemotePath)
				if len(fields) == 3 {
					localPath = fields[2]
				}
				localPath = filepath.ToSlash(filepath.Clean(localPath))
				if localPath == "." {
					return fmt.Errorf("updating a repository-root cross is not supported safely yet")
				}
				if localPath == ".." || strings.HasPrefix(localPath, "../") || filepath.IsAbs(filepath.FromSlash(localPath)) {
					return fmt.Errorf("Unsafe local path, refusing to touch it: %s", localPath)
				}
				if selectedPath != "" && selectedPath != localPath {
					continue
				}
				var patch *Patch
				for i := range meta.Patches {
					if meta.Patches[i].LocalPath == localPath {
						patch = &meta.Patches[i]
						break
					}
				}
				if patch == nil {
					adopted := false
					if _, lerr := os.Stat(filepath.Join(root, localPath)); lerr == nil {
						// A dirty dir is no longer refused: the prompt offers to stash
						// (or preserve) uncommitted work before anything is deleted.
						skip, rerr := readoptLostCross(root, localPath, force, func() error {
							return setCmd.RunE(cmd, []string{fields[1], localPath})
						})
						if rerr != nil {
							return rerr
						}
						if skip {
							declined++
							continue
						}
						adopted = true
					}
					if !adopted {
						if err := setCmd.RunE(cmd, []string{fields[1], localPath}); err != nil {
							return err
						}
					}
					meta, err = loadMetadata()
					if err != nil {
						return err
					}
					for i := range meta.Patches {
						if meta.Patches[i].LocalPath == localPath {
							targets = append(targets, meta.Patches[i])
							break
						}
					}
					continue
				}
				if patch.Remote != spec.Remote || filepath.Clean(patch.RemotePath) != filepath.Clean(spec.RemotePath) {
					return fmt.Errorf("Crossfile source for %s changed; delete and re-set it explicitly before updating", localPath)
				}
				if spec.BranchProvided && spec.Branch != patch.Branch {
					return fmt.Errorf("Crossfile branch for %s changed; delete and re-set it explicitly before updating", localPath)
				}
				gdAbs := patch.gitdirAbs(root)
				if _, gerr := os.Stat(gdAbs); os.IsNotExist(gerr) {
					adopted := false
					if _, lerr := os.Stat(patch.localAbs(root)); lerr == nil {
						// Same prompt as the unregistered-dir case above (incl. the
						// stash/preserve handling of uncommitted work).
						skip, rerr := readoptLostCross(root, localPath, force, func() error {
							// Drop the stale registration (the Crossfile line stays); set re-adds it.
							kept := meta.Patches[:0]
							for _, p := range meta.Patches {
								if p.LocalPath != localPath {
									kept = append(kept, p)
								}
							}
							meta.Patches = kept
							if err := saveMetadata(meta); err != nil {
								return err
							}
							return setCmd.RunE(cmd, []string{fields[1], localPath})
						})
						if rerr != nil {
							return rerr
						}
						if skip {
							declined++
							continue
						}
						adopted = true
					}
					if !adopted {
						if err := setCmd.RunE(cmd, []string{fields[1], localPath}); err != nil {
							return err
						}
					}
					meta, err = loadMetadata()
					if err != nil {
						return err
					}
					for i := range meta.Patches {
						if meta.Patches[i].LocalPath == localPath {
							targets = append(targets, meta.Patches[i])
							break
						}
					}
					continue
				}
				// Pre-0.6 subdir gitdir (0.6.1): it exists but carries no synthesis
				// markers — a sparse-layout v0.5 mirror. Heal it through the SAME
				// re-adoption flow as a missing gitdir: drop the stale registration
				// and the gitdir (both disposable .cross/ state — the stale mirror
				// would poison a fresh `set` with its sparse config), then let the
				// prompt decide what happens to the crossed dir's content (wipe /
				// stash / preserve). One `git cross update` IS the 0.5→0.6 migration.
				if patch.RemotePath != "." && patch.RemotePath != "/" {
					if merr := runGitdir(gdAbs, "rev-parse", "-q", "--verify", upstreamRef(patch.Branch)).Run(); merr != nil {
						logWarn(fmt.Sprintf("%s: pre-0.6 subdir gitdir (no synthesis markers); re-adopting it at the v0.6 layout", localPath))
						skip, rerr := readoptLostCross(root, localPath, force, func() error {
							kept := meta.Patches[:0]
							for _, q := range meta.Patches {
								if q.LocalPath != localPath {
									kept = append(kept, q)
								}
							}
							meta.Patches = kept
							if err := saveMetadata(meta); err != nil {
								return err
							}
							if err := removeGitdirTree(root, patch.Gitdir); err != nil {
								return err
							}
							return setCmd.RunE(cmd, []string{fields[1], localPath})
						})
						if rerr != nil {
							return rerr
						}
						if skip {
							declined++
							continue
						}
						meta, err = loadMetadata()
						if err != nil {
							return err
						}
						for i := range meta.Patches {
							if meta.Patches[i].LocalPath == localPath {
								targets = append(targets, meta.Patches[i])
								break
							}
						}
						continue
					}
				}
				// rerere in the standalone gitdir: ensure + announce when newly enabled.
				if gc := runGitdir(gdAbs, "config", "--get", "rerere.enabled"); gc.Run() != nil {
					if err := runGitdir(gdAbs, "config", "rerere.enabled", "true").Run(); err == nil {
						logInfo("Enabled rerere in gitdir: conflict resolutions are remembered for later updates.")
					}
				}
				targets = append(targets, *patch)
			}
			// A declined cross is a skip, not a missing cross: the path WAS in
			// the Crossfile, the user just did not confirm the re-adoption.
			if selectedPath != "" && len(targets) == 0 && declined == 0 {
				return fmt.Errorf("no Crossfile cross found for path: %s", selectedPath)
			}
			if len(targets) == 0 {
				logInfo("No crosses to update.")
				if declined > 0 {
					logWarn(fmt.Sprintf("%d cross(es) not adopted: not confirmed (use --force to adopt without asking).", declined))
				}
				return nil
			}

			// Pass 2: fetch every upstream first. Fetching is innocent — it only
			// writes refs/remotes/origin/<branch> inside the gitdir and never
			// touches a work tree — so it happens for ALL patches before any
			// patch directory is modified.
			fetched := make(map[string]string, len(targets)) // local_path -> new rev
			for i := range targets {
				p := &targets[i]
				gdAbs := p.gitdirAbs(root)
				if fc := runGitdir(gdAbs, "fetch", "-q", "--no-recurse-submodules", "origin",
					fmt.Sprintf("+refs/heads/%s:refs/remotes/origin/%s", p.Branch, p.Branch)); fc.Run() != nil {
					logError(fmt.Sprintf("git fetch failed for %s (%s); %s not updated", p.Remote, p.RemoteURL, p.LocalPath))
					continue
				}
				revOut, err := runGitdir(gdAbs, "rev-parse", "refs/remotes/origin/"+p.Branch).Output()
				if err != nil {
					logError(fmt.Sprintf("cannot resolve fetched revision for %s; not updated", p.LocalPath))
					continue
				}
				fetched[p.LocalPath] = strings.TrimSpace(string(revOut))
			}

			// Pass 3: land upstream in the patch dir and re-apply the user's
			// version on top (ADR-003). The mirror gitdir is READ-ONLY here except
			// for its branch ref, which advances only once the content landed.
			updated, skipped, conflicted := 0, 0, 0
			for i := range targets {
				p := &targets[i]
				rev, ok := fetched[p.LocalPath]
				if !ok {
					continue
				}
				switch res := landUpstream(root, p, rev, doResolve && !noResolve); res {
				case landPending:
					logWarn(fmt.Sprintf("'%s' has a pending conflict; run: git cross resolve %s", p.LocalPath, p.LocalPath))
					conflicted++
				case landDirty:
					logWarn(fmt.Sprintf("'%s' has modified files; commit them in your repo first — not updated", p.LocalPath))
					skipped++
				case landConflict:
					logWarn(fmt.Sprintf("conflict in '%s'; resolve the marked files, then: git add <paths> && git commit", p.LocalPath))
					conflicted++
				case landUntracked:
					logWarn(fmt.Sprintf("'%s' has untracked files the update would overwrite; commit, stage or remove them first — not updated", p.LocalPath))
					skipped++
				case landUptodate:
					logInfo(fmt.Sprintf("%s is already up to date", p.LocalPath))
				case landUpdated:
					logSuccess(fmt.Sprintf("Updated %s", p.LocalPath))
					updated++
				default:
					logError(fmt.Sprintf("failed to update %s", p.LocalPath))
					skipped++
				}
			}

			if conflicted > 0 {
				logInfo(fmt.Sprintf("%d cross(es) need attention; run: git cross resolve", conflicted))
			}
			if updated > 0 || conflicted > 0 {
				logInfo("Review the differences in your repo:")
				fmt.Println("  git status / git diff            # staged upstream + your re-applied changes")
				fmt.Println("  git cross resolve                # list leftovers, --continue, --abort")
			}
			if skipped > 0 {
				logInfo(fmt.Sprintf("%d cross(es) skipped; %d updated.", skipped, updated))
				logInfo(fmt.Sprintf("git-cross %s — raw git errors where a friendly gate should be can mean an older binary; check: git cross --version", crossVersion))
			}
			if declined > 0 {
				logWarn(fmt.Sprintf("%d cross(es) not adopted: not confirmed (use --force to adopt without asking).", declined))
			}
			return nil
		},
	}
	updateCmd.Flags().BoolVar(&noResolve, "no-resolve", false,
		"land upstream as-is: collisions with your edits resolve in upstream's favor (-X theirs) — no conflict markers, nothing left to resolve")
	updateCmd.Flags().BoolVar(&doResolve, "resolve", true,
		"default behavior: land upstream and re-apply your changes (3-way apply)")
	_ = updateCmd.Flags().MarkHidden("resolve") // the default is implied; kept for symmetry with --no-resolve
	updateCmd.Flags().BoolVar(&force, "force", false,
		"adopt crossed dirs that exist without .cross state: delete the dir and re-create it from upstream (refused when it has uncommitted changes)")
	updateCmd.MarkFlagsMutuallyExclusive("resolve", "no-resolve")

	resolveFlagName := "continue"
	if doAbort {
		resolveFlagName = "abort"
	}
	resolveCmd := &cobra.Command{
		Use:     "resolve [--continue|--abort] [path]",
		Short:   "Finish an update conflict: report unmerged paths, or continue/abort",
		GroupID: "crosses",
		Args:    cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			root, err := getRepoRoot()
			if err != nil {
				return err
			}
			var patch *Patch
			if len(args) > 0 {
				relPath, err := resolvePathToRepoRelative(args[0])
				if err != nil {
					return err
				}
				meta, _ := loadMetadata()
				patch = findPatchForPath(meta, relPath)
			} else {
				meta, _ := loadMetadata()
				if found, ferr := findPatchForPathFromCWD(meta); ferr == nil {
					patch = found
				}
			}
			if patch == nil {
				// Not inside a patch: fall back to the only patch, if unambiguous.
				meta, _ := loadMetadata()
				if len(meta.Patches) == 1 {
					patch = &meta.Patches[0]
				}
			}
			if patch == nil {
				// --continue/--abort MUTATE state (advance the mirror / restore
				// the dir): with several crosses and no context they are
				// genuinely ambiguous. Fail cleanly — rows + hint on stderr,
				// exit 1, no duplicate cobra "Error:" line.
				if len(args) > 0 || doContinue || doAbort {
					// A PATH ARG that matches nothing is a user error (keep
					// erroring); --continue/--abort with several crosses are
					// genuinely ambiguous. Both go to stderr, exit 1, without
					// the redundant cobra "Error:" line.
					w := os.Stdout
					if len(args) == 0 {
						w = os.Stderr
					}
					hint := "several crosses; pass a path or run this inside a crossed directory. Crosses (local_path <TAB> gitdir):"
					if len(args) > 0 {
						hint = fmt.Sprintf("no cross found for '%s'; available crosses (local_path <TAB> gitdir):", args[0])
					}
					if err := printPatchRowsTo(w, hint); err != nil {
						return err
					}
					if len(args) == 0 {
						fmt.Fprintf(os.Stderr, "run: git cross resolve --%s <local_path>\n", resolveFlagName)
					} else {
						fmt.Fprintf(os.Stderr, "run: git cross resolve <local_path>\n")
					}
					os.Exit(1) // contextual failure: exits directly, no duplicate cobra "Error:" line
				}
				// No path, no flags, no cross context: LIST what is left
				// across ALL crosses — the documented behavior
				// ("git cross resolve [path]  # list what is left").
				// Informational like `git status`: exit 0 either way.
				meta, _ := loadMetadata()
				pending := 0
				for i := range meta.Patches {
					p := &meta.Patches[i]
					u := patchUnmerged(root, p)
					if len(u) == 0 {
						continue
					}
					if pending == 0 {
						fmt.Println("Crosses with unresolved conflicts:")
					}
					logInfo(fmt.Sprintf("%s: %d unmerged path(s)", p.LocalPath, len(u)))
					pending++
				}
				if pending == 0 {
					fmt.Println("No pending conflicts.")
				} else {
					fmt.Println("run: git cross resolve <local_path>")
				}
				return nil
			}
			unmerged := patchUnmerged(root, patch)
			// No-args list mode (no --continue/--abort, no path arg): showing
			// the pending state is the point, so an empty or full list is
			// informational, not an error (exit 0, like the all-crosses list
			// above). A path arg keeps the stricter contract.
			listMode := len(args) == 0 && !doContinue && !doAbort

			if doContinue {
				if len(unmerged) > 0 {
					for _, f := range unmerged {
						fmt.Println(f)
					}
					return fmt.Errorf("%d unresolved path(s) in %s", len(unmerged), patch.LocalPath)
				}
				// The content landed and was resolved: let the mirror follow.
				if out, err := runGitdir(patch.gitdirAbs(root), "rev-parse",
					"refs/remotes/origin/"+patch.Branch).Output(); err == nil {
					advanceMirror(root, patch, strings.TrimSpace(string(out)))
				}
				logSuccess(fmt.Sprintf("%s is clean; commit your changes in your repo (git add + git commit)", patch.LocalPath))
				return nil
			}
			if doAbort {
				// checkout -f from HEAD clears unmerged entries; `git restore`
				// refuses pathspecs that are in conflict.
				restore := exec.Command("git", "-C", root, "checkout", "-f", "HEAD", "--", patch.worktreePath())
				restore.Stdout, restore.Stderr = nil, os.Stderr
				if err := restore.Run(); err != nil {
					return fmt.Errorf("failed to restore %s: %w", patch.LocalPath, err)
				}
				quit := exec.Command("git", "-C", root, "cherry-pick", "--quit")
				quit.Env = os.Environ()
				quit.Run() // harmless when no sequencer state exists
				logSuccess(fmt.Sprintf("Reverted %s to HEAD; upstream is still fetched, re-run: git cross update", patch.LocalPath))
				return nil
			}
			if len(unmerged) == 0 {
				if listMode {
					fmt.Println("No pending conflicts.")
					return nil
				}
				return fmt.Errorf("nothing to resolve for %s", patch.LocalPath)
			}
			logInfo(fmt.Sprintf("%d unmerged path(s) in %s:", len(unmerged), patch.LocalPath))
			for _, f := range unmerged {
				fmt.Println("  " + f)
			}
			fmt.Println("resolve them, then: git add <paths> && git commit")
			fmt.Println("or: git cross resolve --abort")
			if listMode {
				return nil // informational listing, not an error
			}
			// A path arg naming a cross WITH conflicts: non-zero so scripts
			// notice, but with an honest message — "cross not found" would be
			// a lie (the cross was found, it just needs resolving).
			return fmt.Errorf("%s still has unresolved conflicts", patch.LocalPath)
		},
	}
	resolveCmd.Flags().BoolVar(&doContinue, "continue", false, "verify the cross is resolved and let the mirror follow")
	resolveCmd.Flags().BoolVar(&doAbort, "abort", false, "discard the partial apply (crossed dir back to HEAD)")

	// removeSinglePatch removes a cross by local_path: gitdir, Crossfile entry,
	// metadata entry, and local directory. Used by `del` (wipe never deletes a
	// crossed dir).
	removeSinglePatch := func(meta *Metadata, localPath string) error {
		localPath = filepath.ToSlash(filepath.Clean(localPath))
		patchIdx := -1
		// Copy the entry: the slice is mutated below, which would invalidate a
		// pointer into it (it would read the next patch's fields).
		var patch Patch
		for i, p := range meta.Patches {
			if p.LocalPath == localPath {
				patch = p
				patchIdx = i
				break
			}
		}
		if patchIdx < 0 {
			return fmt.Errorf("cross not found for path: %s", localPath)
		}
		logInfo(fmt.Sprintf("Removing cross at %s...", localPath))

		logInfo("Removing from Crossfile...")
		removeFromCrossfile(localPath)

		logInfo("Updating metadata...")
		meta.Patches = append(meta.Patches[:patchIdx], meta.Patches[patchIdx+1:]...)

		// v2: one standalone gitdir per patch — remove it unconditionally.
		root, err := getRepoRoot()
		if err == nil {
			gdAbs := patch.gitdirAbs(root)
			if _, err := os.Stat(gdAbs); err == nil {
				logInfo(fmt.Sprintf("Removing gitdir at %s...", patch.Gitdir))
				if err := os.RemoveAll(gdAbs); err != nil {
					logError(fmt.Sprintf("Failed to remove gitdir: %v", err))
				}
			}
		}

		if localPath != "." && localPath != "" {
			logInfo(fmt.Sprintf("Deleting local directory %s...", localPath))
			if err := os.RemoveAll(filepath.Join(root, filepath.FromSlash(localPath))); err != nil {
				logError(fmt.Sprintf("Failed to remove local directory: %v", err))
			}
		}
		return nil
	}

	delCmd := &cobra.Command{
		Use:           "del [path]",
		Short:         "Delete a cross: gitdir + crossed dir + Crossfile/metadata entries",
		GroupID:       "crosses",
		Args:          cobra.ExactArgs(1),
		SilenceErrors: true,
		SilenceUsage:  true,
		RunE: func(cmd *cobra.Command, args []string) error {
			meta, err := loadMetadata()
			if err != nil {
				return err
			}
			localPath := filepath.ToSlash(filepath.Clean(strings.TrimSpace(args[0])))
			found := false
			for _, p := range meta.Patches {
				if p.LocalPath == localPath {
					found = true
					break
				}
			}
			if !found {
				if err := printPatchRows("No cross detected; available crosses (local_path <TAB> gitdir):"); err != nil {
					return err
				}
				return errPatchNotFound
			}
			if err := removeSinglePatch(&meta, localPath); err != nil {
				return err
			}
			if err := saveMetadata(meta); err != nil {
				return err
			}
			logSuccess("Cross deleted successfully.")
			return nil
		},
	}

	wipeCmd := &cobra.Command{
		Use:     "wipe [remote]",
		Short:   "Remove a remote's metadata + gitdirs (crossed dirs stay), or sweep unused remotes and orphaned gitdirs",
		GroupID: "overview",
		Args:    cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			meta, _ := loadMetadata()
			root, err := getRepoRoot()
			if err != nil {
				return err
			}
			dropRemote := func(name string) {
				out := meta.Remotes[:0]
				for _, r := range meta.Remotes {
					if r.Name != name {
						out = append(out, r)
					}
				}
				meta.Remotes = out
				rel := filepath.ToSlash(filepath.Join(GitdirRoot, name))
				if _, serr := os.Stat(filepath.Join(root, filepath.FromSlash(rel))); serr == nil {
					logInfo(fmt.Sprintf("Removing gitdir directory: %s", rel))
				}
				if err := removeGitdirTree(root, rel); err != nil {
					logError(fmt.Sprintf("Failed to remove %s: %v", rel, err))
				}
			}

			if len(args) == 1 {
				remoteName := args[0]
				logInfo(fmt.Sprintf("Wiping all crosses for remote: %s...", remoteName))
				// Wipe owns metadata + gitdirs only: the crossed dirs are the user's
				// files in the working tree, so they stay (and are named) here.
				kept := meta.Patches[:0]
				removed := 0
				for _, p := range meta.Patches {
					if p.Remote != remoteName {
						kept = append(kept, p)
						continue
					}
					removed++
					logInfo(fmt.Sprintf("Leaving %s in place (remove it with: git cross del %s)", p.worktreePath(), p.LocalPath))
				}
				meta.Patches = kept
				if removed == 0 {
					logInfo(fmt.Sprintf("No crosses found for remote: %s", remoteName))
				}
				dropRemote(remoteName)
				if err := saveMetadata(meta); err != nil {
					return err
				}
				logSuccess(fmt.Sprintf("Remote %s wiped: metadata and gitdirs removed, crossed dirs left in place.", remoteName))
				return nil
			}

			// Drop dead metadata entries first. Two kinds are dead:
			//  - worktree AND gitdir both gone: nothing left to recover (the
			//    Crossfile line can re-create it with `update --force`);
			//  - no longer declared in the Crossfile: the declaration IS the
			//    registration, so the entry is stale even when files remain
			//    on disk (user-reported: hand-edited Crossfile lines left
			//    "Missing GD" rows that wipe never cleaned, and the stale
			//    patch kept its remote looking "used").
			// A Crossfile that cannot be read (missing here is legitimate —
			// `cfg` may not have run) skips only the undeclared sweep: never
			// drop registrations on unreadable declarations.
			declared, declErr := declaredLocalPaths(nil)
			if cfCommands, cfErr := crossfileCommands(filepath.Join(root, CrossfileRelPath)); cfErr != nil {
				logWarn(fmt.Sprintf("cannot read Crossfile declarations (%v); skipping the undeclared-entry sweep", cfErr))
			} else {
				declared, declErr = declaredLocalPaths(cfCommands)
				if declErr != nil {
					logWarn(fmt.Sprintf("cannot interpret Crossfile declarations (%v); skipping the undeclared-entry sweep", declErr))
				}
			}
			livePatches := meta.Patches[:0]
			for _, p := range meta.Patches {
				_, werr := os.Stat(p.localAbs(root))
				_, gerr := os.Stat(p.gitdirAbs(root))
				_, wkept := os.Stat(filepath.Join(root, filepath.FromSlash(p.worktreePath())))
				worktreeExists := wkept == nil
				if os.IsNotExist(werr) && os.IsNotExist(gerr) {
					logInfo(fmt.Sprintf("Dropping %s from metadata: its worktree and gitdir are both missing", p.LocalPath))
					continue
				}
				if declErr == nil && !declared[filepath.ToSlash(filepath.Clean(p.LocalPath))] {
					logInfo(fmt.Sprintf("Dropping %s from metadata: it is no longer declared in Crossfile", p.LocalPath))
					if worktreeExists {
						logInfo(fmt.Sprintf("Leaving %s in place (its files are yours; remove them yourself if unwanted)", p.worktreePath()))
					}
					continue
				}
				livePatches = append(livePatches, p)
			}
			meta.Patches = livePatches

			// Remove unused remotes (registered but no patches reference them).
			logInfo("Finding unused remotes...")
			usedRemotes := make(map[string]bool)
			for _, p := range meta.Patches {
				usedRemotes[p.Remote] = true
			}
			var unusedRemotes []string
			for _, r := range meta.Remotes {
				if !usedRemotes[r.Name] {
					unusedRemotes = append(unusedRemotes, r.Name)
				}
			}
			if len(unusedRemotes) == 0 {
				logInfo("No unused remotes found.")
			} else {
				logInfo(fmt.Sprintf("Unused remotes: %s", strings.Join(unusedRemotes, ", ")))
				fmt.Print("Remove these remotes? [y/N]: ")
				var confirm string
				fmt.Scanln(&confirm)
				if confirm == "y" || confirm == "Y" {
					for _, r := range unusedRemotes {
						logInfo(fmt.Sprintf("Removing remote: %s", r))
						dropRemote(r)
					}
					logSuccess("Unused remotes removed.")
				} else {
					logInfo("Wipe cancelled.")
				}
			}

			// Sweep orphaned gitdirs not referenced by metadata patches.
			wtRoot := filepath.Join(root, filepath.FromSlash(GitdirRoot))
			knownGds := make(map[string]bool)
			for _, p := range meta.Patches {
				knownGds[p.Gitdir] = true
			}
			remotes, _ := os.ReadDir(wtRoot)
			for _, rd := range remotes {
				if !rd.IsDir() {
					continue
				}
				gds, _ := os.ReadDir(filepath.Join(wtRoot, rd.Name()))
				for _, gd := range gds {
					if !gd.IsDir() {
						continue
					}
					rel := filepath.ToSlash(filepath.Join(GitdirRoot, rd.Name(), gd.Name()))
					if !knownGds[rel] {
						logInfo(fmt.Sprintf("Removing orphaned gitdir: %s", rel))
						if err := removeGitdirTree(root, rel); err != nil {
							logError(fmt.Sprintf("Failed to remove %s: %v", rel, err))
						}
					}
				}
			}
			if err := saveMetadata(meta); err != nil {
				return err
			}
			logSuccess("Wipe complete.")
			return nil
		},
	}

	cfgCmd := &cobra.Command{
		Use:     "cfg",
		Aliases: []string{"init"},
		Short:   "Configure the repo for git-cross: Crossfile + rerere + .gitignore (init kept as alias)",
		GroupID: "crosses",
		RunE: func(cmd *cobra.Command, args []string) error {
			if root, rerr := getRepoRoot(); rerr == nil {
				if ensureRerere("-C", root) {
					logInfo("Enabled rerere: conflict resolutions are remembered for later updates.")
				} else {
					logInfo("rerere already enabled: conflict resolutions are reused.")
				}
			}
			// .cross/ is disposable state - make sure the repo does not track it.
			ensureGitignore()
			root, _ := getRepoRoot()
			path := filepath.Join(root, CrossfileRelPath)
			if _, err := os.Stat(path); err == nil {
				logInfo("Crossfile already exists.")
				return nil
			}
			if err := os.WriteFile(path, []byte("# git-cross configuration\n"), 0o644); err != nil {
				return err
			}
			logSuccess("Crossfile initialized.")
			logInfo(shellIntegrationHint())
			return nil
		},
	}

	// env prints the upstream git context of a crossed dir, for `eval`. It is the
	// explicit, process-scoped alternative to `git cross <git-args>`: plain `git`
	// commands (aliases, editor/gh integrations, lazygit, ...) speak to upstream.
	envCmd := &cobra.Command{
		Use:     "env [path]",
		Short:   "Print the git environment of a crossed dir's upstream (for eval/source)",
		GroupID: "overview",
		Args:    cobra.MaximumNArgs(1),
		Long: `Print shell code that points git at a crossed directory's UPSTREAM mirror.

  eval "$(git cross env)"          # bash/zsh, run inside the crossed dir
  git cross env --fish | source    # fish

It defines GIT_DIR (the patch's bare gitdir), GIT_WORK_TREE (the crossed dir),
CROSS_ACTIVE (its local_path) and CROSS_REMOTE (the remote name). After that,
plain 'git' means the cross's upstream: log, diff, status, fetch, push, ...

Keep the context scoped — exported variables in an interactive shell are easy
to forget. The gxenv wrapper (from: git cross comp) runs a NESTED shell by
default (leaving it unloads), 'gxenv -i' loads into the current shell and
'gxenv -u' unloads again; either way the prompt is marked [cross:<remote>] so
a modified terminal is obvious. 'git cross ...' keeps working with the context loaded; it is
plain 'git' that changes meaning. Commits made in this context land in the
mirror branch, NOT in your repo — commit the crossed files from your repo.

flags: --fish (fish syntax), --unset (print the unload code), --json,
       --gitdir / --worktree / --local-path (print one bare value).`,
		RunE: func(cmd *cobra.Command, args []string) error {
			fish, _ := cmd.Flags().GetBool("fish")
			unset, _ := cmd.Flags().GetBool("unset")
			asJSON, _ := cmd.Flags().GetBool("json")
			wantGitdir, _ := cmd.Flags().GetBool("gitdir")
			wantWorktree, _ := cmd.Flags().GetBool("worktree")
			wantLocalPath, _ := cmd.Flags().GetBool("local-path")
			wantRemote, _ := cmd.Flags().GetBool("remote")

			if unset {
				if fish {
					fmt.Println("set -e GIT_DIR GIT_WORK_TREE CROSS_ACTIVE CROSS_REMOTE")
				} else {
					fmt.Println("unset GIT_DIR GIT_WORK_TREE CROSS_ACTIVE CROSS_REMOTE")
				}
				return nil
			}

			meta, err := loadMetadata()
			if err != nil {
				return err
			}
			patch, err := patchForEnv(&meta, args)
			if err != nil {
				return err
			}
			if patch == nil {
				if len(meta.Patches) == 0 {
					return fmt.Errorf("no crosses configured: run: git cross set <remote>:<path> <local_path>")
				}
				return fmt.Errorf("no cross matches the working directory: run this inside a crossed dir (or name one: git cross env <local_path>)")
			}
			root, err := getRepoRoot()
			if err != nil {
				return err
			}
			gdAbs := patch.gitdirAbs(root)
			if _, serr := os.Stat(gdAbs); os.IsNotExist(serr) {
				return fmt.Errorf("gitdir missing for %s (%s); run: git cross update %s", patch.LocalPath, patch.Gitdir, patch.LocalPath)
			}
			wtAbs := patch.localAbs(root)

			switch {
			case wantGitdir:
				fmt.Println(gdAbs)
			case wantWorktree:
				fmt.Println(wtAbs)
			case wantLocalPath:
				fmt.Println(patch.LocalPath)
			case wantRemote:
				fmt.Println(patch.Remote)
			case asJSON:
				payload := struct {
					Remote    string `json:"remote"`
					Branch    string `json:"branch"`
					LocalPath string `json:"local_path"`
					GitDir    string `json:"git_dir"`
					WorkTree  string `json:"work_tree"`
				}{patch.Remote, patch.Branch, patch.LocalPath, gdAbs, wtAbs}
				b, merr := json.MarshalIndent(payload, "", "  ")
				if merr != nil {
					return merr
				}
				fmt.Println(string(b))
			case fish:
				fmt.Printf("set -gx GIT_DIR %s\nset -gx GIT_WORK_TREE %s\nset -gx CROSS_ACTIVE %s\nset -gx CROSS_REMOTE %s\n",
					shellQuote(gdAbs), shellQuote(wtAbs), shellQuote(patch.LocalPath), shellQuote(patch.Remote))
			default:
				fmt.Printf("export GIT_DIR=%s\nexport GIT_WORK_TREE=%s\nexport CROSS_ACTIVE=%s\nexport CROSS_REMOTE=%s\n",
					shellQuote(gdAbs), shellQuote(wtAbs), shellQuote(patch.LocalPath), shellQuote(patch.Remote))
			}
			return nil
		},
	}
	envCmd.Flags().Bool("fish", false, "print fish syntax (set -gx ...) instead of POSIX export")
	envCmd.Flags().Bool("unset", false, "print the code that unloads the context instead")
	envCmd.Flags().Bool("json", false, "print git_dir/work_tree/local_path as JSON")
	envCmd.Flags().Bool("gitdir", false, "print only the absolute gitdir")
	envCmd.Flags().Bool("worktree", false, "print only the absolute work tree")
	envCmd.Flags().Bool("local-path", false, "print only the local_path")
	envCmd.Flags().Bool("remote", false, "print only the remote name")

	cdCmd := &cobra.Command{
		Use:           "cd [--pick] [path]",
		Short:         "Print a crossed directory path (hidden: the xcd/gx-cd wrapper does the real cd)",
		GroupID:       "overview",
		Hidden:        true,
		SilenceErrors: true,
		SilenceUsage:  true,
		Long: `Print the absolute path of a crossed directory to stdout.

Running this directly only prints a path: a child process cannot change the
caller's shell — that is why this command is hidden from help. For a real
directory change use the wrappers (git cross comp):
  eval "$(git cross comp)"          # bash/zsh; then: xcd [path]  (or: gx cd [path])
  git cross comp fish | source      # fish`,
		RunE: func(cmd *cobra.Command, args []string) error {
			pick, _ := cmd.Flags().GetBool("pick")
			meta, err := loadMetadata()
			if err != nil {
				return err
			}
			if len(meta.Patches) == 0 {
				logInfo("No crosses configured.")
				return nil
			}
			var patch *Patch
			if len(args) > 0 {
				arg := strings.TrimSpace(args[0])
				relPath, rerr := resolvePathToRepoRelative(arg)
				if rerr != nil {
					return rerr
				}
				patch = findPatchForPath(meta, relPath)
				if patch == nil {
					cleanArg := filepath.ToSlash(filepath.Clean(arg))
					for i := range meta.Patches {
						if meta.Patches[i].LocalPath == cleanArg {
							patch = &meta.Patches[i]
							break
						}
					}
				}
				if patch == nil {
					if err := printPatchRows("No cross detected; available crosses (local_path <TAB> gitdir):"); err != nil {
						return err
					}
					return errPatchNotFound
				}
			} else {
				// --pick: always ask (the xcd wrapper uses it for a bare `xcd`,
				// so being inside a cross does not silently mean "this one").
				if !pick {
					if detected, derr := findPatchForPathFromCWD(meta); derr == nil && detected != nil {
						patch = detected
					}
				}
				if patch == nil {
					selected, serr := selectPatchInteractive(&meta)
					if serr != nil {
						rows := os.Stdout
						if pick {
							rows = os.Stderr // stdout is reserved for the chosen path
						}
						if rerr := printPatchRowsTo(rows, "fzf is not installed; cd manually, e.g. `cd <local_path>`. Crossed dirs (local_path <TAB> gitdir):"); rerr != nil {
							return rerr
						}
						return errPatchNotFound
					}
					if selected == nil {
						return nil
					}
					patch = selected
				}
			}
			root, err := getRepoRoot()
			if err != nil {
				return err
			}
			abs := patch.localAbs(root)
			if _, err := os.Stat(abs); os.IsNotExist(err) {
				return fmt.Errorf("cross not found: %s", patch.LocalPath)
			}
			fmt.Println(abs)
			// A subprocess cannot cd the caller's shell; tell interactive users how.
			if stdoutIsTerminal() {
				fmt.Fprintln(os.Stderr, xcdHint())
			}
			return nil
		},
	}

	// wt is kept as an alias of cd. In <=0.5.0 it was the upstream git passthrough;
	// that role now lives only on the bare `git cross <git-args>` fall-through.
	wtCmd := &cobra.Command{
		Use:           "wt [path]",
		Short:         "Print a crossed directory path (hidden alias of cd)",
		GroupID:       "overview",
		Hidden:        true,
		Args:          cobra.MaximumNArgs(1),
		SilenceErrors: true,
		SilenceUsage:  true,
		Long: `Alias of 'cd': prints the crossed directory's absolute path.
For a real directory change use the 'xcd' wrapper (see: git cross comp).`,
		RunE: cdCmd.RunE,
	}

	cdCmd.Flags().Bool("pick", false, "always open the interactive cross picker (no CWD auto-detect)")

	// Hidden: kept for compatibility. `comp` is the visible entry point.
	shellInitCmd := &cobra.Command{
		Use:     "shell-init [fish|bash|zsh]",
		Short:   "Print shell wrappers for git-cross (xcd, gxenv, gx, cr)",
		GroupID: "overview",
		Hidden:  true,
		Args:    cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			shell, err := resolveShell(args)
			if err != nil {
				return err
			}
			switch shell {
			case "fish":
				fmt.Print(fishShellInit)
			case "bash", "zsh":
				fmt.Print(posixShellInit)
			default:
				return fmt.Errorf("unsupported shell %q for shell functions (supported: fish, bash, zsh)", shell)
			}
			return nil
		},
	}

	compCmd := &cobra.Command{
		Use:     "comp [fish|bash|zsh|powershell]",
		Aliases: []string{"completion"},
		Short:   "Print shell completions + wrappers (xcd, gxenv, gx, cr) to evaluate",
		GroupID: "overview",
		Args:    cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			shell, err := resolveShell(args)
			if err != nil {
				return err
			}
			switch shell {
			case "fish":
				if err := rootCmd.GenFishCompletion(os.Stdout, true); err != nil {
					return err
				}
				fmt.Print("\n", fishShellInit)
			case "bash":
				if err := rootCmd.GenBashCompletionV2(os.Stdout, true); err != nil {
					return err
				}
				fmt.Print("\n", posixShellInit)
			case "zsh":
				if err := rootCmd.GenZshCompletion(os.Stdout); err != nil {
					return err
				}
				fmt.Print("\n", posixShellInit)
			case "powershell", "pwsh":
				if err := rootCmd.GenPowerShellCompletionWithDesc(os.Stdout); err != nil {
					return err
				}
			default:
				return fmt.Errorf("unsupported shell %q (supported: %s)", shell, supportedShells)
			}
			return nil
		},
	}

	lsCmd := &cobra.Command{
		Use:     "ls",
		Aliases: []string{"list"},
		Short:   "Show all configured remotes and crosses",
		GroupID: "overview",
		RunE: func(cmd *cobra.Command, args []string) error {
			raw, _ := cmd.Flags().GetBool("raw")
			noHeader, _ := cmd.Flags().GetBool("no-header")
			meta, err := loadMetadata()
			if err != nil {
				return err
			}
			// v2: remotes come from metadata, not from the primary repo's git config.
			remoteNames := make([]string, 0, len(meta.Remotes))
			urls := make(map[string]string, len(meta.Remotes))
			for _, r := range meta.Remotes {
				remoteNames = append(remoteNames, r.Name)
				urls[r.Name] = r.URL
			}
			sort.Strings(remoteNames)

			if raw {
				var rows [][]string
				if len(remoteNames) > 0 {
					if !noHeader {
						rows = append(rows, []string{"REMOTE_NAME", "REMOTE_URL"})
					}
					for _, name := range remoteNames {
						rows = append(rows, []string{name, urls[name]})
					}
					printRawRows(rows)
				}
				if len(meta.Patches) == 0 {
					fmt.Fprintln(os.Stderr, "No crosses configured.")
					return nil
				}
				rows = nil
				if !noHeader {
					rows = append(rows, []string{"REMOTE", "REMOTE_PATH", "LOCAL_PATH", "WORKTREE", "GITDIR", "BRANCH", "DIFF", "SHA"})
				}
				lsRoot, err := getRepoRoot()
				if err != nil {
					return err
				}
				for _, p := range meta.Patches {
					rows = append(rows, []string{p.Remote, p.RemotePath, p.LocalPath, p.worktreePath(), p.Gitdir, p.Branch,
						crossDiffState(lsRoot, &p), crossHeadShort(lsRoot, &p)})
				}
				printRawRows(rows)
				return nil
			}

			if len(remoteNames) > 0 {
				logInfo("Configured Remotes:")
				table := tablewriter.NewWriter(os.Stdout)
				if !noHeader {
					table.Header("REMOTE NAME", "REMOTE URL")
				}
				for _, name := range remoteNames {
					table.Append(name, urls[name])
				}
				table.Render()
				fmt.Println()
			}
			if len(meta.Patches) == 0 {
				fmt.Println("No crosses configured.")
				return nil
			}
			lsRoot, err := getRepoRoot()
			if err != nil {
				return err
			}
			logInfo("Configured crosses:")
			table := tablewriter.NewWriter(os.Stdout)
			if !noHeader {
				table.Header("REMOTE", "REMOTE PATH", "LOCAL PATH", "WORKTREE", "GITDIR", "BRANCH", "DIFF", "SHA")
			}
			for _, p := range meta.Patches {
				table.Append(p.Remote, p.RemotePath, p.LocalPath, p.worktreePath(), p.Gitdir, p.Branch,
					crossDiffState(lsRoot, &p), crossHeadShort(lsRoot, &p))
			}
			table.Render()
			return nil
		},
	}
	lsCmd.Flags().Bool("raw", false, "machine-readable output: tab-separated rows, no borders, no banners")
	lsCmd.Flags().Bool("no-header", false, "omit header line (applies to table mode and --raw")

	rootCmd.AddCommand(useCmd, setCmd, delCmd, cfgCmd, updateCmd, resolveCmd, lsCmd, envCmd, cdCmd, wtCmd, compCmd, wipeCmd, shellInitCmd)
	if err := rootCmd.Execute(); err != nil {
		os.Exit(1)
	}
}
