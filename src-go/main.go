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
	"github.com/mattn/go-shellwords"
	"github.com/olekukonko/tablewriter"
	"github.com/spf13/cobra"
	"github.com/zloylos/grsync"
)

const (
	MetadataPath  = ".git/cross/metadata.json"
	CrossfilePath = "Crossfile"
)

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
	data, err := os.ReadFile(MetadataPath)
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
	dir := filepath.Dir(MetadataPath)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(meta, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(MetadataPath, data, 0644)
}

func updateCrossfile(line string) error {
	line = strings.TrimSpace(line)
	data, err := os.ReadFile(CrossfilePath)
	if err != nil && !os.IsNotExist(err) {
		return err
	}

	content := string(data)
	if strings.Contains(content, line) {
		return nil
	}

	f, err := os.OpenFile(CrossfilePath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return err
	}
	defer f.Close()

	if len(data) > 0 && data[len(data)-1] != '\n' {
		f.WriteString("\n")
	}
	_, err = f.WriteString("cross " + line + "\n")
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
	refs, err := git.LsRemote(url)
	if err != nil {
		return "", err
	}

	for _, ref := range refs {
		if strings.HasPrefix(ref.Refspec, "ref: refs/heads/") {
			return strings.TrimPrefix(ref.Refspec, "ref: refs/heads/"), nil
		}
	}
	return "main", nil
}

