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
)

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
	check := exec.Command("git", "--git-dir="+gdAbs, "--work-tree="+p.localAbs(root),
		"diff", "--quiet", "HEAD", "--", pathspec)
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
	if err := runGitdir(gdAbs, "update-ref", "refs/heads/"+p.Branch, rev).Run(); err != nil {
		logWarn(fmt.Sprintf("could not advance the mirror ref for %s: %v", p.LocalPath, err))
		return
	}

}

// applyUpstreamDelta runs the land+re-apply step for one patch (ADR-003).
func applyUpstreamDelta(root string, p *Patch, baseRev, theirsRev string, resolve bool) landResult {
	delta, err := upstreamDeltaCommit(root, p, baseRev, theirsRev)
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
	baseOut, err := runGitdir(p.gitdirAbs(root), "rev-parse", "HEAD").Output()
	if err != nil {
		logError(fmt.Sprintf("%s: cannot resolve the mirror HEAD: %v", p.LocalPath, err))
		return landFailed
	}
	baseRev := strings.TrimSpace(string(baseOut))
	if baseRev == rev {
		return landUptodate
	}
	if err := runGitdir(p.gitdirAbs(root), "cat-file", "-e", baseRev+"^{tree}").Run(); err != nil {
		logError(fmt.Sprintf("%s: the mirror lacks the previous upstream tree (shallow/partial clone?); delete and re-set it", p.LocalPath))
		return landFailed
	}
	// The USER's repo must own every object it will reference: a local fetch from
	// the mirror copies the needed objects without creating a remote or a lasting
	// ref (FETCH_HEAD only). Without this the user's index would point at blobs
	// that only exist in the mirror.
	for _, ref := range []string{
		"refs/heads/" + p.Branch,
		"refs/remotes/origin/" + p.Branch,
	} {
		fc := exec.Command("git", "-C", root, "fetch", "--no-tags", "--quiet", p.gitdirAbs(root), ref)
		fc.Stderr = os.Stderr
		if err := fc.Run(); err != nil {
			logError(fmt.Sprintf("%s: cannot import upstream objects from the mirror: %v", p.LocalPath, err))
			return landFailed
		}
	}
	res := applyUpstreamDelta(root, p, baseRev, rev, resolve)
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
func logError(msg string) { color.New(color.Bold, color.FgRed).Fprint(os.Stderr, "==> ERROR: "); fmt.Fprintln(os.Stderr, msg) }

// envList splits a comma-separated environment variable into trimmed items.

// printPatchRows prints one row per patch: local_path <TAB> gitdir.
func printPatchRows(hint string) error {
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
			fmt.Printf("%-*s  %s\n", width, p.LocalPath, p.Gitdir)
		}
		return nil
	}
	for _, p := range meta.Patches {
		fmt.Printf("%s\t%s\n", p.LocalPath, p.Gitdir)
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

func crossfileCommands(path string) ([][]string, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()

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
		commands = append(commands, fields)
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return commands, nil
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

// shellQuote single-quotes s for POSIX sh and fish (both read '\'' as a
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
	readoptDecline readoptChoice = iota // skip: nothing is touched
	readoptWipe                         // re-initialize from upstream (dir wiped)
	readoptPreserve                     // re-initialize but preserve local (backup + copy back)
	readoptStash                        // stash uncommitted changes, then re-initialize (wipe)
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
xcd() { local p; p="$(git cross cd "$@")" || return; [ -n "$p" ] && cd "$p"; }
gx() { if [ "$1" = "cd" ]; then shift; xcd "$@"; else git cross "$@"; fi; }   # short alias for git cross (gx cd changes directory)
cr() { git cross "$@"; }     # short alias for git cross: cr log --oneline
# --- gxenv: give plain 'git' the crossed dir's UPSTREAM context ----------------
#   gxenv [path]      nested shell (exit unloads; nothing leaks into yours)
#   gxenv -i [path]   load into THIS shell (remember: gxenv -u before leaving)
#   gxenv -u          unload from this shell
# While loaded, PS1 ends with [cross:REMOTE] so the terminal is visibly marked
# (a PROMPT_COMMAND/theme that rewrites PS1 wholesale will hide the marker).
_gx_mark() { echo "[cross:${CROSS_REMOTE:-${CROSS_ACTIVE:-cross}}]"; }
_gx_prompt_off() { if [ -n "${_GX_PS1_SAVED+x}" ]; then PS1="$_GX_PS1_SAVED"; unset _GX_PS1_SAVED; fi; return 0; }
_gx_prompt_on() { _gx_prompt_off; _GX_PS1_SAVED="${PS1-}"; PS1="${PS1-}$(_gx_mark) "; }
gxenv() { case "${1-}" in
    -u|--unset) eval "$(git cross env --unset)"; _gx_prompt_off; return 0 ;;
    -i|--in-place)
        local src; src=$(git cross env "${2-}") && eval "$src" && _gx_prompt_on
        return $? ;;
    -h|--help) echo 'usage: gxenv [-i|--in-place|-u|--unset] [path]'
        echo '  (default) nested shell with the crossed dir upstream context'
        echo '  -i        load into this shell    -u  unload from this shell'; return 0 ;;
  esac
  local gd wt lp rm sh
  gd=$(git cross env --gitdir "$@") || return
  wt=$(git cross env --worktree "$@") || return
  lp=$(git cross env --local-path "$@") || return
  rm=$(git cross env --remote "$@") || return
  sh=$(basename "${SHELL:-/bin/sh}")
  case "$sh" in
    bash)
        GIT_DIR=$gd GIT_WORK_TREE=$wt CROSS_ACTIVE=$lp CROSS_REMOTE=$rm \
            bash --rcfile <(cat "$HOME/.bashrc" 2>/dev/null; echo 'PS1="${PS1}[cross:${CROSS_REMOTE}] "') -i ;;
    zsh)
        local zd; zd=$(mktemp -d) || return
        { cat "$HOME/.zshrc" 2>/dev/null; echo 'PS1="${PS1}[cross:${CROSS_REMOTE}] "'; } > "$zd/.zshrc"
        GIT_DIR=$gd GIT_WORK_TREE=$wt CROSS_ACTIVE=$lp CROSS_REMOTE=$rm ZDOTDIR=$zd zsh -i
        local rc=$?; rm -rf "$zd"; return $rc ;;
    *)
        GIT_DIR=$gd GIT_WORK_TREE=$wt CROSS_ACTIVE=$lp CROSS_REMOTE=$rm "${SHELL:-/bin/sh}" -i ;;
  esac
}
# optional git alias so 'git x add ./file' also works:
#   git config --global alias.x '!git cross'
`

const fishShellInit = `# git-cross shell wrappers (part of: git cross comp fish | source)
function xcd --description 'cd into a git-cross crossed directory'
    set -l p (git cross cd $argv)
    or return
    test -n "$p"; and cd $p
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
# --- gxenv: plain 'git' in a crossed dir speaks to its upstream ----------------
#   gxenv [path]      nested shell (exit unloads; nothing leaks into yours)
#   gxenv -i [path]   load into THIS fish     gxenv -u  unload from this fish
# While loaded the prompt is marked with [cross:REMOTE] (fish_prompt wrapper).
function _gx_mark
    if set -q CROSS_REMOTE
        echo -n "[cross:$CROSS_REMOTE]"
    else
        echo -n "[cross:$CROSS_ACTIVE]"
    end
