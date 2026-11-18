package main

// Integration tests for the ADR-003 update/resolve contract.
//
// These drive the real CLI binary (built once in TestMain) against throwaway
// repositories under t.TempDir(), so they cover exactly what a user runs:
//
//   update  = fetch every patch (innocent), then per patch land upstream in the
//             patch dir and re-apply the user's version on top
//   resolve = list leftovers / --continue / --abort
//
// What is pinned here:
//  1. a clean update lands upstream and re-applies committed local changes;
//  2. uncommitted (unstaged) changes refuse the update, staged content does not;
//  3. a collision keeps the conflict: unmerged paths + markers, never an
//     overwrite;
//  4. `resolve --abort` restores the user's version and keeps the fetch;
//  5. `resolve --continue` requires the paths to be resolved and lets the mirror
//     branch follow, so the next update is a no-op;
//  6. a repeated identical conflict is replayed by rerere (recorded in the user's
//     repo, `<repo>/.git/rr-cache`), not in the mirror;
//  7. `--no-resolve` lands upstream as-is (upstream wins, no markers).

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

var binPath string

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "cross-gotest-")
	if err != nil {
		panic(err)
	}
	binPath = filepath.Join(dir, "git-cross-test")
	build := exec.Command("go", "build", "-mod=mod", "-o", binPath, ".")
	build.Stdout, build.Stderr = os.Stdout, os.Stderr
	if err := build.Run(); err != nil {
		os.RemoveAll(dir)
		panic("build failed: " + err.Error())
	}
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}

func run(t *testing.T, dir, bin string, args ...string) (string, int) {
	t.Helper()
	cmd := exec.Command(bin, args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(),
		"GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@example.com",
		"GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@example.com",
		// keep ssh/gpg out of the way for local fixtures
		"GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null",
	)
	out, err := cmd.CombinedOutput()
	code := 0
	if ee, ok := err.(*exec.ExitError); ok {
		code = ee.ExitCode()
	} else if err != nil {
		t.Fatalf("run %v: %v", args, err)
	}
	return string(out), code
}

func git(t *testing.T, dir string, args ...string) string {
	t.Helper()
	full := append([]string{"-C", dir, "-c", "user.name=t", "-c", "user.email=t@example.com"}, args...)
	cmd := exec.Command("git", full...)
	cmd.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return string(out)
}

type fixture struct {
	t    *testing.T
	root string // user repo
	up   string // upstream repo
}

// newFixture creates an upstream repo with src/lib/{c.yaml}, a user repo, and one
// patch at "lib" covering "src/lib".
func newFixture(t *testing.T) *fixture {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not available")
	}
	base := t.TempDir()
	f := &fixture{t: t, root: filepath.Join(base, "repo"), up: filepath.Join(base, "upstream")}
	for _, d := range []string{f.root, f.up} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
		git(t, d, "init", "-q", "-b", "main")
	}

	// upstream: src/lib/c.yaml
	if err := os.MkdirAll(filepath.Join(f.up, "src", "lib"), 0o755); err != nil {
		t.Fatal(err)
	}
	f.writeUpstream("c.yaml", "NAME: AAA\n")
	git(t, f.up, "add", "-A")
	git(t, f.up, "commit", "-qm", "v1")

	// the fixture upstream lives inside the test tree: keep it out of the repo
	if err := os.WriteFile(filepath.Join(f.root, ".gitignore"), []byte("../\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	git(t, f.root, "add", ".gitignore")
	git(t, f.root, "commit", "-qm", "init")

	if out, code := run(t, f.root, binPath, "cfg"); code != 0 {
		t.Fatalf("set: %d\n%s", code, out)
	}
	if out, code := run(t, f.root, binPath, "use", "up", f.up); code != 0 {
		t.Fatalf("use: %d\n%s", code, out)
	}
	if out, code := run(t, f.root, binPath, "set", "up:src/lib", "lib"); code != 0 {
		t.Fatalf("patch: %d\n%s", code, out)
	}
	return f
}

func (f *fixture) writeUpstream(name, content string) {
	f.t.Helper()
	p := filepath.Join(f.up, "src", "lib", name)
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		f.t.Fatal(err)
	}
}

