use anyhow::{Context, Result, anyhow};
use clap::{Parser, Subcommand};
use serde::{Deserialize, Serialize};
use std::env;
use std::fs;
use std::io::{ErrorKind, Write};
use std::path::Path;
use std::process::{Command, Stdio};
use tabled::{Table, Tabled};

#[derive(Parser)]
#[command(name = "git-cross-rust")]
#[command(version = "0.2.1")]
#[command(
    about = "A tool for vendoring git directories using worktrees [EXPERIMENTAL/WIP]",
    long_about = "Note: The Rust implementation of git-cross is currently EXPERIMENTAL and WORK IN PROGRESS. The Go implementation is the primary focus and recommended for production use."
)]
struct Cli {
    #[arg(long, global = true, default_value = "")]
    dry: String,
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Add a remote repository
    Use { name: String, url: String },
    /// Vendor a directory from a remote
    Patch {
        /// remote[:branch]:path
        spec: String,
        /// Optional local path (defaults to remote path)
        local_path: Option<String>,
    },

    /// Update all patches from upstream
    Sync {
        #[arg(default_value = "")]
        path: String,
    },
    /// Open a shell in the patch worktree
    Cd {
        #[arg(default_value = "")]
        path: String,
    },
    /// Alias for cd
    Wt {
        #[arg(default_value = "")]
        path: String,
    },
    /// Show all configured patches
    List,
    /// Show patch status
    Status,
    /// Show changes between local and upstream
    Diff {
        #[arg(default_value = "")]
        path: String,
    },
    /// Re-execute all Crossfile commands
    Replay,
    /// Initialize a new project with Crossfile
    Init,
    /// Remove a patch and its worktree
    Remove {
        /// Local path of the patch to remove
        path: String,
    },
    /// Prune unused remotes and worktrees, or remove all patches for a specific remote
    Prune {
        /// Optional remote name to prune all its patches
        remote: Option<String>,
    },
    /// Push changes back to upstream
    Push {
        #[arg(default_value = "")]
        path: String,
        #[arg(long)]
        branch: Option<String>,
        #[arg(long, default_value_t = false)]
        force: bool,
        #[arg(long, default_value_t = false)]
        yes: bool,
        #[arg(long)]
        message: Option<String>,
    },
    /// Run arbitrary command
    Exec {
        #[arg(trailing_var_arg = true)]
        args: Vec<String>,
    },
}

#[derive(Serialize, Deserialize, Debug, Tabled, Clone)]
struct Patch {
    #[serde(default)]
    pub id: String,
    pub remote: String,
    pub remote_path: String,
    pub local_path: String,
    pub worktree: String,
    #[tabled(skip)]
    pub branch: String,
}

#[derive(Serialize, Deserialize, Debug)]
struct Metadata {
    patches: Vec<Patch>,
}

struct PatchSpec {
    remote: String,
    remote_path: String,
    branch: Option<String>,
    branch_provided: bool,
}

const METADATA_REL_PATH: &str = ".git/cross/metadata.json";
const CROSSFILE_REL_PATH: &str = "Crossfile";

fn get_repo_root() -> Result<String> {
    run_cmd(&["git", "rev-parse", "--show-toplevel"])
}

fn get_metadata_path() -> Result<std::path::PathBuf> {
    let root = get_repo_root()?;
    Ok(Path::new(&root).join(METADATA_REL_PATH))
}

fn get_crossfile_path() -> Result<std::path::PathBuf> {
    let root = get_repo_root()?;
    Ok(Path::new(&root).join(CROSSFILE_REL_PATH))
}

fn parse_patch_spec(spec: &str) -> Result<PatchSpec> {
    let parts: Vec<&str> = spec.split(':').collect();
    if parts.len() < 2 {
        return Err(anyhow!("Invalid spec. Use remote[:branch]:remote_path"));
    }

    let remote = parts[0].to_string();
    let mut remote_path = parts.last().unwrap().to_string();
    let mut branch: Option<String> = None;
    let mut branch_provided = false;

    match parts.len() {
        2 => {}
        3 => {
            if !parts[1].is_empty() {
                branch = Some(parts[1].to_string());
                branch_provided = true;
            }
        }
        _ => {
            if !parts[1].is_empty() {
                branch = Some(parts[1].to_string());
                branch_provided = true;
            }
            remote_path = parts[2..].join(":");
        }
    }

    let remote_path = remote_path
        .trim_start_matches('/')
        .trim_end_matches('/')
        .to_string();
    if remote_path.is_empty() {
        return Err(anyhow!("Invalid remote path in spec: {}", spec));
    }

    Ok(PatchSpec {
        remote,
        remote_path,
        branch,
        branch_provided,
    })
}

fn canonical_spec(spec: &PatchSpec) -> String {
    if let Some(branch) = &spec.branch {
        format!("{}:{}:{}", spec.remote, branch, spec.remote_path)
    } else {
        format!("{}:{}", spec.remote, spec.remote_path)
    }
}

