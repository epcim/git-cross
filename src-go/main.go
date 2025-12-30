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
	MetadataRelPath  = ".git/cross/metadata.json"
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
	if remotePath == "" {
		return patchSpec{}, fmt.Errorf("invalid remote path in spec: %s", spec)
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
		"--height",
		"40%",
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
	rootCmd := &cobra.Command{Use: "git-cross"}
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
			h.Write([]byte(spec.Remote + spec.RemotePath + spec.Branch))
			hash := hex.EncodeToString(h.Sum(nil))[:8]

			wtDir := fmt.Sprintf(".git/cross/worktrees/%s_%s", spec.Remote, hash)
			if _, err := os.Stat(wtDir); os.IsNotExist(err) {
				logInfo(fmt.Sprintf("Setting up worktree at %s...", wtDir))
				if err := os.MkdirAll(wtDir, 0o755); err != nil {
					return err
				}

				c := exec.Command("git", "worktree", "add", "--no-checkout", wtDir, fmt.Sprintf("%s/%s", spec.Remote, spec.Branch))
				if out, err := c.CombinedOutput(); err != nil {
					return fmt.Errorf("git worktree add failed: %v\nOutput: %s", err, string(out))
				}

				git.NewCommand("sparse-checkout", "init", "--no-cone").RunInDir(wtDir)
				git.NewCommand("sparse-checkout", "set", spec.RemotePath).RunInDir(wtDir)
				git.NewCommand("checkout").RunInDir(wtDir)
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
			for _, p := range meta.Patches {
				if path != "" && p.LocalPath != path {
					continue
				}
				logInfo(fmt.Sprintf("Syncing %s...", p.LocalPath))

				wtRepo, err := git.Open(p.Worktree)
				if err != nil {
					logError(fmt.Sprintf("Failed to open worktree %s: %v", p.Worktree, err))
					continue
				}

				if err := wtRepo.Pull(git.PullOptions{
					Remote: p.Remote,
					Branch: p.Branch,
					Rebase: true,
				}); err != nil {
					logError(fmt.Sprintf("Failed to pull for %s: %v", p.LocalPath, err))
					continue
				}

				if err := runSync(p.Worktree+"/"+p.RemotePath+"/", p.LocalPath+"/"); err != nil {
					logError(fmt.Sprintf("Failed to sync files for %s: %v", p.LocalPath, err))
				}
			}
			logSuccess("Sync completed.")
			return nil
		},
	}

	cdCmd := &cobra.Command{
		Use:   "cd [path]",
		Short: "Open a shell in the patch worktree",
		RunE: func(cmd *cobra.Command, args []string) error {
			meta, _ := loadMetadata()
			if len(meta.Patches) == 0 {
				fmt.Println("No patches configured.")
				return nil
			}

			var patch *Patch
			if len(args) > 0 {
				path := strings.TrimSpace(args[0])
				patch = findPatchForPath(meta, path)
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
			} else {
				selected, err := selectPatchInteractive(&meta)
				if err != nil {
					logInfo("fzf not available. Showing patch list; rerun with a path to enter a worktree.")
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
				patch = selected
			}

			if patch == nil {
				return nil
			}

			if _, err := os.Stat(patch.Worktree); os.IsNotExist(err) {
				return fmt.Errorf("worktree not found for %s", patch.LocalPath)
			}

			shell := os.Getenv("SHELL")
			if shell == "" {
				shell = "/bin/sh"
			}

			if dry != "" {
				fmt.Printf("%s cd %s\n", dry, patch.Worktree)
				fmt.Printf("%s exec %s\n", dry, shell)
				return nil
			}

			logInfo(fmt.Sprintf("Opening shell in %s", patch.Worktree))
			c := exec.Command(shell)
			c.Dir = patch.Worktree
			c.Stdin = os.Stdin
			c.Stdout = os.Stdout
			c.Stderr = os.Stderr
			return c.Run()
		},
	}

	listCmd := &cobra.Command{
		Use:   "list",
		Short: "Show all configured patches and remotes",
		RunE: func(cmd *cobra.Command, args []string) error {
			repo, err := git.Open(".")
			if err == nil {
				remotes, _ := git.NewCommand("remote", "-v").RunInDir(repo.Path())
				if len(remotes) > 0 {
					logInfo("Configured Remotes:")
					remotesStr := strings.TrimSpace(string(remotes))
					lines := strings.Split(remotesStr, "\n")
					table := tablewriter.NewWriter(os.Stdout)
					table.Header("NAME", "URL", "TYPE")
					for _, line := range lines {
						fields := strings.Fields(line)
						if len(fields) >= 3 {
							table.Append(fields[0], fields[1], fields[2])
						}
					}
					table.Render()
					fmt.Println()
				}
			}

			meta, _ := loadMetadata()
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
			table := tablewriter.NewWriter(os.Stdout)
			table.Header("LOCAL PATH", "DIFF", "UPSTREAM", "CONFLICTS")
			for _, p := range meta.Patches {
				diff := "Clean"
				upstream := "Synced"
				conflicts := "No"

				if _, err := os.Stat(p.Worktree); os.IsNotExist(err) {
					diff = "Missing WT"
				} else {
					// Quick diff check
					c := exec.Command("git", "diff", "--no-index", "--quiet", p.Worktree+"/"+p.RemotePath, p.LocalPath)
					if err := c.Run(); err != nil {
						diff = "Modified"
					}

					behindOut, _ := git.NewCommand("rev-list", "--count", "HEAD..@{upstream}").RunInDir(p.Worktree)
					aheadOut, _ := git.NewCommand("rev-list", "--count", "@{upstream}..HEAD").RunInDir(p.Worktree)

					behind := strings.TrimSpace(string(behindOut))
					ahead := strings.TrimSpace(string(aheadOut))

					if behind != "" && behind != "0" {
						upstream = behind + " behind"
					} else if ahead != "" && ahead != "0" {
						upstream = ahead + " ahead"
					}

					if out, _ := git.NewCommand("ls-files", "-u").RunInDir(p.Worktree); len(out) > 0 {
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
		RunE: func(cmd *cobra.Command, args []string) error {
			path := ""
			if len(args) > 0 {
				path = args[0]
			}
			meta, _ := loadMetadata()
			found := false
			for _, p := range meta.Patches {
				if path != "" && p.LocalPath != path {
					continue
				}
				found = true
				if _, err := os.Stat(p.Worktree); os.IsNotExist(err) {
					logError(fmt.Sprintf("Worktree not found for %s", p.LocalPath))
					continue
				}
				// Use git diff --no-index to compare directories
				c := exec.Command("git", "diff", "--no-index", filepath.Join(p.Worktree, p.RemotePath), p.LocalPath)
				c.Stdout = os.Stdout
				c.Stderr = os.Stderr
				// git diff --no-index returns 1 if there are differences, which cobra might treat as error
				_ = c.Run()
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

	wtCmd := &cobra.Command{
		Use:   "wt [path]",
		Short: "Alias for cd",
		RunE:  cdCmd.RunE,
	}

	removeCmd := &cobra.Command{
		Use:   "remove [path]",
		Short: "Remove a patch and its worktree",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			localPath := filepath.Clean(args[0])
			meta, _ := loadMetadata()
			var patch *Patch
			patchIdx := -1
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
			path, err := getCrossfilePath()
			if err == nil {
				data, err := os.ReadFile(path)
				if err == nil {
					lines := strings.Split(string(data), "\n")
					var newLines []string
					for _, line := range lines {
						if !strings.Contains(line, "patch") || !strings.Contains(line, localPath) {
							newLines = append(newLines, line)
						}
					}
					os.WriteFile(path, []byte(strings.Join(newLines, "\n")), 0o644)
				}
			}

			// 3. Remove from metadata
			logInfo("Updating metadata...")
			meta.Patches = append(meta.Patches[:patchIdx], meta.Patches[patchIdx+1:]...)
			if err := saveMetadata(meta); err != nil {
				return err
			}

			// 4. Remove local directory
			logInfo(fmt.Sprintf("Deleting local directory %s...", localPath))
			if err := os.RemoveAll(localPath); err != nil {
				logError(fmt.Sprintf("Failed to remove local directory: %v", err))
			}

			logSuccess("Patch removed successfully.")
			return nil
		},
	}

	rootCmd.AddCommand(useCmd, patchCmd, syncCmd, removeCmd, cdCmd, wtCmd, listCmd, statusCmd, diffCmd, replayCmd, pushCmd, execCmd, initCmd)
	if err := rootCmd.Execute(); err != nil {
		os.Exit(1)
	}
}