func (f *fixture) writeLocal(name, content string) {
	f.t.Helper()
	p := filepath.Join(f.root, "lib", "src", "lib", name)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		f.t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		f.t.Fatal(err)
	}
}

func (f *fixture) readLocal(name string) string {
	f.t.Helper()
	b, err := os.ReadFile(filepath.Join(f.root, "lib", "src", "lib", name))
	if err != nil {
		f.t.Fatalf("read local %s: %v", name, err)
	}
	return string(b)
}

// commitAll commits the working tree of the user repo (the vendored files).
func (f *fixture) commitAll(msg string) {
	f.t.Helper()
	git(f.t, f.root, "add", "-A")
	git(f.t, f.root, "commit", "-qm", msg)
}

func (f *fixture) unmerged() []string {
	f.t.Helper()
	out := git(f.t, f.root, "ls-files", "-u")
	seen := map[string]bool{}
	var paths []string
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		parts := strings.SplitN(line, "\t", 2)
		if len(parts) != 2 || seen[parts[1]] {
			continue
		}
		seen[parts[1]] = true
		paths = append(paths, parts[1])
	}
	return paths
}

func (f *fixture) mirrorHead() string {
	f.t.Helper()
	gd := f.mirror()
	return strings.TrimSpace(git(f.t, f.root, "--git-dir", gd, "rev-parse", "HEAD"))
}

func (f *fixture) mirrorOrigin() string {
	f.t.Helper()
	gd := f.mirror()
	return strings.TrimSpace(git(f.t, f.root, "--git-dir", gd, "rev-parse", "refs/remotes/origin/main"))
}

func (f *fixture) mirror() string {
	f.t.Helper()
	return filepath.Join(f.root, ".cross", "worktrees", "up", "lib")
}

// TestUpdateLandsAndReapplies covers a clean update where the user committed an
// edit to a file upstream did not touch, plus a new upstream file.
func TestUpdateLandsAndReapplies(t *testing.T) {
	f := newFixture(t)
	f.commitAll("vendor: initial") // vendored files are staged by `patch`

	f.writeLocal("local.txt", "user only\n")
	f.commitAll("vendor: local addition")
	f.writeUpstream("new.txt", "upstream new\n")
	git(t, f.up, "add", "-A")
	git(t, f.up, "commit", "-qm", "v2")

	out, code := run(t, f.root, binPath, "update")
	if code != 0 {
		t.Fatalf("update: %d\n%s", code, out)
	}
	if !strings.Contains(out, "Updated lib") {
		t.Errorf("expected 'Updated lib', got:\n%s", out)
	}
	if got := f.readLocal("new.txt"); got != "upstream new\n" {
		t.Errorf("upstream file not landed: %q", got)
	}
	if got := f.readLocal("local.txt"); got != "user only\n" {
		t.Errorf("local change lost: %q", got)
	}
	if p := f.unmerged(); len(p) != 0 {
		t.Errorf("clean landing must not leave unmerged paths: %v", p)
	}
	if f.mirrorHead() != f.mirrorOrigin() {
		t.Error("mirror branch should follow the landed revision")
	}
	// A second update is a no-op.
	out, _ = run(t, f.root, binPath, "update")
	if !strings.Contains(out, "already up to date") {
		t.Errorf("second update should be a no-op, got:\n%s", out)
	}
}