end
function _gx_prompt_on
    if set -q __gx_prompt_wrapped
        return 0
    end
    functions -c fish_prompt __gx_orig_fish_prompt; or return 0
    function fish_prompt
        __gx_orig_fish_prompt
        echo -n (_gx_mark)" "
    end
    set -g __gx_prompt_wrapped 1
end
function _gx_prompt_off
    if not set -q __gx_prompt_wrapped
        return 0
    end
    functions -e fish_prompt
    functions -c __gx_orig_fish_prompt fish_prompt
    functions -e __gx_orig_fish_prompt
    set -e __gx_prompt_wrapped
end
function gxenv --description 'plain git in a crossed dir speaks to its upstream (nested shell)'
    switch "$argv[1]"
        case -u --unset
            git cross env --fish --unset | source
            _gx_prompt_off
            return
        case -i --in-place
            git cross env --fish $argv[2..-1] | source; and _gx_prompt_on
            return
        case -h --help
            echo 'usage: gxenv [-i|--in-place|-u|--unset] [path]'
            return
    end
    set -l gd (git cross env --gitdir $argv); or return
    set -l wt (git cross env --worktree $argv); or return
    set -l lp (git cross env --local-path $argv); or return
    set -l rm (git cross env --remote $argv); or return
    set -l mrk (_gx_mark)
    if test (basename $SHELL) = fish
        GIT_DIR=$gd GIT_WORK_TREE=$wt CROSS_ACTIVE=$lp CROSS_REMOTE=$rm \
            fish -i -C "functions -c fish_prompt __gx_orig_fish_prompt; function fish_prompt; __gx_orig_fish_prompt; echo -n '$mrk '; end"
    else
        GIT_DIR=$gd GIT_WORK_TREE=$wt CROSS_ACTIVE=$lp CROSS_REMOTE=$rm $SHELL -i
    end
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
				fmt.Println("git-cross version 0.5.3")
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
	useRemote := func(name, url string) error {
		if out, err := exec.Command("git", "ls-remote", "--heads", url).CombinedOutput(); err != nil {
			return fmt.Errorf("cannot reach remote %s: %s: %w", url, strings.TrimSpace(string(out)), err)
		}
		meta, err := loadMetadata()
		if err != nil {
			return err
		}
		upsertRemote(&meta, name, url)
		if err := saveMetadata(meta); err != nil {
			return err
		}
		return updateCrossfile(fmt.Sprintf("use %s %s", name, url))
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

				if spec.RemotePath != "." {
					// Sparse filter: trailing "/" matches the directory reliably in --no-cone mode.
					if gc := runGitdir(gdAbs, "config", "core.sparseCheckout", "true"); gc.Run() != nil {
						return fmt.Errorf("sparse config failed for %s", gd)
					}
					if err := os.MkdirAll(filepath.Join(gdAbs, "info"), 0o755); err != nil {
						return err
					}
					if err := os.WriteFile(filepath.Join(gdAbs, "info", "sparse-checkout"), []byte(spec.RemotePath+"/\n"), 0o644); err != nil {
						return err
					}
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
			commands, err := crossfileCommands(crossfile)
			if err != nil {
				return err
			}
			selectedPath := ""
			declined := 0 // crosses not adopted: declined the y/N wipe prompt
			if len(args) > 0 {
				selectedPath, err = resolvePathToRepoRelative(args[0])
				if err != nil {
					return err
				}
			}
			meta, err := loadMetadata()
			if err != nil {
				return err
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
				if fc := runGitdir(gdAbs, "fetch", "-q", "origin",
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
				if err := printPatchRows("several crosses; pass a path or run this inside a crossed directory. Crosses (local_path <TAB> gitdir):"); err != nil {
					return err
				}
				return errPatchNotFound
			}
			unmerged := patchUnmerged(root, patch)

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
				return fmt.Errorf("nothing to resolve for %s", patch.LocalPath)
			}
			logInfo(fmt.Sprintf("%d unmerged path(s) in %s:", len(unmerged), patch.LocalPath))
			for _, f := range unmerged {
				fmt.Println("  " + f)
			}
			fmt.Println("resolve them, then: git add <paths> && git commit")
			fmt.Println("or: git cross resolve --abort")
			return errPatchNotFound
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

			// Drop dead metadata entries first: a record whose worktree AND gitdir
			// are both gone has nothing left to recover (the Crossfile line can
			// re-create it with `update --force`).
			livePatches := meta.Patches[:0]
			for _, p := range meta.Patches {
				_, werr := os.Stat(p.localAbs(root))
				_, gerr := os.Stat(p.gitdirAbs(root))
				if os.IsNotExist(werr) && os.IsNotExist(gerr) {
					logInfo(fmt.Sprintf("Dropping %s from metadata: its worktree and gitdir are both missing", p.LocalPath))
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
		Use:           "cd [path]",
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
				if detected, derr := findPatchForPathFromCWD(meta); derr == nil && detected != nil {
					patch = detected
				} else {
					selected, serr := selectPatchInteractive(&meta)
					if serr != nil {
						if rerr := printPatchRows("fzf is not installed; cd manually, e.g. `cd <local_path>`. Crossed dirs (local_path <TAB> gitdir):"); rerr != nil {
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
		Use:          "wt [path]",
		Short:        "Print a crossed directory path (hidden alias of cd)",
		GroupID:      "overview",
		Hidden:       true,
		Args:         cobra.MaximumNArgs(1),
		SilenceErrors: true,
		SilenceUsage:  true,
		Long: `Alias of 'cd': prints the crossed directory's absolute path.
For a real directory change use the 'xcd' wrapper (see: git cross comp).`,
		RunE: cdCmd.RunE,
	}

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