fn detect_default_branch_from_url(url: &str) -> Result<String> {
    let symref_result = duct::cmd!("git", "ls-remote", "--symref", url, "HEAD")
        .stderr_to_stdout()
        .stdout_capture()
        .unchecked()
        .run()?;

    if symref_result.status.success() {
        let stdout = String::from_utf8_lossy(&symref_result.stdout);
        for line in stdout.lines() {
            if let Some(rest) = line.strip_prefix("ref: ") {
                let mut parts = rest.split('\t');
                if let (Some(refspec), Some(target)) = (parts.next(), parts.next()) {
                    if target == "HEAD" && refspec.starts_with("refs/heads/") {
                        return Ok(refspec.trim_start_matches("refs/heads/").to_string());
                    }
                }
            }
        }
    }

    let heads_output = run_cmd(&["git", "ls-remote", "--heads", url])?;
    for candidate in ["main", "master"] {
        let needle = format!("\trefs/heads/{}", candidate);
        if heads_output.contains(&needle) {
            return Ok(candidate.to_string());
        }
    }

    for line in heads_output.lines() {
        if let Some((_hash, refname)) = line.split_once('\t') {
            if let Some(stripped) = refname.strip_prefix("refs/heads/") {
                if !stripped.is_empty() {
                    return Ok(stripped.to_string());
                }
            }
        }
    }

    Ok("main".to_string())
}

fn detect_remote_branch(repo: &git2::Repository, remote: &str) -> Result<String> {
    if let Ok(mut remote_handle) = repo.find_remote(remote) {
        if let Some(url) = remote_handle.url() {
            if let Ok(branch) = detect_default_branch_from_url(url) {
                return Ok(branch);
            }
        }

        if remote_handle.connect(git2::Direction::Fetch).is_ok() {
            let mut candidate: Option<String> = None;

            if let Ok(buf) = remote_handle.default_branch() {
                if let Some(name) = buf.as_str() {
                    let trimmed = name.trim_start_matches("refs/heads/").to_string();
                    if !trimmed.is_empty() {
                        candidate = Some(trimmed);
                    }
                }
            }

            if candidate.is_none() {
                if let Ok(list) = remote_handle.list() {
                    if candidate.is_none() {
                        if let Some(target) = list
                            .iter()
                            .find(|r| r.name() == "HEAD")
                            .and_then(|r| r.symref_target())
                        {
                            let trimmed = target.trim_start_matches("refs/heads/").to_string();
                            if !trimmed.is_empty() {
                                candidate = Some(trimmed);
                            }
                        }
                    }

                    if candidate.is_none() {
                        for head in list {
                            if let Some(stripped) = head.name().strip_prefix("refs/heads/") {
                                if !stripped.is_empty() {
                                    candidate = Some(stripped.to_string());
                                    break;
                                }
                            }
                        }
                    }
                }
            }

            let _ = remote_handle.disconnect();
            if let Some(branch) = candidate {
                return Ok(branch);
            }
        }
    }

    for candidate in ["main", "master"] {
        if let Ok(output) = run_cmd(&["git", "ls-remote", remote, candidate]) {
            if !output.trim().is_empty() {
                return Ok(candidate.to_string());
            }
        }
    }

    Ok("main".to_string())
}

fn log_info(msg: &str) {
    println!("\x1b[1;34m==>\x1b[0m {}", msg);
}

fn log_success(msg: &str) {
    println!("\x1b[1;32m==>\x1b[0m {}", msg);
}

fn log_error(msg: &str) {
    eprintln!("\x1b[1;31m==> ERROR:\x1b[0m {}", msg);
}

fn run_cmd(args: &[&str]) -> Result<String> {
    use duct::cmd;
    let output = cmd(args[0], &args[1..])
        .stderr_to_stdout()
        .stdout_capture()
        .unchecked()
        .run()
        .context(format!("Failed to execute command: {:?}", args))?;

    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if !output.status.success() {
        return Err(anyhow!("Command failed: {:?}\nOutput: {}", args, stdout));
    }

    Ok(stdout)
}

fn normalize_local_path(path: &str) -> String {
    let mut normalized = path.replace('\\', "/");
    normalized = normalized.trim().to_string();
    while let Some(stripped) = normalized.strip_prefix("./") {
        normalized = stripped.to_string();
    }
    normalized.trim_matches('/').to_string()
}

fn find_patch_for_path(metadata: &Metadata, rel: &str) -> Option<Patch> {
    let rel = normalize_local_path(rel);
    if rel.is_empty() {
        return None;
    }

    let mut selected: Option<Patch> = None;
    let mut longest = 0usize;
    for patch in &metadata.patches {
        let lp = normalize_local_path(&patch.local_path);
        if lp.is_empty() {
            continue;
        }
        if rel == lp || rel.starts_with(&(lp.clone() + "/")) {
            if lp.len() > longest {
                longest = lp.len();
                selected = Some(patch.clone());
            }
        }
    }

    selected
}