// TestUpdateRefusesUnstagedChanges pins the git-like ask-first rule. Staged
// content must NOT block (cherry-pick merges into the index).
func TestUpdateRefusesUnstagedChanges(t *testing.T) {
	f := newFixture(t)
	f.commitAll("vendor: initial")

	f.writeLocal("c.yaml", "NAME: BBB\n") // unstaged
	f.writeUpstream("c.yaml", "NAME: CCC\n")
	git(t, f.up, "commit", "-qam", "v2")

	out, code := run(t, f.root, binPath, "update")
	if code != 0 {
		t.Fatalf("update: %d\n%s", code, out)
	}
	if !strings.Contains(out, "has modified files; commit them in your repo first") {
		t.Errorf("expected the ask-first warning, got:\n%s", out)
	}
	if !strings.Contains(out, "not updated") {
		t.Errorf("expected 'not updated', got:\n%s", out)
	}
	if got := f.readLocal("c.yaml"); got != "NAME: BBB\n" {
		t.Errorf("uncommitted change was destroyed: %q", got)
	}
	// The fetch still happened: the upstream tree is in the mirror.
	gd := f.mirror()
	if o := strings.TrimSpace(git(t, f.root, "--git-dir", gd, "show", "refs/remotes/origin/main:src/lib/c.yaml")); o != "NAME: CCC" {
		t.Errorf("fetch phase should have stored upstream, got %q", o)
	}

	// Staging the same change makes it landable.
	git(t, f.root, "add", "lib")
	out, code = run(t, f.root, binPath, "update")
	if code != 0 {
		t.Fatalf("update after staging: %d\n%s", code, out)
	}
	if u := f.unmerged(); len(u) == 0 {
		t.Errorf("staged edit colliding with upstream should conflict, got output:\n%s", out)
	}
}

// TestUpdateKeepsConflictAndResolveAbort covers the conflict lifecycle up to
// --abort, including that the user's version is restored and the fetch survives.
func TestUpdateKeepsConflictAndResolveAbort(t *testing.T) {
	f := newFixture(t)
	f.commitAll("vendor: initial")
	f.writeLocal("c.yaml", "NAME: BBB\n")
	f.commitAll("vendor: local BBB")

	f.writeUpstream("c.yaml", "NAME: CCC\n")
	git(t, f.up, "commit", "-qam", "v2")

	out, _ := run(t, f.root, binPath, "update")
	if !strings.Contains(out, "conflict in 'lib'") {
		t.Fatalf("expected a kept conflict, got:\n%s", out)
	}
	if !strings.Contains(out, "git cross resolve") {
		t.Errorf("output should point at resolve:\n%s", out)
	}
	if u := f.unmerged(); len(u) == 0 {
		t.Fatal("conflict must surface as unmerged paths in the USER repo")
	}
	if got := f.readLocal("c.yaml"); !strings.Contains(got, "<<<<<<<") {
		t.Errorf("expected conflict markers in the patch dir, got %q", got)
	}
	// A second update must not reset over the pending state.
	out, _ = run(t, f.root, binPath, "update")
	if !strings.Contains(out, "pending conflict") {
		t.Errorf("second update should report the pending conflict, got:\n%s", out)
	}
	if len(f.unmerged()) == 0 {
		t.Error("pending state must survive a second update")
	}

	// resolve (no flags) lists the paths and exits non-zero.
	out, code := run(t, f.root, binPath, "resolve")
	if code == 0 {
		t.Errorf("resolve with leftovers should exit non-zero, got:\n%s", out)
	}
	if !strings.Contains(out, "lib/src/lib/c.yaml") {
		t.Errorf("resolve should list the unmerged path, got:\n%s", out)
	}

	out, code = run(t, f.root, binPath, "resolve", "--abort")
	if code != 0 {
		t.Fatalf("resolve --abort: %d\n%s", code, out)
	}
	if u := f.unmerged(); len(u) != 0 {
		t.Errorf("--abort must clear unmerged paths: %v", u)
	}
	if got := f.readLocal("c.yaml"); got != "NAME: BBB\n" {
		t.Errorf("--abort must restore the user's version, got %q", got)
	}
	if f.mirrorHead() == f.mirrorOrigin() {
		t.Error("--abort must not advance the mirror (upstream stays fetched)")
	}
}