func main() {
	var rootCmd = &cobra.Command{Use: "git-cross"}

	var useCmd = &cobra.Command{
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

			remotes, _ := repo.Remotes()
			found := false
			for _, r := range remotes {
				if r == name {
					found = true
					break
				}
			}

			if found {
				// Use Command for set-url since porcelain might be missing
				_, err = git.NewCommand("remote", "set-url", name, url).RunInDir(".")
			} else {
				err = repo.RemoteAdd(name, url)
			}
			if err != nil {
				return err
			}

			logInfo("Autodetecting default branch...")
			branch, err := detectDefaultBranch(url)
			if err != nil {
				logError(fmt.Sprintf("Failed to detect branch: %v. Fallback to main.", err))
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

	var patchCmd = &cobra.Command{
		Use:   "patch [spec] [local_path]",
		Short: "Vendor a directory from a remote",
		Args:  cobra.MinimumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			spec := args[0]
			localPath := ""
			if len(args) > 1 {
				localPath = args[1]
			}

			parts := strings.Split(spec, ":")
			if len(parts) < 2 {
				return fmt.Errorf("invalid spec. Use remote:path[:branch]")
			}
			remoteName, remotePath := parts[0], parts[1]
			branch := "main"
			if len(parts) > 2 {
				branch = parts[2]
			}
			if localPath == "" {
				localPath = filepath.Base(remotePath)
			}

			logInfo(fmt.Sprintf("Patching %s to %s", spec, localPath))

			h := sha256.New()
			h.Write([]byte(spec + branch))
			hash := hex.EncodeToString(h.Sum(nil))[:8]

			wtDir := fmt.Sprintf(".git/cross/worktrees/%s_%s", remoteName, hash)
			if _, err := os.Stat(wtDir); os.IsNotExist(err) {
				logInfo(fmt.Sprintf("Setting up worktree at %s...", wtDir))
				os.MkdirAll(wtDir, 0755)
				
				// System call for worktree since it's a newer git feature often not fully in libraries
				c := exec.Command("git", "worktree", "add", "--no-checkout", wtDir, fmt.Sprintf("%s/%s", remoteName, branch))
				if out, err := c.CombinedOutput(); err != nil {
					return fmt.Errorf("git worktree add failed: %v\nOutput: %s", err, string(out))
				}
				
				git.NewCommand("sparse-checkout", "init", "--cone").RunInDir(wtDir)
				git.NewCommand("sparse-checkout", "set", remotePath).RunInDir(wtDir)
				git.NewCommand("checkout").RunInDir(wtDir)
			}

			logInfo(fmt.Sprintf("Syncing files to %s...", localPath))
			os.MkdirAll(localPath, 0755)
			if err := runSync(wtDir+"/"+remotePath+"/", localPath+"/"); err != nil {
				return err
			}

			meta, _ := loadMetadata()
			found := false
			for i, p := range meta.Patches {
				if p.LocalPath == localPath {
					meta.Patches[i] = Patch{remoteName, remotePath, localPath, wtDir, branch}
					found = true
					break
				}
			}
			if !found {
				meta.Patches = append(meta.Patches, Patch{remoteName, remotePath, localPath, wtDir, branch})
			}
			saveMetadata(meta)

			updateCrossfile(fmt.Sprintf("patch %s %s", spec, localPath))
			logSuccess("Patch successful.")
			return nil
		},
	}

	var syncCmd = &cobra.Command{
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

	var listCmd = &cobra.Command{
		Use:   "list",
		Short: "Show all configured patches",
		RunE: func(cmd *cobra.Command, args []string) error {
			meta, _ := loadMetadata()
			if len(meta.Patches) == 0 {
				fmt.Println("No patches configured.")
				return nil
			}
			table := tablewriter.NewWriter(os.Stdout)
			table.Header("REMOTE", "REMOTE PATH", "LOCAL PATH", "WORKTREE")
			for _, p := range meta.Patches {
				table.Append(p.Remote, p.RemotePath, p.LocalPath, p.Worktree)
			}
			return table.Render()
		},
	}

	var statusCmd = &cobra.Command{
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

	var replayCmd = &cobra.Command{
		Use:   "replay",
		Short: "Re-execute all Crossfile commands",
		RunE: func(cmd *cobra.Command, args []string) error {
			logInfo("Replaying Crossfile...")
			data, err := os.ReadFile(CrossfilePath)
			if err != nil {
				return err
			}
			exe, _ := os.Executable()
			for _, line := range strings.Split(string(data), "\n") {
				line = strings.TrimSpace(line)
				if line == "" || strings.HasPrefix(line, "#") {
					continue
				}
				logInfo("Executing: " + line)
				words, _ := shellwords.Parse(line)
				if len(words) == 0 {
					continue
				}
				startIdx := -1
				if words[0] == "just" && len(words) > 1 && words[1] == "cross" {
					startIdx = 2
				} else if words[0] == "cross" {
					startIdx = 1
				}
				if startIdx >= 0 {
					c := exec.Command(exe, words[startIdx:]...)
					c.Stdout = os.Stdout
					c.Stderr = os.Stderr
					c.Run()
				} else {
					c := exec.Command("bash", "-c", line)
					c.Stdout = os.Stdout
					c.Stderr = os.Stderr
					c.Run()
				}
			}
			logSuccess("Replay completed.")
			return nil
		},
	}

	var pushCmd = &cobra.Command{
		Use:   "push [path]",
		Short: "Push changes back upstream (WIP)",
		RunE: func(cmd *cobra.Command, args []string) error {
			logInfo("The 'push' command is currently WORK IN PROGRESS.")
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

			msg := "Update from git-cross"
			// Try to get message from parent repo log
			logOut, _ := git.NewCommand("log", "-1", "--pretty=%s", "--", patch.LocalPath).RunInDir(".")
			if len(logOut) > 0 {
				msg = strings.TrimSpace(string(logOut))
			}

			logInfo("Committing and pushing...")
			if _, err := git.NewCommand("add", ".").RunInDir(patch.Worktree); err != nil {
				return err
			}
			if _, err := git.NewCommand("commit", "-m", msg).RunInDir(patch.Worktree); err != nil {
				// might be nothing to commit, ignore
			}
			
			if _, err := git.NewCommand("push", patch.Remote, "HEAD:"+patch.Branch).RunInDir(patch.Worktree); err != nil {
				return err
			}
			logSuccess("Push completed.")
			return nil
		},
	}

	var execCmd = &cobra.Command{
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

	rootCmd.AddCommand(useCmd, patchCmd, syncCmd, listCmd, statusCmd, replayCmd, pushCmd, execCmd)
	if err := rootCmd.Execute(); err != nil {
		os.Exit(1)
	}
}
