package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

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

func getCrossOverrides(localPath string) ([]string, error) {
	data, err := os.ReadFile(filepath.Join(localPath, ".crossignore"))
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	return parseCrossOverrides(string(data)), nil
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

func logError(msg string) {
	color.New(color.Bold, color.FgRed).Print("==> ERROR: ")
	fmt.Println(msg)
}

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
	return meta, err
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
		if isPatchLine && len(fields) > 0 && fields[len(fields)-1] == localPath {
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

	var selected *Patch
	longest := -1
	for i := range meta.Patches {
		lp := strings.Trim(meta.Patches[i].LocalPath, "/")
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
	absPath, err = filepath.EvalSymlinks(absPath)
	if err != nil {
		// If EvalSymlinks fails (path doesn't exist), continue with cleaned path
		// This allows diff to work even if path doesn't exist yet
		absPath = filepath.Clean(absPath)
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

func selectPatchInteractive(meta *Metadata) (*Patch, error) {
	if _, err := exec.LookPath("fzf"); err != nil {
		return nil, err
	}
	if len(meta.Patches) == 0 {
		return nil, nil
	}

	var b strings.Builder
	for _, p := range meta.Patches {
		b.WriteString(fmt.Sprintf("%s\t%s\t%s\n", p.Remote, p.RemotePath, p.LocalPath))
	}

	cmd := exec.Command("fzf",
		"--with-nth=1,2,3",
		"--delimiter",
		"\t",
		"--prompt",
		"Select patch> ",
		"--header",
		"REMOTE\tREMOTE_PATH\tLOCAL_PATH",
		"--height",
		"40%",
		"--border",
		"--select-1",
		"--exit-0",
	)
	cmd.Stdin = strings.NewReader(b.String())
	out, err := cmd.Output()
	if err != nil {
		return nil, err
	}

	selection := strings.TrimSpace(string(out))
	if selection == "" {
		return nil, nil
	}

	parts := strings.Split(selection, "\t")
	var localPath string
	if len(parts) >= 3 {
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

func main() {
	var dry string
	rootCmd := &cobra.Command{
		Use:     "git-cross",
		Version: "0.3.0",
	}
	rootCmd.PersistentFlags().StringVar(&dry, "dry", "", "Dry run command (e.g. echo)")

	useCmd := &cobra.Command{
		Use:   "use [name] [url]",
		Short: "Add a remote repository",
		Args:  cobra.ExactArgs(2),
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
		Use:   "patch [spec] [local_path]",
		Short: "Vendor a directory from a remote",
		Args:  cobra.MinimumNArgs(1),
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
		Use:   "sync [path]",
		Short: "Update patches from upstream",
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

	// Helper: Copy text to clipboard (cross-platform)
	copyToClipboard := func(text string) error {
		var cmd *exec.Cmd

		// Detect platform and use appropriate command
		if _, err := exec.LookPath("pbcopy"); err == nil {
			// macOS
			cmd = exec.Command("pbcopy")
		} else if _, err := exec.LookPath("xclip"); err == nil {
			// Linux with xclip
			cmd = exec.Command("xclip", "-selection", "clipboard")
		} else if _, err := exec.LookPath("xsel"); err == nil {
			// Linux with xsel
			cmd = exec.Command("xsel", "--clipboard", "--input")
		} else {
			return fmt.Errorf("no clipboard tool found (pbcopy/xclip/xsel)")
		}

		cmd.Stdin = strings.NewReader(text)
		return cmd.Run()
	}

	// Helper: Get relative path from PWD to target
	getRelativePath := func(targetPath string) string {
		pwd, err := os.Getwd()
		if err != nil {
			return targetPath // fallback to absolute
		}
		relPath, err := filepath.Rel(pwd, targetPath)
		if err != nil {
			return targetPath // fallback to absolute
		}
		return relPath
	}

	// Helper: Open shell in target directory (path must be provided)
	openShellInDir := func(path string, targetType string) error {
		meta, _ := loadMetadata()
		if len(meta.Patches) == 0 {
			fmt.Println("No patches configured.")
			return nil
		}

		// Find patch for provided path
		patch := findPatchForPath(meta, path)
		if patch == nil {
			for i := range meta.Patches {
				if meta.Patches[i].LocalPath == path {
					patch = &meta.Patches[i]
					break
				}
			}
		}
		if patch == nil {
			return fmt.Errorf("patch not found for path: %s", path)
		}

		// Determine target directory
		var targetDir string
		if targetType == "worktree" {
			targetDir = patch.Worktree
		} else {
			targetDir = patch.LocalPath
		}

		if _, err := os.Stat(targetDir); os.IsNotExist(err) {
			return fmt.Errorf("%s not found: %s", targetType, targetDir)
		}

		// Open subshell
		shell := os.Getenv("SHELL")
		if shell == "" {
			shell = "/bin/sh"
		}

		if dry != "" {
			fmt.Printf("%s cd %s\n", dry, targetDir)
			fmt.Printf("%s exec %s\n", dry, shell)
			return nil
		}

		logInfo(fmt.Sprintf("Opening shell in %s", targetDir))
		c := exec.Command(shell)
		c.Dir = targetDir
		c.Stdin = os.Stdin
		c.Stdout = os.Stdout
		c.Stderr = os.Stderr
		return c.Run()
	}

	// Shared logic for cd/wt commands — only the target field differs
	makeDirCmd := func(use, short, long, target string) *cobra.Command {
		return &cobra.Command{
			Use: use, Short: short, Long: long,
			RunE: func(cmd *cobra.Command, args []string) error {
				meta, _ := loadMetadata()
				if len(meta.Patches) == 0 {
					fmt.Println("No patches configured.")
					return nil
				}
				if len(args) > 0 {
					return openShellInDir(strings.TrimSpace(args[0]), target)
				}
				selected, err := selectPatchInteractive(&meta)
				if err != nil {
					logInfo("fzf not available. Showing patch list; rerun with a path.")
					table := tablewriter.NewWriter(os.Stdout)
					table.Header("REMOTE", "REMOTE PATH", "LOCAL PATH")
					for _, p := range meta.Patches {
						table.Append(p.Remote, p.RemotePath, p.LocalPath)
					}
					table.Render()
					return nil
				}
				if selected == nil {
					logInfo("No selection made.")
					return nil
				}
				targetPath := selected.LocalPath
				if target == "worktree" {
					targetPath = selected.Worktree
				}
				relPath := getRelativePath(targetPath)
				if err := copyToClipboard(relPath); err != nil {
					return fmt.Errorf("failed to copy to clipboard: %v", err)
				}
				logSuccess(fmt.Sprintf("Path copied to clipboard: %s", relPath))
				return nil
			},
		}
	}

	cdCmd := makeDirCmd("cd [path]",
		"Open a shell in the patch local_path (for editing files)",
		"Open a shell in the patch local_path (for editing files).\n\nWith path: opens subshell in the specified local_path directory.\nWithout path: uses fzf to select a patch, then copies the path to clipboard.",
		"local_path")

	wtCmd := makeDirCmd("wt [path]",
		"Open a shell in the patch worktree (for working with git history)",
		"Open a shell in the patch worktree (for working with git history).\n\nWith path: opens subshell in the specified worktree directory.\nWithout path: uses fzf to select a patch, then copies the path to clipboard.",
		"worktree")

	listCmd := &cobra.Command{
		Use:   "list",
		Short: "Show all configured patches and remotes",
		RunE: func(cmd *cobra.Command, args []string) error {
			meta, _ := loadMetadata()

			// Collect unique remote names from patches
			usedRemotes := make(map[string]bool)
			for _, p := range meta.Patches {
				usedRemotes[p.Remote] = true
			}

			repo, err := git.Open(".")
			if err == nil && len(usedRemotes) > 0 {
				remotes, _ := git.NewCommand("remote", "-v").RunInDir(repo.Path())
				if len(remotes) > 0 {
					logInfo("Configured Remotes:")
					remotesStr := strings.TrimSpace(string(remotes))
					lines := strings.Split(remotesStr, "\n")

					// Map to track fetch/push URLs per remote for deduplication
					type remoteInfo struct {
						fetch string
						push  string
					}
					remoteMap := make(map[string]*remoteInfo)

					for _, line := range lines {
						fields := strings.Fields(line)
						if len(fields) >= 3 {
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

					table := tablewriter.NewWriter(os.Stdout)
					table.Header("NAME", "URL")
					for name, info := range remoteMap {
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
			}

			if len(meta.Patches) == 0 {
				fmt.Println("No patches configured.")
				return nil
			}
			logInfo("Configured Patches:")
			table := tablewriter.NewWriter(os.Stdout)
			table.Header("REMOTE", "REMOTE PATH", "LOCAL PATH", "WORKTREE")
			for _, p := range meta.Patches {
				table.Append(p.Remote, p.RemotePath, p.LocalPath, p.Worktree)
			}
			table.Render()
			return nil
		},
	}

	statusCmd := &cobra.Command{
		Use:   "status",
		Short: "Show patch status",
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
					hasOverrides, err := hasCrossOverrides(filepath.Join(root, p.LocalPath))
					if err != nil {
						return fmt.Errorf("failed to read .crossignore for %s: %w", p.LocalPath, err)
					}
					if hasOverrides {
						diff = "Override"
					} else {
						// Quick diff check - use absolute paths
						upstreamPath := filepath.Join(worktreePath, p.RemotePath)
						localPath := filepath.Join(root, p.LocalPath)
						c := exec.Command("git", "diff", "--no-index", "--quiet", upstreamPath, localPath)
						if err := c.Run(); err != nil {
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
					localAbsPath := filepath.Join(root, p.LocalPath)
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
		Use:   "diff [path]",
		Short: "Show changes between local and upstream",
		Long: `Show diff between local vendored files and their upstream worktree source.

When run without a path argument, auto-detects the current patch from the
working directory: if CWD is inside a patched local_path, shows only that
patch's diff. Otherwise shows diffs for all patches.`,
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
				// No explicit path: detect from CWD
				cwd, err := os.Getwd()
				if err == nil {
					root, _ := getRepoRoot()
					meta, _ := loadMetadata()
					for _, p := range meta.Patches {
						absLocal := filepath.Join(root, p.LocalPath)
						if strings.HasPrefix(cwd+string(os.PathSeparator), absLocal+string(os.PathSeparator)) ||
							cwd == absLocal {
							path = p.LocalPath
							logInfo(fmt.Sprintf("Auto-detected patch from CWD: %s", path))
							break
						}
					}
				}
			}

			// Get repo root for resolving relative paths in metadata
			root, err := getRepoRoot()
			if err != nil {
				return fmt.Errorf("failed to get repo root: %w", err)
			}

			meta, _ := loadMetadata()
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
					c := exec.Command("git", "diff", "--no-index", upstreamPath, localPath)
					c.Stdout = os.Stdout
					c.Stderr = os.Stderr
					// git diff --no-index returns 1 if there are differences, which cobra might treat as error
					_ = c.Run()
				}
			}
			if !found && path != "" {
				return fmt.Errorf("patch not found for path: %s", path)
			}
			return nil
		},
	}

	replayCmd := &cobra.Command{
		Use:   "replay",
		Short: "Re-execute all Crossfile commands",
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
		Use:   "push [path]",
		Short: "Push changes back upstream",
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
		Use:   "exec [cmd]",
		Short: "Run arbitrary command",
		Args:  cobra.MinimumNArgs(1),
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
		Use:   "init",
		Short: "Initialize a new project with Crossfile",
		RunE: func(cmd *cobra.Command, args []string) error {
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
			return nil
		},
	}

	removeCmd := &cobra.Command{
		Use:   "remove [path]",
		Short: "Remove a patch and its worktree",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			meta, _ := loadMetadata()
			if err := removeSinglePatch(&meta, args[0]); err != nil {
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
		Use:   "prune [remote]",
		Short: "Prune unused remotes and worktrees, or remove all patches for a specific remote",
		Args:  cobra.MaximumNArgs(1),
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

	rootCmd.AddCommand(useCmd, patchCmd, syncCmd, removeCmd, pruneCmd, cdCmd, wtCmd, listCmd, statusCmd, diffCmd, replayCmd, pushCmd, execCmd, initCmd)
	if err := rootCmd.Execute(); err != nil {
		os.Exit(1)
	}
}