// TestResolveContinueAndRerereReplay covers the full cycle: resolve by hand,
// --continue lets the mirror follow, and an identical conflict later is replayed
// from the rerere cache in the USER repo.
func TestResolveContinueAndRerereReplay(t *testing.T) {
	f := newFixture(t)
	f.commitAll("vendor: initial")
	baseMirror := f.mirrorHead() // mirror at upstream v1 (base AAA)

	f.writeLocal("c.yaml", "NAME: BBB\n")
	f.commitAll("vendor: local BBB")
	oursBefore := strings.TrimSpace(git(t, f.root, "rev-parse", "HEAD"))

	f.writeUpstream("c.yaml", "NAME: CCC\n")
	git(t, f.up, "commit", "-qam", "v2")

	if out, _ := run(t, f.root, binPath, "update"); !strings.Contains(out, "conflict in 'lib'") {
		t.Fatalf("expected conflict, got:\n%s", out)
	}
	f.writeLocal("c.yaml", "NAME: BBB\nNAME: CCC\n")
	git(t, f.root, "add", "lib")

	out, code := run(t, f.root, binPath, "resolve", "--continue")
	if code != 0 {
		t.Fatalf("resolve --continue: %d\n%s", code, out)
	}
	if !strings.Contains(out, "is clean") {
		t.Errorf("--continue should confirm cleanliness, got:\n%s", out)
	}
	if f.mirrorHead() != f.mirrorOrigin() {
		t.Error("--continue must let the mirror follow")
	}
	f.commitAll("vendor: resolved")

	// rerere lives in the user's repo, not in the mirror.
	if entries, _ := os.ReadDir(filepath.Join(f.root, ".git", "rr-cache")); len(entries) == 0 {
		t.Fatal("rerere should have recorded the resolution in <repo>/.git/rr-cache")
	}

	// Recreate the identical preimage: ours=BBB, base=AAA, theirs=CCC.
	git(t, f.root, "reset", "--hard", oursBefore)
	git(t, f.root, "--git-dir", f.mirror(), "update-ref", "refs/heads/main", baseMirror)

	out, _ = run(t, f.root, binPath, "update")
	if strings.Contains(out, "<<<<<<<") {
		t.Logf("output:\n%s", out)
	}
	if got := f.readLocal("c.yaml"); strings.Contains(got, "<<<<<<<") {
		t.Errorf("expected rerere to replay the recorded resolution, got markers:\n%s", got)
	}
	if got := f.readLocal("c.yaml"); strings.TrimSpace(got) == "" {
		t.Errorf("replayed file is empty")
	}
}

// TestUpdateNoResolveLandsUpstream pins --no-resolve: upstream wins, no markers.
func TestUpdateNoResolveLandsUpstream(t *testing.T) {
	f := newFixture(t)
	f.commitAll("vendor: initial")
	f.writeLocal("c.yaml", "NAME: BBB\n")
	f.commitAll("vendor: local BBB")

	f.writeUpstream("c.yaml", "NAME: CCC\n")
	git(t, f.up, "commit", "-qam", "v2")

	out, code := run(t, f.root, binPath, "update", "--no-resolve")
	if code != 0 {
		t.Fatalf("update --no-resolve: %d\n%s", code, out)
	}
	if got := f.readLocal("c.yaml"); got != "NAME: CCC\n" {
		t.Errorf("--no-resolve should land upstream (%q), got %q", "NAME: CCC\n", got)
	}
	if u := f.unmerged(); len(u) != 0 {
		t.Errorf("--no-resolve must not leave unmerged paths: %v", u)
	}
	if f.mirrorHead() != f.mirrorOrigin() {
		t.Error("--no-resolve should advance the mirror")
	}
}
