package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"unicode/utf8"

	"github.com/fatih/color"
	"github.com/gogs/git-module"
	"github.com/olekukonko/tablewriter"
	"github.com/spf13/cobra"
	"github.com/zloylos/grsync"
)

const (
	MetadataRelPath  = ".cross/metadata.json"
	CrossfileRelPath = "Crossfile"
)

func getRepoRoot() (string, error) {
	out, err := exec.Command("git", "rev-parse", "--show-toplevel").Output()
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

func parseCrossOverrides(data string) []string {
	var overrides []string
	for _, line := range strings.Split(data, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		overrides = append(overrides, line)
	}
	return overrides
}

func globMatch(pattern, value string) bool {
	patternRunes := []rune(pattern)
	valueRunes := []rune(value)
	pi, vi := 0, 0
	star, match := -1, 0

	for vi < len(valueRunes) {
		if pi < len(patternRunes) && (patternRunes[pi] == valueRunes[vi] || patternRunes[pi] == '?') {
			pi++
			vi++
			continue
		}
		if pi < len(patternRunes) && patternRunes[pi] == '*' {
			star = pi
			match = vi
			pi++
			continue
		}
		if star != -1 {
			pi = star + 1
			match++
			vi = match
			continue
		}
		return false
	}

	for pi < len(patternRunes) && patternRunes[pi] == '*' {
		pi++
	}
	return pi == len(patternRunes)
}

func matchCrossOverride(pattern, relPath string) (string, bool) {
	pattern = strings.TrimSuffix(filepath.ToSlash(pattern), "/")
	relPath = filepath.ToSlash(relPath)
	if pattern == "" {
		return "", false
	}
	if strings.Contains(pattern, "/") {
		if relPath == pattern || strings.HasPrefix(relPath, pattern+"/") {
			return pattern, true
		}
		return "", false
	}

	parts := strings.Split(relPath, "/")
	for i, part := range parts {
		if globMatch(pattern, part) {
			return strings.Join(parts[:i+1], "/"), true
		}
	}
	return "", false
}

func getCrossOverrides(localPath string) ([]string, error) {
	data, err := os.ReadFile(filepath.Join(localPath, ".crossignore"))
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}

	patterns := parseCrossOverrides(string(data))
	if len(patterns) == 0 {
		return nil, nil
	}

	seen := make(map[string]bool)
	var overrides []string
	err = filepath.WalkDir(localPath, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if path == localPath {
			return nil
		}
		relPath, err := filepath.Rel(localPath, path)
		if err != nil {
			return err
		}
		relPath = filepath.ToSlash(relPath)
		if relPath == ".git" || strings.HasPrefix(relPath, ".git/") {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}

		for _, pattern := range patterns {
			matchedPath, ok := matchCrossOverride(pattern, relPath)
			if !ok {
				continue
			}
			if !seen[matchedPath] {
				seen[matchedPath] = true
				overrides = append(overrides, matchedPath)
			}
			if d.IsDir() && matchedPath == relPath {
				return filepath.SkipDir
			}
			break
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.Strings(overrides)
	return overrides, nil
}

func hasCrossOverrides(localPath string) (bool, error) {
	overrides, err := getCrossOverrides(localPath)
	if err != nil {
		return false, err
	}
	return len(overrides) > 0, nil
}

type Patch struct {
	Remote     string `json:"remote"`
	RemotePath string `json:"remote_path"`
	LocalPath  string `json:"local_path"`
	Worktree   string `json:"worktree"`
	Branch     string `json:"branch"`
}

type Metadata struct {
	Patches []Patch `json:"patches"`
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

func detectRemoteBranch(repo *git.Repository, remote string) (string, error) {
	urlBytes, err := git.NewCommand("remote", "get-url", remote).RunInDir(repo.Path())
	if err != nil {
		return "", err
	}
	return detectDefaultBranch(strings.TrimSpace(string(urlBytes)))
}

func logInfo(msg string) {
	color.New(color.Bold, color.FgBlue).Print("==> ")
	fmt.Println(msg)
}

func logSuccess(msg string) {
	color.New(color.Bold, color.FgGreen).Print("==> ")
	fmt.Println(msg)
}

func logWarn(msg string) {
	color.New(color.Bold, color.FgYellow).Print("==> WARNING: ")
	fmt.Println(msg)
}

// envList splits a comma-separated environment variable into trimmed items.
func envList(name string) []string {
	raw := strings.TrimSpace(os.Getenv(name))
	if raw == "" {
		return nil
	}
	var items []string
	for _, part := range strings.Split(raw, ",") {
		if p := strings.TrimSpace(part); p != "" {
			items = append(items, p)
		}
	}
	return items
}

// vimValue makes a value safe to embed in a vim single-quoted string and in
// the double-quoted bash argument that carries the +cmd.
func vimValue(s string) string {
	s = strings.ReplaceAll(s, "\n", " ")
	s = strings.ReplaceAll(s, `"`, "")
	return strings.ReplaceAll(s, "'", "''")
}

// vimIgnoreRegexp turns comma-separated keywords into a vim regexp.
// \V (very nomagic) makes every character literal, so dots etc. need no
// escaping; \| remains alternation.
func vimIgnoreRegexp(keywords []string) string {
	escaped := make([]string, 0, len(keywords))
	for _, k := range keywords {
		escaped = append(escaped, strings.ReplaceAll(k, `\`, `\\`))
	}
	return `\V` + strings.Join(escaped, `\|`)
}

// defaultDiffTool returns the built-in diff tool command: nvim when available,
// otherwise vim. Separate +cmd arguments set the exclusions and, when
// DIRDIFF_IGNORE is set, the diff-content keywords to ignore; then DirDiff runs
// on the given directories. .git is always excluded.
func defaultDiffTool() string {
	editor := "vim"
	if _, err := exec.LookPath("nvim"); err == nil {
		editor = "nvim"
	}
	excludes := append([]string{".git"}, envList("DIRDIFF_EXCLUDES")...)
	args := []string{fmt.Sprintf(`"+let g:DirDiffExcludes = '%s'"`, vimValue(strings.Join(excludes, ",")))}
	if keywords := envList("DIRDIFF_IGNORE"); len(keywords) > 0 {
		args = append(args, fmt.Sprintf(`"+let g:DirDiffIgnore = '%s'"`, vimValue(vimIgnoreRegexp(keywords))))
	}
	args = append(args, `"+DirDiff {left} {right}"`)
	return editor + " " + strings.Join(args, " ")
}

func diffTool() string {
	if out, err := exec.Command("git", "config", "--get", "cross.diffTool").Output(); err == nil {
		if tool := strings.TrimSpace(string(out)); tool != "" {
			return tool
		}
	}
	return defaultDiffTool()
}

// runDiffTool executes the configured diff tool. If the tool string contains
// {left}/{right} placeholders, they are substituted with repo-relative paths
// and the command runs with cwd = repo root. Legacy configs without
// placeholders keep the old behavior (paths appended as arguments).
func runDiffTool(root, left, right string) error {
	tool := diffTool()
	relLeft, errL := filepath.Rel(root, left)
	relRight, errR := filepath.Rel(root, right)
	if errL != nil || errR != nil {
		relLeft, relRight = left, right
	}
	var c *exec.Cmd
	if strings.Contains(tool, "{left}") || strings.Contains(tool, "{right}") {
		cmdline := strings.NewReplacer("{left}", relLeft, "{right}", relRight).Replace(tool)
		c = exec.Command("bash", "-c", cmdline, "cross-diff")
	} else {
		c = exec.Command("bash", "-c", tool+` "$@"`, "cross-diff", left, right)
	}
	c.Dir = root
	c.Stdin, c.Stdout, c.Stderr = os.Stdin, os.Stdout, os.Stderr
	return c.Run()
}

func localDiffersFromWorktree(localPath, worktreePath string) (bool, error) {
	if _, err := os.Stat(localPath); os.IsNotExist(err) {
		return false, nil
	} else if err != nil {
		return false, err
	}
	return directoriesDiffer(worktreePath, localPath)
}

func logError(msg string) {
	color.New(color.Bold, color.FgRed).Print("==> ERROR: ")
	fmt.Println(msg)
}

// printPatchRows prints one row per patch: local_path <TAB> worktree.
// Rows go to stdout (parseable via cut -f1); hint goes to stderr, so
// `git cross compare 2>/dev/null | cut -f1` yields local paths.
// When stdout is a terminal the first column is space-padded so the
// worktree column lines up; piped output stays pure TAB-separated.
func printPatchRows(hint string) error {
	meta, err := loadMetadata()
	if err != nil {
		return err
	}
	if len(meta.Patches) == 0 {
		logInfo("No patches configured.")
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
			fmt.Printf("%-*s  %s\n", width, p.LocalPath, p.Worktree)
		}
		return nil
	}
	for _, p := range meta.Patches {
		fmt.Printf("%s\t%s\n", p.LocalPath, p.Worktree)
	}
	return nil
}

// printRawRows writes rows as TAB-separated values when piped, or as
// space-aligned columns when stdout is a terminal (readable interactively
// without breaking the TAB contract for scripts).
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

// stdoutIsTerminal reports whether stdout is attached to a TTY (interactive
// output may be padded for readability; pipes keep the TAB contract).
func stdoutIsTerminal() bool {
	info, err := os.Stdout.Stat()
	if err != nil {
		return false
	}
	return info.Mode()&os.ModeCharDevice != 0
}

// errPatchNotFound is returned after rows were already printed; commands
// that use it set SilenceErrors+SilenceUsage so nothing extra is printed.
var errPatchNotFound = errors.New("patch not found")

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
	err = json.Unmarshal(data, &meta)
	if err != nil {
		return meta, err
	}
	// Self-heal legacy local paths (e.g. "./mxc2" -> "mxc2") so the next
	// save rewrites normalized paths.
	for i := range meta.Patches {
		meta.Patches[i].LocalPath = filepath.ToSlash(filepath.Clean(meta.Patches[i].LocalPath))
	}
	return meta, nil
}

func saveMetadata(meta Metadata) error {
	path, err := getMetadataPath()
	if err != nil {
		return err
	}
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
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
	// Improved deduplication: check for exact line or line without 'cross ' prefix
	lineWithoutPrefix := strings.TrimPrefix(line, "cross ")
	lines := strings.Split(content, "\n")
	for _, l := range lines {
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

func runSync(src, dst string) error {
	task := grsync.NewTask(src, dst, grsync.RsyncOptions{
		Archive: true,
		Verbose: true,
		Delete:  true,
		Exclude: []string{".git"},
	})

	if err := task.Run(); err != nil {
		return fmt.Errorf("rsync failed: %v\nLog: %v", err, task.Log())
	}
	return nil
}

// directoriesDiffer reports whether two directory trees differ, ignoring
// .git (the worktree's pointer file never exists in the local copy).
// -c: checksum compare; no -t so time-only changes don't produce lines.
// --delete: files existing only on the right side are reported.
func directoriesDiffer(left, right string) (bool, error) {
	c := exec.Command("rsync", "-rlcn", "--delete", "--exclude=.git",
		"--itemize-changes",
		left+string(os.PathSeparator), right+string(os.PathSeparator))
	out, err := c.Output()
	if err != nil {
		return false, fmt.Errorf("rsync compare %s vs %s: %w\n%s", left, right, err, out)
	}
	return strings.TrimSpace(string(out)) != "", nil
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
		if len(fields) == 0 || (fields[0] != "use" && fields[0] != "patch") {
			return nil, fmt.Errorf("unsupported Crossfile command on line %d (update accepts only use and patch declarations)", lineNumber)
		}
		commands = append(commands, fields)
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return commands, nil
}

func detectDefaultBranch(url string) (string, error) {
	cmd := exec.Command("git", "ls-remote", "--symref", url, "HEAD")
	if out, err := cmd.CombinedOutput(); err == nil {
		lines := strings.Split(string(out), "\n")
		for _, line := range lines {
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

	refs, err := git.LsRemote(url, git.LsRemoteOptions{Heads: true})
	if err != nil {
		return "", err
	}

	for _, candidate := range []string{"main", "master"} {
		refName := "refs/heads/" + candidate
		for _, ref := range refs {
			if ref.Refspec == refName {
				return candidate, nil
			}
		}
	}

	for _, ref := range refs {
		if strings.HasPrefix(ref.Refspec, "refs/heads/") {
			return strings.TrimPrefix(ref.Refspec, "refs/heads/"), nil
		}
	}

	return "main", nil
}

// removeFromCrossfile removes lines matching a specific patch local_path
// using structured field matching instead of fragile substring search.
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
		// Only filter "patch" lines; leave "use", "exec", etc. intact
		fields := strings.Fields(trimmed)
		// Crossfile lines: "cross patch remote:branch:path local_path"
		// The local_path is always the last field on a patch line
		isPatchLine := false
		for _, f := range fields {
			if f == "patch" {
				isPatchLine = true
				break
			}
		}
		if isPatchLine && len(fields) > 0 && filepath.ToSlash(filepath.Clean(fields[len(fields)-1])) == localPath {
			continue // skip this line
		}
		newLines = append(newLines, line)
	}
	if err := os.WriteFile(path, []byte(strings.Join(newLines, "\n")), 0o644); err != nil {
		logError(fmt.Sprintf("Failed to update Crossfile: %v", err))
	}
}

// removeSinglePatch removes a patch by local_path: worktree, crossfile entry,
// metadata entry, and local directory. Used by both `remove` and `prune`.
func removeSinglePatch(meta *Metadata, localPath string) error {
	localPath = filepath.Clean(localPath)

	patchIdx := -1
	var patch *Patch
	for i, p := range meta.Patches {
		if p.LocalPath == localPath {
			patch = &meta.Patches[i]
			patchIdx = i
			break
		}
	}
	if patch == nil {
		return fmt.Errorf("patch not found for path: %s", localPath)
	}

	logInfo(fmt.Sprintf("Removing patch at %s...", localPath))

	// 1. Remove worktree
	if _, err := os.Stat(patch.Worktree); err == nil {
		logInfo(fmt.Sprintf("Removing git worktree at %s...", patch.Worktree))
		if _, err := git.NewCommand("worktree", "remove", "--force", patch.Worktree).RunInDir("."); err != nil {
			logError(fmt.Sprintf("Failed to remove worktree: %v", err))
		}
	}

	// 2. Remove from Crossfile
	logInfo("Removing from Crossfile...")
	removeFromCrossfile(localPath)

	// 3. Remove from metadata
	logInfo("Updating metadata...")
	meta.Patches = append(meta.Patches[:patchIdx], meta.Patches[patchIdx+1:]...)

	// 4. Remove local directory (with root guard)
	if localPath != "." && localPath != "" {
		logInfo(fmt.Sprintf("Deleting local directory %s...", localPath))
		if err := os.RemoveAll(localPath); err != nil {
			logError(fmt.Sprintf("Failed to remove local directory: %v", err))
		}
	}

	return nil
}

func repoRelativePath() (string, error) {
	out, err := git.NewCommand("rev-parse", "--show-toplevel").RunInDir(".")
	if err != nil {
		return "", err
	}
	root := strings.TrimSpace(string(out))
	cwd, err := os.Getwd()
	if err != nil {
		return "", err
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
		// Clean stored paths defensively so legacy metadata (e.g. "./mxc2")
		// still matches; this heals without a migration step.
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

func findPatchForPathFromCWD(meta Metadata) (*Patch, error) {
	root, err := getRepoRoot()
	if err != nil {
		return nil, err
	}
	cwd, err := os.Getwd()
	if err != nil {
		return nil, err
	}
	rel, err := filepath.Rel(root, cwd)
	if err != nil {
		return nil, err
	}
	return findPatchForPath(meta, filepath.ToSlash(rel)), nil
}

// resolvePathToRepoRelative converts any path (relative, absolute, or repo-relative)
// to a repo-relative path for matching against metadata
func resolvePathToRepoRelative(inputPath string) (string, error) {
	if inputPath == "" {
		return "", nil
	}

	// Get repo root
	root, err := getRepoRoot()
	if err != nil {
		return "", err
	}

	// Get current working directory
	cwd, err := os.Getwd()
	if err != nil {
		return "", err
	}

	// Resolve input path to absolute
	var absPath string
	if filepath.IsAbs(inputPath) {
		absPath = inputPath
	} else {
		absPath = filepath.Join(cwd, inputPath)
	}

	// Clean the path (resolves . and ..)
	absPath = filepath.Clean(absPath)

	// Evaluate symlinks to handle /tmp -> /private/tmp on macOS
	// If the path doesn't exist yet, keep the cleaned absolute path.
	if resolved, err := filepath.EvalSymlinks(absPath); err == nil {
		absPath = resolved
	}

	// Also evaluate symlinks for root to ensure consistent comparison
	rootResolved, err := filepath.EvalSymlinks(root)
	if err == nil {
		root = rootResolved
	}

	// Get relative path from repo root
	relPath, err := filepath.Rel(root, absPath)
	if err != nil {
		return "", err
	}

	// Convert to forward slashes for consistency
	relPath = filepath.ToSlash(relPath)

	// If the path is outside the repo, return error
	if strings.HasPrefix(relPath, "..") {
		return "", fmt.Errorf("path is outside repository: %s", inputPath)
	}

	// Normalize: remove . and trim slashes
	if relPath == "." {
		return "", nil
	}

	return strings.Trim(relPath, "/"), nil
}

// pickerWidth is the padded width of the LOCAL_PATH column: the widest
// local_path plus a two-space gap, clamped so one long path cannot push the
// second column off screen.
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

// pickerLabel is the second picker column: remote:remote_path, with the branch
// in parentheses when it is not the usual default.
func pickerLabel(p Patch) string {
	label := p.Remote + ":" + p.RemotePath
	if p.Branch != "" && p.Branch != "main" {
		label += " (" + p.Branch + ")"
	}
	return label
}

// selectPatchInteractive lets the user pick a patch with fzf. Rows are
// space-padded for alignment (TAB is used only as the hidden field separator),
// with the local_path repeated as the last field so the selection is parseable.
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
		"--prompt",
		"Select patch> ",
		"--header",
		fmt.Sprintf("%-*s%s", width, "LOCAL_PATH", "REMOTE:REMOTE_PATH"),
		"--height",
		"40%",
		"--border",
		"--select-1",
		"--exit-0",
	)
	cmd.Stdin = strings.NewReader(b.String())
	out, err := cmd.Output()
	selection := strings.TrimSpace(string(out))
	if err != nil || selection == "" {
		return nil, nil // user cancelled (ESC / empty)
	}

	// The local_path is always the last TAB-delimited field.
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

	return nil, fmt.Errorf("selected patch not found: %s", localPath)
}

// runNoIndexDiff prints a unified diff between the upstream worktree directory
// and the local copy. A worktree root contains a `.git` pointer file that the
// local copy never has; pathspec excludes are not portable across git versions
// (older gits reject them with a usage error), so when `.git` is present we
// diff against a temporary mirror that omits it.
func runNoIndexDiff(upstreamPath, localPath string) {
	left := upstreamPath
	cleanup := func() {}
	if _, err := os.Stat(filepath.Join(upstreamPath, ".git")); err == nil {
		if tmp, terr := os.MkdirTemp("", "cross-diff-"); terr == nil {
			// --link-dest hardlinks unchanged files, so the mirror is cheap.
			cmd := exec.Command("rsync", "-a", "--exclude=.git",
				"--link-dest="+upstreamPath+string(os.PathSeparator),
				upstreamPath+string(os.PathSeparator), tmp+string(os.PathSeparator))
			if _, rerr := cmd.CombinedOutput(); rerr == nil {
				left = tmp
				cleanup = func() { os.RemoveAll(tmp) }
			} else {
				os.RemoveAll(tmp)
			}
		}
	}
	defer cleanup()

	c := exec.Command("git", "diff", "--no-index", left, localPath)
	c.Stdout = os.Stdout
	c.Stderr = os.Stderr
	// git diff --no-index returns 1 when differences exist; that is not an error.
	_ = c.Run()
}

const posixShellInit = `# git-cross cd wrappers (part of: eval "$(git cross completion bash|zsh)")
crosscd() { local p; p="$(git cross cd "$@")" || return; [ -n "$p" ] && cd "$p"; }
crosswt() { local p; p="$(git cross wt "$@")" || return; [ -n "$p" ] && cd "$p"; }
`

const fishShellInit = `# git-cross cd wrappers (part of: git cross completion fish | source)
function crosscd --description 'cd into a git-cross patch'
    set -l p (git cross cd $argv)
    or return
    test -n "$p"; and cd $p
end
function crosswt --description 'cd into a git-cross worktree'
    set -l p (git cross wt $argv)
    or return
    test -n "$p"; and cd $p
end
`

// shellIntegrationHint returns the one-liner that fits the caller's $SHELL.
// fish joins multi-line command substitution with spaces, so it needs `| source`.
func shellIntegrationHint() string {
	if strings.ToLower(filepath.Base(strings.TrimSpace(os.Getenv("SHELL")))) == "fish" {
		return "Shell integration (cd wrappers + completions): git cross completion fish | source"
	}
	return `Shell integration (cd wrappers + completions): eval "$(git cross completion)"`
}

// supportedShells is the canonical order for help and error hints.
const supportedShells = "fish, bash, zsh, powershell"

// resolveShell picks the shell from an explicit argument, falling back to the
// basename of $SHELL. An unknown or undetectable shell is an error: guessing a
// default would emit a script the caller cannot evaluate.
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

// ensureRerere enables reuse-recorded-resolution in the shared repo config, so
// conflict resolutions recorded in any cross worktree (merge/rebase) are
// replayed automatically when the same conflict reappears on later updates.
// Returns true when the setting was newly enabled.
func ensureRerere(root string) bool {
	if out, err := exec.Command("git", "-C", root, "config", "--get", "rerere.enabled").Output(); err == nil {
		if strings.TrimSpace(string(out)) == "true" {
			return false
		}
	}
	if err := exec.Command("git", "-C", root, "config", "rerere.enabled", "true").Run(); err != nil {
		logWarn(fmt.Sprintf("could not enable rerere: %v", err))
		return false
	}
	return true
}

// copyToClipboard copies text using the first available platform tool
// (pbcopy/xclip/xsel).
//
// Currently unused: cd/wt print a path and completion provides the real cd, so
// the clipboard workflow is obsolete. Kept isolated for possible reuse.
func copyToClipboard(text string) error {
	candidates := [][]string{
		{"pbcopy"},
		{"xclip", "-selection", "clipboard"},
		{"xsel", "--clipboard", "--input"},
	}
	for _, cand := range candidates {
		if _, err := exec.LookPath(cand[0]); err != nil {
			continue
		}
		c := exec.Command(cand[0], cand[1:]...)
		c.Stdin = strings.NewReader(text)
		if err := c.Run(); err != nil {
			return fmt.Errorf("%s failed: %w", cand[0], err)
		}
		return nil
	}
	return errors.New("no clipboard tool found (pbcopy/xclip/xsel)")
}

func main() {
	// Keep authored order in --help: use/patch must come first.
	cobra.EnableCommandSorting = false
	var dry string
	rootCmd := &cobra.Command{
		Use:          "git-cross",
		Version:      "0.4.0",
		Short:        "Manage vendored cross-repo patches (worktree + rsync)",
		SilenceUsage: true, // no Usage dump on errors
		Long: `Manage vendored cross-repo patches (worktree + rsync).

Directory diff tool (compare / cmp): when cross.diffTool is unset, nvim is used
if installed, otherwise vim, with .git ignored. To use the built-in default:

  git config --global --unset cross.diffTool

To pin it explicitly (recommended):

  git config --global cross.diffTool "nvim \"+let g:DirDiffExcludes = '.git'\" \"+DirDiff {left} {right}\""

Replace nvim with vim to pin vim instead.

Environment variables (used only when cross.diffTool is unset):
  DIRDIFF_EXCLUDES  extra comma-separated file/dir names to hide; .git is always ignored
  DIRDIFF_IGNORE    comma-separated keywords ignored in diff content (e.g. github.com,gitlab.com)

Shell completions + cd wrappers (crosscd / crosswt) - evaluate once in your profile:
  git cross completion fish | source    # fish
  eval "$(git cross completion)"        # bash / zsh`,
		RunE: func(cmd *cobra.Command, args []string) error {
			return printPatchRows("")
		},
		CompletionOptions: cobra.CompletionOptions{DisableDefaultCmd: true},
	}
	rootCmd.AddGroup(
		&cobra.Group{ID: "patches", Title: "Patch Lifecycle:"},
		&cobra.Group{ID: "repo", Title: "Repository:"},
		&cobra.Group{ID: "inspect", Title: "Inspect & Navigate:"},
	)
	// Group the builtin help command so no ungrouped visible command remains
	// (Cobra otherwise renders it under "Additional Commands:").
	rootCmd.SetHelpCommand(&cobra.Command{
		Use:     "help [command]",
		Short:   "Help about any command",
		GroupID: "repo",
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
	rootCmd.PersistentFlags().StringVar(&dry, "dry", "", "Dry run command (e.g. echo)")

	useCmd := &cobra.Command{
		Use:     "use [name] [url]",
		Short:   "Add a remote repository",
		GroupID: "patches",
		Args:    cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			name, url := args[0], args[1]
			logInfo(fmt.Sprintf("Adding remote %s (%s)...", name, url))

			repo, err := git.Open(".")
			if err != nil {
				return err
			}

			if urls, _ := repo.RemoteGetURL(name); len(urls) > 0 {
				if _, err := git.NewCommand("remote", "set-url", name, url).RunInDir("."); err != nil {
					return err
				}
			} else {
				if err := repo.RemoteAdd(name, url); err != nil {
					return err
				}
			}

			logInfo("Autodetecting default branch...")
			branch, err := detectDefaultBranch(url)
			if err != nil {
				logError(fmt.Sprintf("Failed to detect branch: %v. Falling back to main.", err))
				branch = "main"
			}
			logInfo(fmt.Sprintf("Detected default branch: %s", branch))

			if err := repo.Fetch(git.FetchOptions{
				CommandOptions: git.CommandOptions{
					Args: []string{name, branch},
				},
			}); err != nil {
				return err
			}

			updateCrossfile(fmt.Sprintf("use %s %s", name, url))
			logSuccess("Remote added and Crossfile updated.")
			return nil
		},
	}

	patchCmd := &cobra.Command{
		Use:     "patch [spec] [local_path]",
		Short:   "Vendor a directory from a remote",
		GroupID: "patches",
		Args:    cobra.MinimumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			specInput := args[0]
			spec, err := parsePatchSpec(specInput)
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

			repo, err := git.Open(".")
			if err != nil {
				return err
			}

			if !spec.BranchProvided {
				logInfo("Autodetecting default branch...")
				branch, err := detectRemoteBranch(repo, spec.Remote)
				if err != nil {
					logError(fmt.Sprintf("Failed to detect branch: %v. Falling back to main.", err))
					spec.Branch = "main"
				} else {
					spec.Branch = branch
				}
				logInfo(fmt.Sprintf("Using branch: %s", spec.Branch))
			}
			if spec.Branch == "" {
				spec.Branch = "main"
			}

			if _, err := git.NewCommand("remote", "get-url", spec.Remote).RunInDir(repo.Path()); err != nil {
				return fmt.Errorf("remote %s not found", spec.Remote)
			}

			// Remember conflict resolutions so later updates can reuse them.
			ensureRerere(repo.Path())

			canonical := canonicalSpec(spec)
			logInfo(fmt.Sprintf("Patching %s to %s", canonical, localPath))

			if _, err := git.NewCommand("fetch", spec.Remote, spec.Branch).RunInDir(repo.Path()); err != nil {
				return fmt.Errorf("git fetch %s %s failed: %w", spec.Remote, spec.Branch, err)
			}

			h := sha256.New()
			h.Write([]byte(spec.Remote + "\x00" + spec.RemotePath + "\x00" + spec.Branch))
			hash := hex.EncodeToString(h.Sum(nil))[:8]

			wtDir := fmt.Sprintf(".cross/worktrees/%s_%s", spec.Remote, hash)
			branchName := fmt.Sprintf("cross/%s/%s/%s", spec.Remote, spec.Branch, hash)
			if _, err := os.Stat(wtDir); os.IsNotExist(err) {
				logInfo(fmt.Sprintf("Setting up worktree at %s...", wtDir))
				// Only create parent dir - let git worktree add create the worktree dir itself
				if err := os.MkdirAll(filepath.Dir(wtDir), 0o755); err != nil {
					return err
				}

				// Prune stale worktree registrations (e.g. from previous failed attempts)
				exec.Command("git", "worktree", "prune").Run()

				c := exec.Command("git", "worktree", "add", "--no-checkout", "-f",
					"-B", branchName, wtDir, fmt.Sprintf("%s/%s", spec.Remote, spec.Branch))
				if out, err := c.CombinedOutput(); err != nil {
					// Clean up partial directory on failure
					os.RemoveAll(wtDir)
					return fmt.Errorf("git worktree add failed: %v\nOutput: %s", err, string(out))
				}

				if spec.RemotePath == "." {
					// Whole-repo patch: skip sparse-checkout, do full checkout
					if _, err := git.NewCommand("read-tree", "-mu", "HEAD").RunInDir(wtDir); err != nil {
						return fmt.Errorf("checkout failed: %w", err)
					}
				} else {
					// Sparse checkout — use trailing "/" so gitignore-style patterns
					// reliably match the directory and its contents in --no-cone mode.
					if _, err := git.NewCommand("sparse-checkout", "init", "--no-cone").RunInDir(wtDir); err != nil {
						return fmt.Errorf("sparse-checkout init failed: %w", err)
					}
					sparsePattern := spec.RemotePath
					if !strings.HasSuffix(sparsePattern, "/") {
						sparsePattern += "/"
					}
					if _, err := git.NewCommand("sparse-checkout", "set", sparsePattern).RunInDir(wtDir); err != nil {
						return fmt.Errorf("sparse-checkout set failed: %w", err)
					}
					// Use read-tree to explicitly populate index+worktree from HEAD,
					// because bare "git checkout" can be a no-op after --no-checkout.
					if _, err := git.NewCommand("read-tree", "-mu", "HEAD").RunInDir(wtDir); err != nil {
						return fmt.Errorf("checkout failed: %w", err)
					}
				}
			}

			logInfo(fmt.Sprintf("Syncing files to %s...", localPath))
			if err := os.MkdirAll(localPath, 0o755); err != nil {
				return err
			}
			src := filepath.Join(wtDir, spec.RemotePath) + string(os.PathSeparator)
			dst := localPath + string(os.PathSeparator)
			if err := runSync(src, dst); err != nil {
				return err
			}

			// Ensure .cross/ is in .gitignore
			ensureGitignore()
			meta, _ := loadMetadata()
			found := false
			for i, p := range meta.Patches {
				if p.LocalPath == localPath {
					meta.Patches[i] = Patch{spec.Remote, spec.RemotePath, localPath, wtDir, spec.Branch}
					found = true
					break
				}
			}
			if !found {
				meta.Patches = append(meta.Patches, Patch{spec.Remote, spec.RemotePath, localPath, wtDir, spec.Branch})
			}
			if err := saveMetadata(meta); err != nil {
				return err
			}

			updateCrossfile(fmt.Sprintf("patch %s %s", canonicalSpec(spec), localPath))
			logSuccess("Patch successful.")
			return nil
		},
	}

	syncCmd := &cobra.Command{
		Use:    "sync [path]",
		Short:  "Update patches from upstream",
		Hidden: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			path := ""
			if len(args) > 0 {
				path = args[0]
			}
			meta, _ := loadMetadata()
			root, err := getRepoRoot()
			if err != nil {
				return err
			}

			for _, p := range meta.Patches {
				if path != "" && p.LocalPath != path {
					continue
				}
				logInfo(fmt.Sprintf("Syncing %s...", p.LocalPath))

				localAbsPath := filepath.Join(root, p.LocalPath)

				// Step 1: Check for uncommitted changes in local_path
				stashed := false
				checkCmd := exec.Command("git", "-C", localAbsPath, "status", "--porcelain")
				if statusOut, err := checkCmd.Output(); err == nil && len(statusOut) > 0 {
					logInfo("Stashing local uncommitted changes...")
					stashCmd := exec.Command("git", "-C", localAbsPath, "stash", "push", "-m", "cross-sync-auto-stash")
					if err := stashCmd.Run(); err != nil {
						logError(fmt.Sprintf("Failed to stash changes in %s: %v", p.LocalPath, err))
						continue
					}
					stashed = true
				}

				// Step 2: Rsync git-tracked files from local_path → worktree
				logInfo(fmt.Sprintf("Syncing local changes to worktree %s...", p.Worktree))
				lsFilesCmd := exec.Command("git", "-C", localAbsPath, "ls-files", "-z")
				filesOut, err := lsFilesCmd.Output()
				if err != nil {
					logError(fmt.Sprintf("Failed to list git files in %s: %v", p.LocalPath, err))
					if stashed {
						exec.Command("git", "-C", localAbsPath, "stash", "pop").Run()
					}
					continue
				}

				if len(filesOut) > 0 {
					rsyncCmd := exec.Command("rsync", "-av0", "--files-from=-", "--relative", "--exclude", ".git",
						localAbsPath+"/", filepath.Join(p.Worktree, p.RemotePath)+"/")
					rsyncCmd.Stdin = strings.NewReader(string(filesOut))
					if err := rsyncCmd.Run(); err != nil {
						logError(fmt.Sprintf("Failed to rsync local to worktree: %v", err))
						if stashed {
							exec.Command("git", "-C", localAbsPath, "stash", "pop").Run()
						}
						continue
					}
				}

				// Step 3: Commit local changes in worktree
				wtRepo, err := git.Open(p.Worktree)
				if err != nil {
					logError(fmt.Sprintf("Failed to open worktree %s: %v", p.Worktree, err))
					if stashed {
						exec.Command("git", "-C", localAbsPath, "stash", "pop").Run()
					}
					continue
				}

				statusCmd := git.NewCommand("status", "--porcelain")
				if wtStatus, err := statusCmd.RunInDir(p.Worktree); err == nil && len(wtStatus) > 0 {
					logInfo("Committing local changes in worktree...")
					git.NewCommand("add", ".").RunInDir(p.Worktree)
					git.NewCommand("commit", "-m", "Sync local changes").RunInDir(p.Worktree)
				}

				// Step 4: Pull rebase from upstream
				// Refresh index to avoid false conflicts from rsync mtime changes
				exec.Command("git", "-C", p.Worktree, "update-index", "--refresh", "-q").Run()
				logInfo("Pulling updates from upstream...")
				if err := wtRepo.Pull(git.PullOptions{
					Remote: p.Remote,
					Branch: p.Branch,
					Rebase: true,
				}); err != nil {
					logError(fmt.Sprintf("Failed to pull for %s: %v", p.LocalPath, err))
					logError("Please resolve conflicts manually in worktree:")
					logError(fmt.Sprintf("  cd %s", p.Worktree))
					if stashed {
						logInfo("Note: Local changes are stashed. Run 'git stash pop' in local_path after resolving.")
					}
					continue
				}

				// Step 5: Delete tracked files in local_path that were removed upstream
				logInfo("Checking for files deleted upstream...")
				wtLsCmd := exec.Command("git", "-C", filepath.Join(p.Worktree, p.RemotePath), "ls-files")
				wtFilesOut, err := wtLsCmd.Output()
				if err == nil {
					wtFiles := make(map[string]bool)
					for _, f := range strings.Split(string(wtFilesOut), "\n") {
						if f != "" {
							wtFiles[f] = true
						}
					}

					// Get tracked files in local_path from main repo
					localLsCmd := exec.Command("git", "-C", root, "ls-files", p.LocalPath)
					localFilesOut, err := localLsCmd.Output()
					if err == nil {
						for _, localFile := range strings.Split(string(localFilesOut), "\n") {
							if localFile == "" {
								continue
							}
							// Get relative path (remove local_path prefix)
							relFile := strings.TrimPrefix(localFile, p.LocalPath+"/")
							// Check if this tracked file no longer exists in worktree
							if !wtFiles[relFile] {
								fullPath := filepath.Join(root, localFile)
								logInfo(fmt.Sprintf("Removing deleted file: %s", relFile))
								os.Remove(fullPath)
							}
						}
					}
				}

				// Step 6: Rsync worktree → local_path
				logInfo("Syncing updates back to local directory...")
				if err := runSync(p.Worktree+"/"+p.RemotePath+"/", p.LocalPath+"/"); err != nil {
					logError(fmt.Sprintf("Failed to sync files for %s: %v", p.LocalPath, err))
					if stashed {
						exec.Command("git", "-C", localAbsPath, "stash", "pop").Run()
					}
					continue
				}

				// Step 7: Restore stashed changes
				if stashed {
					logInfo("Restoring stashed local changes...")
					popCmd := exec.Command("git", "-C", localAbsPath, "stash", "pop")
					if err := popCmd.Run(); err != nil {
						logError("Failed to restore stashed changes. Conflicts may exist.")
						logError(fmt.Sprintf("Resolve manually in: %s", p.LocalPath))
						logInfo("Run 'git status' to see conflicts, then 'git stash drop' when resolved.")
					} else {
						// Check if there are conflicts after pop
						conflictCheck := exec.Command("git", "-C", localAbsPath, "diff", "--name-only", "--diff-filter=U")
						if conflictOut, err := conflictCheck.Output(); err == nil && len(conflictOut) > 0 {
							logError("Conflicts detected after restoring local changes:")
							fmt.Println(string(conflictOut))
							logInfo("Resolve conflicts, then run 'git add' and continue.")
						}
					}
				}

				logSuccess(fmt.Sprintf("Sync completed for %s", p.LocalPath))
			}
			return nil
		},
	}

	updateCmd := &cobra.Command{
		Use:     "update [path]",
		Short:   "Update Crossfile patches from upstream",
		GroupID: "repo",
		Args:    cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			root, err := getRepoRoot()
			if err != nil {
				return err
			}
			if ensureRerere(root) {
				logInfo("Enabled rerere: conflict resolutions are remembered for later updates.")
			}
			cwd, err := os.Getwd()
			if err != nil {
				return err
			}
			if err := os.Chdir(root); err != nil {
				return err
			}
			defer os.Chdir(cwd)
			crossfile, err := getCrossfilePath()
			if err != nil {
				return err
			}
			commands, err := crossfileCommands(crossfile)
			if err != nil {
				return err
			}
			selectedPath := ""
			if len(args) > 0 {
				selectedPath, err = resolvePathToRepoRelative(args[0])
				if err != nil {
					return err
				}
				if selectedPath == "" && (args[0] == "." || args[0] == root) {
					selectedPath = "."
				}
			}
			meta, err := loadMetadata()
			if err != nil {
				return err
			}
			localChanges := make(map[string]bool)
			for _, fields := range commands {
				if len(fields) == 0 || fields[0] != "patch" || len(fields) < 2 || len(fields) > 3 {
					continue
				}
				spec, err := parsePatchSpec(fields[1])
				if err != nil {
					return err
				}
				localPath := filepath.Base(spec.RemotePath)
				if len(fields) == 3 {
					localPath = fields[2]
				}
				localPath = filepath.Clean(localPath)
				if selectedPath != "" && selectedPath != localPath {
					continue
				}
				for i := range meta.Patches {
					p := &meta.Patches[i]
					if filepath.Clean(p.LocalPath) == localPath && p.Remote == spec.Remote && filepath.Clean(p.RemotePath) == filepath.Clean(spec.RemotePath) {
						localPathAbs := filepath.Join(root, localPath)
						worktreePath := filepath.Join(root, p.Worktree, p.RemotePath)
						different, err := localDiffersFromWorktree(localPathAbs, worktreePath)
						if err != nil {
							return err
						}
						localChanges[localPath] = different
						break
					}
				}
			}
			updated := 0
			matched := 0
			for _, fields := range commands {
				if fields[0] == "use" {
					if len(fields) != 3 {
						return fmt.Errorf("invalid use declaration in Crossfile: %s", strings.Join(fields, " "))
					}
					name, url := fields[1], fields[2]
					if _, err := exec.Command("git", "-C", root, "remote", "get-url", name).Output(); err != nil {
						if output, addErr := exec.Command("git", "-C", root, "remote", "add", name, url).CombinedOutput(); addErr != nil {
							return fmt.Errorf("add remote %s: %s: %w", name, strings.TrimSpace(string(output)), addErr)
						}
					} else if output, setErr := exec.Command("git", "-C", root, "remote", "set-url", name, url).CombinedOutput(); setErr != nil {
						return fmt.Errorf("update remote %s: %s: %w", name, strings.TrimSpace(string(output)), setErr)
					}
					branch, err := detectDefaultBranch(url)
					if err != nil {
						return fmt.Errorf("detect default branch for %s: %w", name, err)
					}
					if output, fetchErr := exec.Command("git", "-C", root, "fetch", name, branch).CombinedOutput(); fetchErr != nil {
						return fmt.Errorf("fetch %s: %s: %w", name, strings.TrimSpace(string(output)), fetchErr)
					}
					continue
				}
				if len(fields) < 2 || len(fields) > 3 {
					return fmt.Errorf("invalid patch declaration in Crossfile: %s", strings.Join(fields, " "))
				}
				spec, err := parsePatchSpec(fields[1])
				if err != nil {
					return err
				}
				localPath := ""
				if len(fields) == 3 {
					localPath = fields[2]
				} else {
					localPath = filepath.Base(spec.RemotePath)
				}
				localPath = filepath.Clean(localPath)
				if filepath.IsAbs(localPath) || localPath == ".." || strings.HasPrefix(localPath, ".."+string(os.PathSeparator)) {
					return fmt.Errorf("local path must stay inside the repository: %s", localPath)
				}
				if localPath == "." {
					return fmt.Errorf("updating a repository-root patch is disabled until root overlay safety is implemented")
				}
				if selectedPath != "" && selectedPath != localPath {
					continue
				}
				matched++
				var patch *Patch
				for i := range meta.Patches {
					if filepath.Clean(meta.Patches[i].LocalPath) == localPath {
						patch = &meta.Patches[i]
						break
					}
				}
				if patch == nil {
					if _, err := os.Stat(filepath.Join(root, localPath)); err == nil {
						return fmt.Errorf("local path %s exists but is not registered in metadata; refusing to overwrite it", localPath)
					}
					if err := patchCmd.RunE(cmd, []string{fields[1], localPath}); err != nil {
						return err
					}
					meta, err = loadMetadata()
					if err != nil {
						return err
					}
					updated++
					continue
				}
				if patch.Remote != spec.Remote || filepath.Clean(patch.RemotePath) != filepath.Clean(spec.RemotePath) || (spec.Branch != "" && patch.Branch != spec.Branch) {
					return fmt.Errorf("Crossfile source for %s changed; remove and re-patch it explicitly before updating", localPath)
				}
				if _, err := os.Stat(filepath.Join(root, patch.Worktree)); os.IsNotExist(err) {
					if _, localErr := os.Stat(filepath.Join(root, localPath)); localErr == nil {
						return fmt.Errorf("worktree %s is missing while local path %s exists; refusing to overwrite it. Review/remove the patch explicitly, then run update again", patch.Worktree, localPath)
					}
					if err := patchCmd.RunE(cmd, []string{fields[1], localPath}); err != nil {
						return err
					}
					meta, err = loadMetadata()
					if err != nil {
						return err
					}
					updated++
					continue
				}
				if spec.Branch == "" {
					spec.Branch = patch.Branch
				}
				localAbs := filepath.Join(root, localPath)
				upstreamAbs := filepath.Join(root, patch.Worktree, patch.RemotePath)
				localChanged := localChanges[localPath]
				if err := exec.Command("git", "-C", root, "fetch", spec.Remote, spec.Branch).Run(); err != nil {
					return fmt.Errorf("fetch %s %s: %w", spec.Remote, spec.Branch, err)
				}
				fetchHead, err := exec.Command("git", "-C", root, "rev-parse", "FETCH_HEAD").Output()
				if err != nil {
					return fmt.Errorf("resolve fetched revision: %w", err)
				}
				status, err := exec.Command("git", "-C", patch.Worktree, "status", "--porcelain").Output()
				if err != nil {
					return fmt.Errorf("inspect worktree %s: %w", patch.Worktree, err)
				}
				if len(status) != 0 {
					logError(fmt.Sprintf("Worktree has manual changes; leaving it untouched: %s", patch.Worktree))
					continue
				}
				merge := exec.Command("git", "-C", patch.Worktree, "merge", "--ff-only", strings.TrimSpace(string(fetchHead)))
				if output, err := merge.CombinedOutput(); err != nil {
					return fmt.Errorf("upstream update for %s requires manual worktree review (%s): %s", localPath, patch.Worktree, strings.TrimSpace(string(output)))
				}
				updated++
				if localChanged {
					logWarn(fmt.Sprintf("'%s' differs from upstream; local copy preserved. Compare with: git cross diff %s",
						localPath, localPath))
					continue
				}
				if err := os.MkdirAll(localAbs, 0o755); err != nil {
					return err
				}
				if err := runSync(upstreamAbs+string(os.PathSeparator), localAbs+string(os.PathSeparator)); err != nil {
					return err
				}
				logSuccess(fmt.Sprintf("Updated %s", localPath))
			}
			if selectedPath != "" && matched == 0 {
				return fmt.Errorf("no Crossfile patch found for path: %s", selectedPath)
			}
			if updated == 0 {
				logInfo("No patches updated.")
			}
			return nil
		},
	}

	compareCmd := &cobra.Command{
		Use:           "compare [path]",
		Aliases:       []string{"cmp"},
		Short:         "Open the configured directory comparison tool for a patch",
		GroupID:       "repo",
		Args:          cobra.MaximumNArgs(1),
		SilenceErrors: true,
		SilenceUsage:  true,
		RunE: func(cmd *cobra.Command, args []string) error {
			meta, err := loadMetadata()
			if err != nil {
				return err
			}
			var patch *Patch
			if len(args) > 0 {
				relPath, err := resolvePathToRepoRelative(args[0])
				if err != nil {
					return err
				}
				patch = findPatchForPath(meta, relPath)
			} else {
				patch, err = findPatchForPathFromCWD(meta)
				if err != nil {
					return err
				}
			}
			if patch == nil {
				selected, serr := selectPatchInteractive(&meta)
				if serr != nil { // fzf missing
					if rerr := printPatchRows("fzf is not installed; cd into a patched directory first or pass a path. Patches (local_path <TAB> worktree):"); rerr != nil {
						return rerr
					}
					return errPatchNotFound
				}
				if selected == nil {
					return nil // cancelled
				}
				patch = selected
			}
			root, err := getRepoRoot()
			if err != nil {
				return err
			}
			return runDiffTool(root,
				filepath.Join(root, patch.Worktree, patch.RemotePath),
				filepath.Join(root, patch.LocalPath))
		},
	}

	// Shared logic for cd/wt commands — only the target field differs.
	// Prints the selected/resolved absolute path to stdout; the caller cds via
	// `cd "$(git cross cd)"` (a child process cannot change the parent shell).
	makeDirCmd := func(use, short, long, target string) *cobra.Command {
		return &cobra.Command{
			Use: use, Short: short, Long: long,
			SilenceErrors: true, SilenceUsage: true,
			GroupID: "inspect",
			RunE: func(cmd *cobra.Command, args []string) error {
				meta, err := loadMetadata()
				if err != nil {
					return err
				}
				if len(meta.Patches) == 0 {
					logInfo("No patches configured.")
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
						if err := printPatchRows("No patch detected; available patches (local_path <TAB> worktree):"); err != nil {
							return err
						}
						return errPatchNotFound
					}
				} else {
					// No path: CWD auto-detect, then fzf, then rows+hint.
					if detected, derr := findPatchForPathFromCWD(meta); derr == nil && detected != nil {
						patch = detected
					} else {
						selected, err := selectPatchInteractive(&meta)
						if err != nil { // fzf not available
							if rerr := printPatchRows("fzf is not installed; cd manually, e.g. `cd <local_path>` or `cd <worktree>`. Destinations (local_path <TAB> worktree):"); rerr != nil {
								return rerr
							}
							return errPatchNotFound
						}
						if selected == nil {
							return nil // no selection made (ESC)
						}
						patch = selected
					}
				}
				targetPath := patch.LocalPath
				if target == "worktree" {
					targetPath = patch.Worktree
				}
				root, err := getRepoRoot()
				if err != nil {
					return err
				}
				abs := filepath.Join(root, targetPath)
				if _, err := os.Stat(abs); os.IsNotExist(err) {
					return fmt.Errorf("%s not found: %s", target, targetPath)
				}
				if dry != "" {
					fmt.Printf("%s cd %s\n", dry, abs)
					return nil
				}
				fmt.Println(abs) // stdout contract: path only
				return nil
			},
		}
	}

	cdCmd := makeDirCmd("cd [path]",
		"Print a patch local_path (use the crosscd wrapper for a real cd)",
		"Print the absolute path of a patch local_path to stdout.\n\nRunning this directly only prints a path: a child process cannot change the caller's shell, so without a wrapper the cd happens in a throwaway sub-shell. For a real directory change use the 'crosscd' wrapper:\n  eval \"$(git cross completion)\"    # bash/zsh; then: crosscd [path]\n  git cross completion fish | source  # fish\nAdd a custom alias if you like (e.g. alias gccd=crosscd).\n\nWith path: prints the specified local_path.\nWithout path: auto-detects the current patch from the working directory, otherwise uses fzf to select one.",
		"local_path")

	wtCmd := makeDirCmd("wt [path]",
		"Print a patch worktree path (use the crosswt wrapper for a real cd)",
		"Print the absolute path of a patch worktree to stdout.\n\nRunning this directly only prints a path: a child process cannot change the caller's shell, so without a wrapper the cd happens in a throwaway sub-shell. For a real directory change use the 'crosswt' wrapper:\n  eval \"$(git cross completion)\"    # bash/zsh; then: crosswt [path]\n  git cross completion fish | source  # fish\nAdd a custom alias if you like (e.g. alias gcwt=crosswt).\n\nWith path: prints the specified worktree.\nWithout path: auto-detects the current patch from the working directory, otherwise uses fzf to select one.",
		"worktree")

	// Hidden: kept for backwards compatibility. `completion` is the visible
	// entry point (it also emits the completion scripts).
	shellInitCmd := &cobra.Command{
		Use:     "shell-init [fish|bash|zsh]",
		Short:   "Print shell functions that cd into patches and worktrees",
		GroupID: "repo",
		Hidden:  true,
		Args:    cobra.MaximumNArgs(1),
		Long: `Print just the shell functions (no completion scripts). Kept for
backwards compatibility; prefer 'git cross completion'.

  fish:      git cross completion fish | source
  bash/zsh:  eval "$(git cross completion)"`,
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

	completionCmd := &cobra.Command{
		Use:     "completion [fish|bash|zsh|powershell]",
		Short:   "Print shell completions and cd wrappers to evaluate",
		GroupID: "repo",
		Args:    cobra.MaximumNArgs(1),
		Long: `Print a completion script for the requested shell, followed by the
'crosscd' / 'crosswt' functions that perform a real cd. A child process cannot
change the caller's working directory by itself, so these wrappers run the
command and cd into the path it prints.

  fish:      git cross completion fish | source   # or just: git cross completion | source
  bash/zsh:  eval "$(git cross completion)"       # or: git cross completion bash

The shell defaults to the basename of $SHELL when not given. powershell gets
completions only (no cd wrappers). After that, 'crosscd [path]' cd's into the
local copy and 'crosswt [path]' into the sparse worktree, with the same
optional path argument and fzf selection as the git-cross commands.`,
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

	listCmd := &cobra.Command{
		Use:     "list",
		Short:   "Show all configured patches and remotes",
		GroupID: "repo",
		RunE: func(cmd *cobra.Command, args []string) error {
			raw, _ := cmd.Flags().GetBool("raw")
			noHeader, _ := cmd.Flags().GetBool("no-header")
			meta, err := loadMetadata()
			if err != nil {
				return err
			}

			// Collect unique remote names from patches
			usedRemotes := make(map[string]bool)
			for _, p := range meta.Patches {
				usedRemotes[p.Remote] = true
			}

			// Map to track fetch/push URLs per remote for deduplication
			type remoteInfo struct {
				fetch string
				push  string
			}
			remoteMap := make(map[string]*remoteInfo)

			repo, err := git.Open(".")
			if err == nil && len(usedRemotes) > 0 {
				remotes, _ := git.NewCommand("remote", "-v").RunInDir(repo.Path())
				for _, line := range strings.Split(strings.TrimSpace(string(remotes)), "\n") {
					fields := strings.Fields(line)
					if len(fields) < 3 {
						continue
					}
					name := fields[0]
					url := fields[1]
					rtype := fields[2] // (fetch) or (push)

					if !usedRemotes[name] {
						continue
					}

					if remoteMap[name] == nil {
						remoteMap[name] = &remoteInfo{}
					}
					if strings.Contains(rtype, "fetch") {
						remoteMap[name].fetch = url
					} else if strings.Contains(rtype, "push") {
						remoteMap[name].push = url
					}
				}
			}

			// Deterministic remote order in both output modes.
			remoteNames := make([]string, 0, len(remoteMap))
			for name := range remoteMap {
				remoteNames = append(remoteNames, name)
			}
			sort.Strings(remoteNames)

			if raw {
				// Machine-readable rows; aligned on a TTY, TAB-separated when piped.
				var rows [][]string
				if len(remoteNames) > 0 {
					if !noHeader {
						rows = append(rows, []string{"REMOTE_NAME", "REMOTE_URL"})
					}
					for _, name := range remoteNames {
						info := remoteMap[name]
						if info.fetch == "" {
							continue
						}
						rows = append(rows, []string{name, info.fetch})
						if info.push != "" && info.push != info.fetch {
							rows = append(rows, []string{name, info.push})
						}
					}
					printRawRows(rows)
				}
				if len(meta.Patches) == 0 {
					fmt.Fprintln(os.Stderr, "No patches configured.")
					return nil
				}
				rows = nil
				if !noHeader {
					rows = append(rows, []string{"REMOTE", "REMOTE_PATH", "LOCAL_PATH", "WORKTREE", "BRANCH"})
				}
				for _, p := range meta.Patches {
					rows = append(rows, []string{p.Remote, p.RemotePath, p.LocalPath, p.Worktree, p.Branch})
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
					info := remoteMap[name]
					if info.fetch == "" {
						continue
					}
					if info.fetch == info.push || info.push == "" {
						table.Append(name, info.fetch)
					} else {
						table.Append(name, info.fetch+" (fetch)")
						table.Append(name, info.push+" (push)")
					}
				}
				table.Render()
				fmt.Println()
			}

			if len(meta.Patches) == 0 {
				fmt.Println("No patches configured.")
				return nil
			}
			logInfo("Configured Patches:")
			table := tablewriter.NewWriter(os.Stdout)
			if !noHeader {
				table.Header("REMOTE", "REMOTE PATH", "LOCAL PATH", "WORKTREE", "BRANCH")
			}
			for _, p := range meta.Patches {
				table.Append(p.Remote, p.RemotePath, p.LocalPath, p.Worktree, p.Branch)
			}
			table.Render()
			return nil
		},
	}
	listCmd.Flags().Bool("raw", false, "machine-readable output: tab-separated rows, no borders, no banners")
	listCmd.Flags().Bool("no-header", false, "omit header line (applies to table mode and --raw)")

	statusCmd := &cobra.Command{
		Use:     "status",
		Short:   "Show patch status",
		GroupID: "repo",
		RunE: func(cmd *cobra.Command, args []string) error {
			meta, _ := loadMetadata()
			if len(meta.Patches) == 0 {
				fmt.Println("No patches configured.")
				return nil
			}

			// Get repo root for resolving relative paths
			root, err := getRepoRoot()
			if err != nil {
				return fmt.Errorf("failed to get repo root: %w", err)
			}

			table := tablewriter.NewWriter(os.Stdout)
			table.Header("LOCAL PATH", "DIFF", "UPSTREAM", "CONFLICTS")
			for _, p := range meta.Patches {
				diff := "Clean"
				upstream := "Synced"
				conflicts := "No"

				// Resolve worktree path relative to repo root
				worktreePath := filepath.Join(root, p.Worktree)
				if _, err := os.Stat(worktreePath); os.IsNotExist(err) {
					diff = "Missing WT"
				} else {
					localAbsPath := filepath.Join(root, p.LocalPath)
					hasOverrides, err := hasCrossOverrides(localAbsPath)
					if err != nil {
						return fmt.Errorf("failed to read .crossignore for %s: %w", p.LocalPath, err)
					}
					if hasOverrides {
						diff = "Override"
					} else {
						// Quick diff check — .git excluded, checksum-based.
						upstreamPath := filepath.Join(worktreePath, p.RemotePath)
						if differ, derr := directoriesDiffer(upstreamPath, localAbsPath); derr == nil && differ {
							diff = "Modified"
						}
					}

					behindOut, _ := git.NewCommand("rev-list", "--count", "HEAD..@{upstream}").RunInDir(worktreePath)
					aheadOut, _ := git.NewCommand("rev-list", "--count", "@{upstream}..HEAD").RunInDir(worktreePath)

					behind := strings.TrimSpace(string(behindOut))
					ahead := strings.TrimSpace(string(aheadOut))

					if behind != "" && behind != "0" {
						upstream = behind + " behind"
					} else if ahead != "" && ahead != "0" {
						upstream = ahead + " ahead"
					}

					if out, _ := git.NewCommand("ls-files", "-u").RunInDir(worktreePath); len(out) > 0 {
						conflicts = "YES"
					}

					// Also check conflicts in local path (from failed stash restore)
					if out, _ := git.NewCommand("ls-files", "-u", localAbsPath).RunInDir(root); len(out) > 0 {
						conflicts = "YES"
					}
				}
				table.Append(p.LocalPath, diff, upstream, conflicts)
			}
			return table.Render()
		},
	}

	diffCmd := &cobra.Command{
		Use:           "diff [path]",
		Short:         "Show changes between local and upstream",
		GroupID:       "inspect",
		SilenceErrors: true,
		SilenceUsage:  true,
		Long: `Show diff between local vendored files and their upstream worktree source.

When run without a path argument, auto-detects the current patch from the
working directory. Outside a patched directory it uses fzf to select a patch;
if fzf is unavailable it prints the available patches.`,
		RunE: func(cmd *cobra.Command, args []string) error {
			path := ""
			if len(args) > 0 {
				// Explicit path: resolve relative/absolute to repo-relative
				resolved, err := resolvePathToRepoRelative(args[0])
				if err != nil {
					return fmt.Errorf("failed to resolve path: %w", err)
				}
				path = resolved
			} else {
				// No explicit path: CWD auto-detect, then fzf, then rows+hint
				meta, err := loadMetadata()
				if err != nil {
					return err
				}
				patch, perr := findPatchForPathFromCWD(meta)
				if perr == nil && patch != nil {
					path = patch.LocalPath
					logInfo(fmt.Sprintf("Auto-detected patch from CWD: %s", path))
				} else if len(meta.Patches) == 0 {
					logInfo("No patches configured.")
					return nil
				} else {
					selected, serr := selectPatchInteractive(&meta)
					if serr != nil { // fzf missing
						if rerr := printPatchRows("fzf is not installed; cd into a patched directory first or pass a path. Patches (local_path <TAB> worktree):"); rerr != nil {
							return rerr
						}
						return errPatchNotFound
					}
					if selected == nil {
						return nil // cancelled
					}
					path = selected.LocalPath
				}
			}

			// Get repo root for resolving relative paths in metadata
			root, err := getRepoRoot()
			if err != nil {
				return fmt.Errorf("failed to get repo root: %w", err)
			}

			meta, err := loadMetadata()
			if err != nil {
				return err
			}
			found := false
			for _, p := range meta.Patches {
				if path != "" && p.LocalPath != path {
					continue
				}
				found = true

				// Resolve worktree path relative to repo root
				worktreePath := filepath.Join(root, p.Worktree)
				if _, err := os.Stat(worktreePath); os.IsNotExist(err) {
					logError(fmt.Sprintf("Worktree not found for %s", p.LocalPath))
					continue
				}

				// Use git diff --no-index to compare directories
				upstreamPath := filepath.Join(worktreePath, p.RemotePath)
				localPath := filepath.Join(root, p.LocalPath)
				overrides, err := getCrossOverrides(localPath)
				if err != nil {
					return fmt.Errorf("failed to read .crossignore for %s: %w", p.LocalPath, err)
				}
				if len(overrides) > 0 {
					logInfo(fmt.Sprintf(".crossignore overrides present in %s; review manually:", p.LocalPath))
					for _, override := range overrides {
						fmt.Printf("git diff --no-index %q %q\n", filepath.Join(upstreamPath, override), filepath.Join(localPath, override))
					}
				} else {
					runNoIndexDiff(upstreamPath, localPath)
				}
			}
			if !found {
				if err := printPatchRows("No patch detected; available patches (local_path <TAB> worktree):"); err != nil {
					return err
				}
				return errPatchNotFound
			}
			return nil
		},
	}

	replayCmd := &cobra.Command{
		Use:    "replay",
		Short:  "Re-execute all Crossfile commands",
		Hidden: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			logInfo("Replaying Crossfile...")
			path, err := getCrossfilePath()
			if err != nil {
				return err
			}
			_, err = os.ReadFile(path)
			if err != nil {
				return err
			}
			currExe, _ := os.Executable()
			script := fmt.Sprintf(`cross() { "%s" "$@"; }; source "%s"`, currExe, path)
			c := exec.Command("bash", "-c", script)
			c.Stdout = os.Stdout
			c.Stderr = os.Stderr
			err = c.Run()
			if err != nil {
				return err
			}
			logSuccess("Replay completed.")
			return nil
		},
	}

	var pushBranch string
	var pushForce bool
	var pushYes bool
	var pushMessage string

	pushCmd := &cobra.Command{
		Use:    "push [path]",
		Short:  "Push changes back upstream",
		Hidden: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			path := ""
			if len(args) > 0 {
				path = args[0]
			}
			meta, _ := loadMetadata()
			var patch *Patch
			for i := range meta.Patches {
				if path == "" || meta.Patches[i].LocalPath == path {
					patch = &meta.Patches[i]
					break
				}
			}
			if patch == nil {
				return fmt.Errorf("patch not found")
			}

			logInfo(fmt.Sprintf("Syncing changes from %s back to %s...", patch.LocalPath, patch.Worktree))
			if err := runSync(patch.LocalPath+"/", patch.Worktree+"/"+patch.RemotePath+"/"); err != nil {
				return err
			}

			if _, err := git.Open(patch.Worktree); err != nil {
				return err
			}

			logInfo("Worktree updated. Status:")
			out, _ := git.NewCommand("status", "--short").RunInDir(patch.Worktree)
			fmt.Print(string(out))

			if !pushYes {
				fmt.Print("Run push? (y/n): ")
				var response string
				fmt.Scanln(&response)
				if strings.ToLower(response) != "y" {
					logInfo("Push cancelled.")
					return nil
				}
			}

			msg := pushMessage
			if msg == "" {
				msg = "Update from git-cross"
				// Try to get message from parent repo log
				logOut, _ := git.NewCommand("log", "-1", "--pretty=%s", "--", patch.LocalPath).RunInDir(".")
				if len(logOut) > 0 {
					msg = strings.TrimSpace(string(logOut))
				}
			}

			logInfo("Committing and pushing...")
			if _, err := git.NewCommand("add", ".").RunInDir(patch.Worktree); err != nil {
				return err
			}
			// Use shell command for commit to handle message with spaces easily if needed,
			// though gogs/git-module should handle it.
			if _, err := git.NewCommand("commit", "-m", msg).RunInDir(patch.Worktree); err != nil {
				// might be nothing to commit, ignore
			}

			targetBranch := pushBranch
			if targetBranch == "" {
				targetBranch = patch.Branch
			}

			pushArgs := []string{"push"}
			if pushForce {
				pushArgs = append(pushArgs, "--force")
			}

			// Build full refspec to allow branch creation
			refspec := "HEAD:" + targetBranch
			if !strings.HasPrefix(targetBranch, "refs/") {
				refspec = "HEAD:refs/heads/" + targetBranch
			}

			pushArgs = append(pushArgs, patch.Remote, refspec)

			if _, err := git.NewCommand(pushArgs...).RunInDir(patch.Worktree); err != nil {
				return err
			}
			logSuccess("Push completed.")
			return nil
		},
	}
	pushCmd.Flags().StringVarP(&pushBranch, "branch", "b", "", "Target branch")
	pushCmd.Flags().BoolVarP(&pushForce, "force", "f", false, "Force push")
	pushCmd.Flags().BoolVarP(&pushYes, "yes", "y", false, "Skip confirmation")
	pushCmd.Flags().StringVarP(&pushMessage, "message", "m", "", "Commit message")

	execCmd := &cobra.Command{
		Use:    "exec [cmd]",
		Short:  "Run arbitrary command",
		Hidden: true,
		Args:   cobra.MinimumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			fullCmd := strings.Join(args, " ")
			logInfo("Executing custom command: " + fullCmd)
			c := exec.Command("bash", "-c", fullCmd)
			c.Stdout = os.Stdout
			c.Stderr = os.Stderr
			return c.Run()
		},
	}

	initCmd := &cobra.Command{
		Use:     "init",
		Short:   "Initialize a new project with Crossfile",
		GroupID: "repo",
		RunE: func(cmd *cobra.Command, args []string) error {
			if root, rerr := getRepoRoot(); rerr == nil {
				if ensureRerere(root) {
					logInfo("Enabled rerere: conflict resolutions are remembered for later updates.")
				} else {
					logInfo("rerere already enabled: conflict resolutions are reused.")
				}
			}
			path := "Crossfile"
			if _, err := os.Stat(path); err == nil {
				logInfo("Crossfile already exists.")
				return nil
			}
			err := os.WriteFile(path, []byte("# git-cross configuration\n"), 0o644)
			if err != nil {
				return err
			}
			logSuccess("Crossfile initialized.")
			logInfo(shellIntegrationHint())
			return nil
		},
	}

	removeCmd := &cobra.Command{
		Use:           "remove [path]",
		Short:         "Remove a patch and its worktree",
		GroupID:       "patches",
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
				if err := printPatchRows("No patch detected; available patches (local_path <TAB> worktree):"); err != nil {
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
			logSuccess("Patch removed successfully.")
			return nil
		},
	}

	pruneCmd := &cobra.Command{
		Use:     "prune [remote]",
		Short:   "Prune unused remotes and worktrees, or remove all patches for a specific remote",
		GroupID: "patches",
		Args:    cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			meta, _ := loadMetadata()

			if len(args) == 1 {
				// Prune specific remote: remove all its patches
				remoteName := args[0]
				logInfo(fmt.Sprintf("Pruning all patches for remote: %s...", remoteName))

				// Find all patches for this remote
				var patchesToRemove []string
				for _, p := range meta.Patches {
					if p.Remote == remoteName {
						patchesToRemove = append(patchesToRemove, p.LocalPath)
					}
				}

				if len(patchesToRemove) == 0 {
					logInfo(fmt.Sprintf("No patches found for remote: %s", remoteName))
				} else {
					for _, patchPath := range patchesToRemove {
						if err := removeSinglePatch(&meta, patchPath); err != nil {
							logError(fmt.Sprintf("Failed to remove patch %s: %v", patchPath, err))
						}
					}
					if err := saveMetadata(meta); err != nil {
						return err
					}
				}

				// Remove the remote itself
				out, _ := git.NewCommand("remote").RunInDir(".")
				remotes := strings.Split(strings.TrimSpace(string(out)), "\n")
				for _, r := range remotes {
					if strings.TrimSpace(r) == remoteName {
						logInfo(fmt.Sprintf("Removing git remote: %s", remoteName))
						git.NewCommand("remote", "remove", remoteName).RunInDir(".")
						break
					}
				}

				logSuccess(fmt.Sprintf("Remote %s and all its patches pruned successfully.", remoteName))
			} else {
				// Prune all unused remotes (no active patches)
				logInfo("Finding unused remotes...")

				// Get all remotes used by patches
				usedRemotes := make(map[string]bool)
				for _, p := range meta.Patches {
					usedRemotes[p.Remote] = true
				}

				// Get all git remotes
				out, _ := git.NewCommand("remote").RunInDir(".")
				allRemotes := strings.Split(strings.TrimSpace(string(out)), "\n")

				// Find unused remotes (excluding origin and git-cross)
				var unusedRemotes []string
				for _, remote := range allRemotes {
					remote = strings.TrimSpace(remote)
					if remote == "" || remote == "origin" || remote == "git-cross" {
						continue
					}
					if !usedRemotes[remote] {
						unusedRemotes = append(unusedRemotes, remote)
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
						for _, remote := range unusedRemotes {
							logInfo(fmt.Sprintf("Removing remote: %s", remote))
							git.NewCommand("remote", "remove", remote).RunInDir(".")
						}
						logSuccess("Unused remotes removed.")
					} else {
						logInfo("Pruning cancelled.")
					}
				}

				// Always prune stale worktrees
				logInfo("Pruning stale worktrees...")
				git.NewCommand("worktree", "prune", "--verbose").RunInDir(".")

				// Clean orphaned .cross/worktrees/ directories not referenced in metadata
				crossWtDir := ".cross/worktrees"
				if entries, err := os.ReadDir(crossWtDir); err == nil {
					knownWts := make(map[string]bool)
					for _, p := range meta.Patches {
						knownWts[p.Worktree] = true
					}
					for _, e := range entries {
						if !e.IsDir() {
							continue
						}
						wtPath := filepath.Join(crossWtDir, e.Name())
						if !knownWts[wtPath] {
							logInfo(fmt.Sprintf("Removing orphaned worktree directory: %s", wtPath))
							os.RemoveAll(wtPath)
						}
					}
				}

				logSuccess("Worktree pruning complete.")
			}

			return nil
		},
	}

	// Retain superseded implementations in source as internal reference, but do
	// not expose them as supported commands.
	_, _, _, _ = syncCmd, replayCmd, pushCmd, execCmd
	rootCmd.AddCommand(useCmd, patchCmd, removeCmd, pruneCmd, initCmd, completionCmd, listCmd, statusCmd, updateCmd, compareCmd, shellInitCmd, cdCmd, wtCmd, diffCmd)
	if err := rootCmd.Execute(); err != nil {
		os.Exit(1)
	}
}