fn select_patch_interactive(metadata: &Metadata) -> Result<Option<Patch>> {
    if metadata.patches.is_empty() {
        return Ok(None);
    }

    let mut input = String::new();
    for patch in &metadata.patches {
        input.push_str(&format!(
            "{}\t{}\t{}\n",
            patch.remote, patch.remote_path, patch.local_path
        ));
    }

    let mut child = Command::new("fzf")
        .args([
            "--with-nth=1,2,3",
            "--delimiter",
            "\t",
            "--prompt",
            "Select patch> ",
            "--height",
            "40%",
            "--select-1",
            "--exit-0",
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .map_err(|err| {
            if err.kind() == ErrorKind::NotFound {
                anyhow!("fzf not found")
            } else {
                anyhow!(err)
            }
        })?;

    {
        let stdin = child.stdin.as_mut().context("Failed to open fzf stdin")?;
        stdin.write_all(input.as_bytes())?;
    }

    let output = child.wait_with_output()?;
    if !output.status.success() {
        return Ok(None);
    }

    let selection = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if selection.is_empty() {
        return Ok(None);
    }

    let local_path = selection
        .rsplit_once('\t')
        .map(|(_, s)| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .or_else(|| selection.split_whitespace().last().map(|s| s.to_string()))
        .ok_or_else(|| anyhow!("Unable to parse selection: {}", selection))?;

    metadata
        .patches
        .iter()
        .find(|p| p.local_path == local_path)
        .cloned()
        .ok_or_else(|| anyhow!("Selected patch not found: {}", local_path))
        .map(Some)
}

fn copy_to_clipboard(text: &str) -> Result<()> {
    // Detect platform and use appropriate command
    if which::which("pbcopy").is_ok() {
        // macOS
        duct::cmd!("pbcopy").stdin_bytes(text).run()?;
    } else if which::which("xclip").is_ok() {
        // Linux with xclip
        duct::cmd!("xclip", "-selection", "clipboard").stdin_bytes(text).run()?;
    } else if which::which("xsel").is_ok() {
        // Linux with xsel
        duct::cmd!("xsel", "--clipboard", "--input").stdin_bytes(text).run()?;
    } else {
        return Err(anyhow!("No clipboard tool found (pbcopy/xclip/xsel)"));
    }
    Ok(())
}

fn get_relative_path(target_path: &str) -> String {
    use std::path::PathBuf;
    
    // Get current working directory
    let Ok(pwd) = env::current_dir() else {
        return target_path.to_string();
    };
    
    // Convert target to absolute path (don't use canonicalize - it requires file to exist)
    let target = PathBuf::from(target_path);
    
    // Manual computation: try strip_prefix first (if target is subpath of pwd)
    if let Ok(rel) = target.strip_prefix(&pwd) {
        return rel.to_string_lossy().to_string();
    }
    
    // Otherwise compute relative path by finding common prefix
    let pwd_components: Vec<_> = pwd.components().collect();
    let target_components: Vec<_> = target.components().collect();
    
    // Find common prefix
    let common = pwd_components.iter()
        .zip(target_components.iter())
        .take_while(|(a, b)| a == b)
        .count();
    
    // Build relative path: ../ for each level up, then remaining target components
    let ups = pwd_components.len() - common;
    let mut rel_path = PathBuf::new();
    for _ in 0..ups {
        rel_path.push("..");
    }
    for comp in &target_components[common..] {
        rel_path.push(comp);
    }
    
    rel_path.to_string_lossy().to_string()
}

fn open_shell_in_dir(path: &str, target_type: &str) -> Result<()> {
    let metadata = load_metadata()?;
    if metadata.patches.is_empty() {
        println!("No patches configured.");
        return Ok(());
    }

    // Find patch for provided path
    let path = path.trim();
    let target_patch = find_patch_for_path(&metadata, path)
        .or_else(|| metadata.patches.iter().find(|p| p.local_path == path).cloned())
        .ok_or_else(|| anyhow!("Patch not found for path: {}", path))?;

    // Determine target directory
    let target_dir = if target_type == "worktree" {
        &target_patch.worktree
    } else {
        &target_patch.local_path
    };

    // Check directory exists
    if !std::path::Path::new(target_dir).exists() {
        return Err(anyhow!("{} not found: {}", target_type, target_dir));
    }

    // Open subshell
    let shell = env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string());
    log_info(&format!("Opening shell in {}", target_dir));

    let status = Command::new(&shell)
        .current_dir(target_dir)
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status()?;

    if !status.success() {
        return Err(anyhow!("Shell exited with error"));
    }

    Ok(())
}

fn repo_relative_path() -> Result<Option<String>> {
    let prefix = run_cmd(&["git", "rev-parse", "--show-prefix"])?;
    if prefix.is_empty() {
        Ok(None)
    } else {
        Ok(Some(prefix.trim_end_matches('/').to_string()))
    }
}

fn load_metadata() -> Result<Metadata> {
    let path = get_metadata_path()?;
    if path.exists() {
        let content = fs::read_to_string(path)?;
        Ok(serde_json::from_str(&content)?)
    } else {
        Ok(Metadata {
            patches: Vec::new(),
        })
    }
}

fn save_metadata(metadata: &Metadata) -> Result<()> {
    let path = get_metadata_path()?;
    let dir = path.parent().unwrap();
    fs::create_dir_all(dir)?;
    let content = serde_json::to_string_pretty(metadata)?;
    fs::write(path, content)?;
    Ok(())
}

fn update_crossfile(line: &str) -> Result<()> {
    let path = get_crossfile_path()?;
    let mut content = if path.exists() {
        fs::read_to_string(&path)?
    } else {
        String::new()
    };

    let line = line.trim();
    let line_without_prefix = line.strip_prefix("cross ").unwrap_or(line).trim();

    let already_exists = content.lines().any(|l| {
        let trimmed_l = l.trim();
        trimmed_l == line || trimmed_l == format!("cross {}", line) || trimmed_l == line_without_prefix
    });

    if !already_exists {
        if !content.is_empty() && !content.ends_with('\n') {
            content.push('\n');
        }
        if !line.starts_with("cross ") {
            content.push_str("cross ");
        }
        content.push_str(line);
        content.push('\n');
        fs::write(path, content)?;
    }
    Ok(())
}

fn main() -> Result<()> {
    let cli = Cli::parse();

    match &cli.command {
        Commands::Use { name, url } => {
            log_info(&format!("Adding remote {} ({})", name, url));

            let repo = git2::Repository::open(".")?;

            if repo.find_remote(name).is_ok() {
                repo.remote_set_url(name, url)?;
            } else {
                repo.remote(name, url)?;
            }

            log_info("Autodetecting default branch...");
            let branch = detect_default_branch_from_url(url)
                .or_else(|_| detect_remote_branch(&repo, name))
                .unwrap_or_else(|_| "main".to_string());
            log_info(&format!("Detected default branch: {}", branch));

            run_cmd(&["git", "fetch", name, &branch])?;

            update_crossfile(&format!("cross use {} {}", name, url))?;
            log_success("Remote added and Crossfile updated.");
        }
        Commands::Patch { spec, local_path } => {
            let mut spec = parse_patch_spec(spec)?;

            let repo = git2::Repository::open(".")?;
            if repo.find_remote(&spec.remote).is_err() {
                return Err(anyhow!(
                    "Remote {} not found. Run 'use' first.",
                    spec.remote
                ));
            }

            if !spec.branch_provided {
                log_info("Autodetecting default branch...");
                let branch = detect_remote_branch(&repo, &spec.remote)?;
                log_info(&format!("Using branch: {}", branch));
                spec.branch = Some(branch);
            }
            let branch_name = spec.branch.clone().unwrap_or_else(|| "main".to_string());

            let canonical = canonical_spec(&spec);
            let target_path = local_path.clone().unwrap_or_else(|| {
                Path::new(&spec.remote_path)
                    .file_name()
                    .map(|s| s.to_string_lossy().to_string())
                    .unwrap_or_else(|| spec.remote_path.clone())
            });

            log_info(&format!("Patching {} to {}", canonical, target_path));

            run_cmd(&["git", "fetch", &spec.remote, &branch_name])?;

            use std::collections::hash_map::DefaultHasher;
            use std::hash::{Hash, Hasher};
            let mut hasher = DefaultHasher::new();
            canonical.hash(&mut hasher);
            branch_name.hash(&mut hasher);
            let hash = format!("{:016x}", hasher.finish());
            let hash = &hash[..8];

            let wt_dir = format!(".git/cross/worktrees/{}_{}", spec.remote, hash);

            if !Path::new(&wt_dir).exists() {
                log_info(&format!("Setting up worktree at {}...", wt_dir));
                fs::create_dir_all(&wt_dir)?;

                run_cmd(&[
                    "git",
                    "worktree",
                    "add",
                    "--no-checkout",
                    &wt_dir,
                    &format!("{}/{}", spec.remote, branch_name),
                ])?;
                run_cmd(&["git", "-C", &wt_dir, "sparse-checkout", "init", "--no-cone"])?;
                run_cmd(&[
                    "git",
                    "-C",
                    &wt_dir,
                    "sparse-checkout",
                    "set",
                    &spec.remote_path,
                ])?;
                run_cmd(&["git", "-C", &wt_dir, "checkout"])?;
            }

            log_info(&format!("Syncing files to {}...", target_path));
            fs::create_dir_all(&target_path)?;

            let src = format!("{}/{}/", wt_dir, spec.remote_path);
            let dst = format!("{}/", target_path);
            run_cmd(&["rsync", "-av", "--delete", "--exclude", ".git", &src, &dst])?;

            let mut metadata = load_metadata()?;
            if let Some(existing) = metadata
                .patches
                .iter_mut()
                .find(|p| p.local_path == target_path)
            {
                existing.id = hash.to_string();
                existing.remote = spec.remote.clone();
                existing.remote_path = spec.remote_path.clone();
                existing.branch = branch_name.clone();
                existing.worktree = wt_dir.clone();
            } else {
                metadata.patches.push(Patch {
                    id: hash.to_string(),
                    remote: spec.remote.clone(),
                    remote_path: spec.remote_path.clone(),
                    local_path: target_path.clone(),
                    worktree: wt_dir.clone(),
                    branch: branch_name.clone(),
                });
            }
            save_metadata(&metadata)?;

            update_crossfile(&format!(
                "cross patch {} {}",
                canonical_spec(&spec),
                target_path
            ))?;
            log_success("Patch successful.");
        }
        Commands::Sync { path } => {
            let metadata = load_metadata()?;
            let repo_root = run_cmd(&["git", "rev-parse", "--show-toplevel"])?;
            let repo_root = repo_root.trim();

            let patches_to_sync = if path.is_empty() {
                metadata.patches.clone()
            } else {
                metadata
                    .patches
                    .iter()
                    .filter(|p| p.local_path == *path)
                    .cloned()
                    .collect()
            };

            if patches_to_sync.is_empty() {
                log_info("No patches found to sync.");
                return Ok(());
            }

            for patch in patches_to_sync {
                log_info(&format!("Syncing {}...", patch.local_path));

                if !Path::new(&patch.worktree).exists() {
                    log_error(&format!(
                        "Worktree not found for {}. Run patch again.",
                        patch.local_path
                    ));
                    continue;
                }

                let local_abs_path = format!("{}/{}", repo_root, patch.local_path);

                // Step 1: Check for uncommitted changes and stash if needed
                let mut stashed = false;
                match run_cmd(&["git", "-C", &local_abs_path, "status", "--porcelain"]) {
                    Ok(status) if !status.trim().is_empty() => {
                        log_info("Stashing uncommitted changes...");
                        if let Err(e) = run_cmd(&[
                            "git",
                            "-C",
                            &local_abs_path,
                            "stash",
                            "push",
                            "-m",
                            "cross-sync-auto-stash",
                        ]) {
                            log_error(&format!("Failed to stash changes: {}", e));
                            continue;
                        }
                        stashed = true;
                    }
                    _ => {}
                }

                // Step 2: Rsync git-tracked files from local_path to worktree
                log_info("Syncing local changes to worktree...");
                let git_files = run_cmd(&["git", "-C", &local_abs_path, "ls-files", "-z"]);
                if let Ok(files) = git_files {
                    if !files.trim().is_empty() {
                        let wt_remote_path = format!("{}/{}", patch.worktree, patch.remote_path);
                        let rsync_result = duct::cmd!(
                            "rsync",
                            "-av0",
                            "--files-from=-",
                            "--relative",
                            "--exclude",
                            ".git",
                            &format!("{}/", local_abs_path),
                            &format!("{}/", wt_remote_path)
                        )
                        .stdin_bytes(files.as_bytes())
                        .run();

                        if let Err(e) = rsync_result {
                            log_error(&format!("Failed to rsync local to worktree: {}", e));
                            if stashed {
                                let _ = run_cmd(&["git", "-C", &local_abs_path, "stash", "pop"]);
                            }
                            continue;
                        }
                    }
                }

                // Step 3: Commit local changes in worktree
                match run_cmd(&["git", "-C", &patch.worktree, "status", "--porcelain"]) {
                    Ok(wt_status) if !wt_status.trim().is_empty() => {
                        log_info("Committing local changes in worktree...");
                        let _ = run_cmd(&["git", "-C", &patch.worktree, "add", "."]);
                        let _ = run_cmd(&[
                            "git",
                            "-C",
                            &patch.worktree,
                            "commit",
                            "-m",
                            "Sync local changes",
                        ]);
                    }
                    _ => {}
                }

                // Step 4: Pull rebase from upstream
                log_info("Pulling updates from upstream...");
                if let Err(e) = run_cmd(&[
                    "git",
                    "-C",
                    &patch.worktree,
                    "pull",
                    "--rebase",
                    &patch.remote,
                    &patch.branch,
                ]) {
                    log_error(&format!("Failed to pull: {}", e));
                    log_error("Please resolve conflicts manually in worktree:");
                    log_error(&format!("  cd {}", patch.worktree));
                    if stashed {
                        log_info("Note: Local changes are stashed. Run 'git stash pop' in local_path after resolving.");
                    }
                    continue;
                }

                // Step 5: Delete tracked files in local_path that were removed upstream
                log_info("Checking for files deleted upstream...");
                let wt_remote_path = format!("{}/{}", patch.worktree, patch.remote_path);
                
                // Get tracked files in worktree
                if let Ok(wt_files_str) = run_cmd(&["git", "-C", &wt_remote_path, "ls-files"]) {
                    let wt_files: std::collections::HashSet<String> = 
                        wt_files_str.lines().map(|s| s.to_string()).collect();
                    
                    // Get tracked files in local_path from main repo
                    if let Ok(local_files_str) = run_cmd(&["git", "ls-files", &patch.local_path]) {
                        for local_file in local_files_str.lines() {
                            if local_file.is_empty() {
                                continue;
                            }
                            // Get relative path (remove local_path prefix)
                            let rel_file = local_file.strip_prefix(&format!("{}/", patch.local_path))
                                .unwrap_or(local_file);
                            
                            // Check if this tracked file no longer exists in worktree
                            if !wt_files.contains(rel_file) {
                                log_info(&format!("Removing deleted file: {}", rel_file));
                                let full_path = format!("{}/{}", env::current_dir()?.display(), local_file);
                                let _ = std::fs::remove_file(&full_path);
                            }
                        }
                    }
                }
                
                // Step 6: Rsync worktree → local_path (without --delete, we handle deletions above)
                log_info(&format!("Syncing files to {}...", patch.local_path));
                let src = format!("{}/{}/", patch.worktree, patch.remote_path);
                let dst = format!("{}/", patch.local_path);
                if let Err(e) = run_cmd(&["rsync", "-av", "--exclude", ".git", &src, &dst]) {
                    log_error(&format!("Failed to sync files: {}", e));
                    if stashed {
                        let _ = run_cmd(&["git", "-C", &local_abs_path, "stash", "pop"]);
                    }
                    continue;
                }

                // Step 7: Restore stashed changes
                if stashed {
                    log_info("Restoring stashed local changes...");
                    if let Err(e) = run_cmd(&["git", "-C", &local_abs_path, "stash", "pop"]) {
                        log_error("Failed to restore stashed changes. Conflicts may exist.");
                        log_error(&format!("Resolve manually in: {}", patch.local_path));
                        log_info("Run 'git status' to see conflicts, then 'git stash drop' when resolved.");
                    } else {
                        // Check for conflicts after pop
                        if let Ok(conflicts) = run_cmd(&[
                            "git",
                            "-C",
                            &local_abs_path,
                            "diff",
                            "--name-only",
                            "--diff-filter=U",
                        ]) {
                            if !conflicts.trim().is_empty() {
                                log_error("Conflicts detected after restoring local changes:");
                                println!("{}", conflicts);
                                log_info("Resolve conflicts, then run 'git add' and continue.");
                            }
                        }
                    }
                }

                log_success(&format!("Sync completed for {}", patch.local_path));
            }
        }
        Commands::Cd { path } => {
            let metadata = load_metadata()?;
            if metadata.patches.is_empty() {
                println!("No patches configured.");
                return Ok(());
            }

            if !path.is_empty() {
                // Path provided: open shell
                open_shell_in_dir(path, "local_path")?;
            } else {
                // No path: use fzf and copy to clipboard
                match select_patch_interactive(&metadata) {
                    Ok(Some(patch)) => {
                        let rel_path = get_relative_path(&patch.local_path);
                        copy_to_clipboard(&rel_path)?;
                        log_success(&format!("Path copied to clipboard: {}", rel_path));
                    }
                    Ok(None) => {
                        log_info("No selection made.");
                    }
                    Err(_) => {
                        log_info("fzf not available. Showing patch list; rerun with a path.");
                        println!("{}", Table::new(metadata.patches));
                    }
                }
            }
        }
        Commands::Wt { path } => {
            let metadata = load_metadata()?;
            if metadata.patches.is_empty() {
                println!("No patches configured.");
                return Ok(());
            }

            if !path.is_empty() {
                // Path provided: open shell
                open_shell_in_dir(path, "worktree")?;
            } else {
                // No path: use fzf and copy to clipboard
                match select_patch_interactive(&metadata) {
                    Ok(Some(patch)) => {
                        let rel_path = get_relative_path(&patch.worktree);
                        copy_to_clipboard(&rel_path)?;
                        log_success(&format!("Path copied to clipboard: {}", rel_path));
                    }
                    Ok(None) => {
                        log_info("No selection made.");
                    }
                    Err(_) => {
                        log_info("fzf not available. Showing patch list; rerun with a path.");
                        println!("{}", Table::new(metadata.patches));
                    }
                }
            }
        }
        Commands::List => {
            let metadata = load_metadata()?;

            // Collect unique remote names from patches
            let used_remotes: std::collections::HashSet<String> =
                metadata.patches.iter().map(|p| p.remote.clone()).collect();

            if !used_remotes.is_empty() {
                if let Ok(remotes) = run_cmd(&["git", "remote", "-v"]) {
                    if !remotes.is_empty() {
                        log_info("Configured Remotes:");

                        // Map to track fetch/push URLs per remote for deduplication
                        let mut remote_map: std::collections::HashMap<String, (String, String)> =
                            std::collections::HashMap::new();

                        for line in remotes.lines() {
                            let fields: Vec<&str> = line.split_whitespace().collect();
                            if fields.len() >= 3 {
                                let name = fields[0];
                                let url = fields[1];
                                let rtype = fields[2];

                                if !used_remotes.contains(name) {
                                    continue;
                                }

                                let entry = remote_map.entry(name.to_string()).or_insert_with(|| (String::new(), String::new()));
                                if rtype.contains("fetch") {
                                    entry.0 = url.to_string();
                                } else if rtype.contains("push") {
                                    entry.1 = url.to_string();
                                }
                            }
                        }

                        #[derive(Tabled)]
                        struct RemoteRow {
                            name: String,
                            url: String,
                        }
                        let mut rows: Vec<RemoteRow> = Vec::new();
                        for (name, (fetch, push)) in &remote_map {
                            if fetch == push || push.is_empty() {
                                rows.push(RemoteRow {
                                    name: name.clone(),
                                    url: fetch.clone(),
                                });
                            } else {
                                rows.push(RemoteRow {
                                    name: name.clone(),
                                    url: format!("{} (fetch)", fetch),
                                });
                                rows.push(RemoteRow {
                                    name: name.clone(),
                                    url: format!("{} (push)", push),
                                });
                            }
                        }
                        println!("{}", Table::new(rows));
                        println!();
                    }
                }
            }

            if metadata.patches.is_empty() {
                println!("No patches configured.");
            } else {
                log_info("Configured Patches:");
                println!("{}", Table::new(metadata.patches).to_string());
            }
        }
        Commands::Status => {
            let metadata = load_metadata()?;
            if metadata.patches.is_empty() {
                println!("No patches configured.");
                return Ok(());
            }

            #[derive(Tabled)]
            struct StatusRow {
                #[tabled(rename = "LOCAL PATH")]
                path: String,
                #[tabled(rename = "DIFF")]
                diff: String,
                #[tabled(rename = "UPSTREAM")]
                upstream: String,
                #[tabled(rename = "CONFLICTS")]
                conflicts: String,
            }

            let mut rows = Vec::new();
            for patch in metadata.patches {
                let mut row = StatusRow {
                    path: patch.local_path.clone(),
                    diff: "Clean".to_string(),
                    upstream: "Synced".to_string(),
                    conflicts: "No".to_string(),
                };

                if !Path::new(&patch.worktree).exists() {
                    row.diff = "Missing WT".to_string();
                } else {
                    let diff_check = duct::cmd(
                        "git",
                        [
                            "diff",
                            "--no-index",
                            "--quiet",
                            &format!("{}/{}", patch.worktree, patch.remote_path),
                            &patch.local_path,
                        ],
                    )
                    .unchecked()
                    .run()?;
                    if !diff_check.status.success() {
                        row.diff = "Modified".to_string();
                    }

                    let behind = run_cmd(&[
                        "git",
                        "-C",
                        &patch.worktree,
                        "rev-list",
                        "--count",
                        "HEAD..@{upstream}",
                    ])
                    .unwrap_or_else(|_| "0".to_string());
                    let ahead = run_cmd(&[
                        "git",
                        "-C",
                        &patch.worktree,
                        "rev-list",
                        "--count",
                        "@{upstream}..HEAD",
                    ])
                    .unwrap_or_else(|_| "0".to_string());

                    if behind != "0" {
                        row.upstream = format!("{} behind", behind);
                    } else if ahead != "0" {
                        row.upstream = format!("{} ahead", ahead);
                    }

                    match run_cmd(&["git", "-C", &patch.worktree, "ls-files", "-u"]) {
                        Ok(c) if !c.is_empty() => row.conflicts = "YES".to_string(),
                        _ => (),
                    }
                }
                rows.push(row);
            }
            println!("{}", Table::new(rows).to_string());
        }
        Commands::Remove { path } => {
            let path = normalize_local_path(path);
            let mut metadata = load_metadata()?;
            let patch_idx = metadata
                .patches
                .iter()
                .position(|p| normalize_local_path(&p.local_path) == path);

            let patch = match patch_idx {
                Some(idx) => metadata.patches.remove(idx),
                None => return Err(anyhow!("Patch not found for path: {}", path)),
            };

            log_info(&format!("Removing patch at {}...", path));

            // 1. Remove worktree
            if Path::new(&patch.worktree).exists() {
                log_info(&format!("Removing git worktree at {}...", patch.worktree));
                if let Err(e) = run_cmd(&["git", "worktree", "remove", "--force", &patch.worktree]) {
                    log_error(&format!("Failed to remove worktree: {}", e));
                }
            }

            // 2. Remove from Crossfile
            log_info("Removing from Crossfile...");
            if let Ok(cross_path) = get_crossfile_path() {
                if let Ok(content) = fs::read_to_string(&cross_path) {
                    let lines: Vec<String> = content
                        .lines()
                        .filter(|l| !l.contains("patch") || !l.contains(&path))
                        .map(|l| l.to_string())
                        .collect();
                    let mut new_content = lines.join("\n");
                    if !new_content.is_empty() {
                        new_content.push('\n');
                    }
                    let _ = fs::write(&cross_path, new_content);
                }
            }

            // 3. Save metadata
            log_info("Updating metadata...");
            save_metadata(&metadata)?;

            // 4. Remove local directory
            log_info(&format!("Deleting local directory {}...", path));
            if let Err(e) = fs::remove_dir_all(&path) {
                log_error(&format!("Failed to remove local directory: {}", e));
            }

            log_success("Patch removed successfully.");
        }
        Commands::Prune { remote } => {
            let mut metadata = load_metadata()?;
            
            if let Some(remote_name) = remote {
                // Prune specific remote: remove all its patches
                log_info(&format!("Pruning all patches for remote: {}...", remote_name));
                
                // Find all patches for this remote
                let patches_to_remove: Vec<Patch> = metadata
                    .patches
                    .iter()
                    .filter(|p| p.remote == *remote_name)
                    .cloned()
                    .collect();
                
                if patches_to_remove.is_empty() {
                    log_info(&format!("No patches found for remote: {}", remote_name));
                } else {
                    // Remove each patch
                    for patch in patches_to_remove {
                        log_info(&format!("Removing patch: {}", patch.local_path));
                        
                        // Remove worktree
                        if Path::new(&patch.worktree).exists() {
                            let _ = run_cmd(&["git", "worktree", "remove", "--force", &patch.worktree]);
                        }
                        
                        // Remove from Crossfile
                        if let Ok(cross_path) = get_crossfile_path() {
                            if let Ok(content) = fs::read_to_string(&cross_path) {
                                let lines: Vec<String> = content
                                    .lines()
                                    .filter(|l| !l.contains("patch") || !l.contains(&patch.local_path))
                                    .map(|l| l.to_string())
                                    .collect();
                                let mut new_content = lines.join("\n");
                                if !new_content.is_empty() {
                                    new_content.push('\n');
                                }
                                let _ = fs::write(&cross_path, new_content);
                            }
                        }
                        
                        // Remove from metadata
                        metadata.patches.retain(|p| p.local_path != patch.local_path);
                        
                        // Remove local directory
                        let _ = fs::remove_dir_all(&patch.local_path);
                    }
                    save_metadata(&metadata)?;
                }
                
                // Remove the remote itself
                if let Ok(remotes) = run_cmd(&["git", "remote"]) {
                    if remotes.lines().any(|r| r.trim() == remote_name) {
                        log_info(&format!("Removing git remote: {}", remote_name));
                        let _ = run_cmd(&["git", "remote", "remove", remote_name]);
                    }
                }
                
                log_success(&format!("Remote {} and all its patches pruned successfully.", remote_name));
            } else {
                // Prune all unused remotes (no active patches)
                log_info("Finding unused remotes...");
                
                // Get all remotes used by patches
                let used_remotes: std::collections::HashSet<String> = 
                    metadata.patches.iter().map(|p| p.remote.clone()).collect();
                
                // Get all git remotes
                let all_remotes = run_cmd(&["git", "remote"])?;
                let all_remotes: Vec<String> = all_remotes
                    .lines()
                    .map(|s| s.trim().to_string())
                    .filter(|r| !r.is_empty() && r != "origin" && r != "git-cross")
                    .collect();
                
                // Find unused remotes
                let unused_remotes: Vec<String> = all_remotes
                    .into_iter()
                    .filter(|r| !used_remotes.contains(r))
                    .collect();
                
                if unused_remotes.is_empty() {
                    log_info("No unused remotes found.");
                } else {
                    log_info(&format!("Unused remotes: {}", unused_remotes.join(", ")));
                    print!("Remove these remotes? [y/N]: ");
                    std::io::stdout().flush()?;
                    
                    let mut input = String::new();
                    std::io::stdin().read_line(&mut input)?;
                    
                    if input.trim().to_lowercase() == "y" {
                        for remote in unused_remotes {
                            log_info(&format!("Removing remote: {}", remote));
                            let _ = run_cmd(&["git", "remote", "remove", &remote]);
                        }
                        log_success("Unused remotes removed.");
                    } else {
                        log_info("Pruning cancelled.");
                    }
                }
                
                // Always prune stale worktrees
                log_info("Pruning stale worktrees...");
                let _ = run_cmd(&["git", "worktree", "prune", "--verbose"]);
                log_success("Worktree pruning complete.");
            }
        }
        Commands::Diff { path } => {
            let metadata = load_metadata()?;
            let mut found = false;
            for patch in metadata.patches {
                if !path.is_empty() && patch.local_path != *path {
                    continue;
                }
                found = true;
                if !Path::new(&patch.worktree).exists() {
                    log_error(&format!("Worktree not found for {}", patch.local_path));
                    continue;
                }

                let wt_path = format!("{}/{}", patch.worktree, patch.remote_path);
                // git diff --no-index returns 1 on differences, duct handles it via unchecked() if we want to ignore exit code
                let _ = duct::cmd("git", ["diff", "--no-index", &wt_path, &patch.local_path]).run();
            }
            if !found && !path.is_empty() {
                return Err(anyhow!("Patch not found for path: {}", path));
            }
        }
        Commands::Replay => {
            log_info("Replaying Crossfile...");
            let path = get_crossfile_path()?;
            if !path.exists() {
                println!("No Crossfile found.");
                return Ok(());
            }

            let curr_exe = std::env::current_exe()?;
            let script = format!(
                r#"cross() {{ "{}" "$@"; }}; source "{}" "#,
                curr_exe.display(),
                path.display()
            );
            let status = duct::cmd!("bash", "-c", script).unchecked().run()?;

            if status.status.success() {
                log_success("Replay completed.");
            } else {
                return Err(anyhow::anyhow!("Replay failed"));
            }
        }
        Commands::Init => {
            let path = "Crossfile";
            if Path::new(path).exists() {
                log_info("Crossfile already exists.");
                return Ok(());
            }
            fs::write(path, "# git-cross configuration\n")?;
            log_success("Crossfile initialized.");
        }
        Commands::Push {
            path,
            branch,
            force,
            yes,
            message,
        } => {
            let metadata = load_metadata()?;
            let patch = metadata
                .patches
                .iter()
                .find(|p| p.local_path == *path || path.is_empty())
                .context(format!("Could not resolve patch context for '{}'", path))?;

            log_info(&format!(
                "Syncing changes from {} back to {}...",
                patch.local_path, patch.worktree
            ));

            let src = format!("{}/", patch.local_path);
            let dst = format!("{}/{}/", patch.worktree, patch.remote_path);
            run_cmd(&["rsync", "-av", "--delete", "--exclude", ".git", &src, &dst])?;

            log_info("Worktree updated. Status:");
            println!(
                "{}",
                run_cmd(&["git", "-C", &patch.worktree, "status", "--short"])?
            );

            if !*yes {
                println!("Run push? (y/n)");
                let mut input = String::new();
                std::io::stdin().read_line(&mut input)?;
                if input.trim().to_lowercase() != "y" {
                    log_info("Push cancelled.");
                    return Ok(());
                }
            }

            let msg = if let Some(m) = message {
                m.clone()
            } else {
                run_cmd(&["git", "log", "-1", "--pretty=%s", "--", &patch.local_path])
                    .unwrap_or_else(|_| "Update from git-cross".to_string())
            };

            log_info("Committing and pushing...");
            run_cmd(&["git", "-C", &patch.worktree, "add", "."])?;
            let _ = run_cmd(&["git", "-C", &patch.worktree, "commit", "-m", &msg]);

            let target_branch = branch.as_ref().unwrap_or(&patch.branch);

            let mut push_args = vec!["-C", &patch.worktree, "push"];
            if *force {
                push_args.push("--force");
            }
            push_args.push(&patch.remote);

            let refspec = if target_branch.starts_with("refs/") {
                format!("HEAD:{}", target_branch)
            } else {
                format!("HEAD:refs/heads/{}", target_branch)
            };
            push_args.push(&refspec);

            let mut full_push_args = vec!["git"];
            full_push_args.extend(push_args);
            run_cmd(&full_push_args)?;

            log_success("Push completed.");
        }
        Commands::Exec { args } => {
            let full_cmd = args.join(" ");
            log_info(&format!("Executing custom command: {}", full_cmd));
            let _ = duct::cmd("bash", ["-c", &full_cmd]).run();
        }
    }

    Ok(())
}
