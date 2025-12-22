use anyhow::{Context, Result, anyhow};
use clap::{Parser, Subcommand};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::Path;
use tabled::{Table, Tabled};

#[derive(Parser)]
#[command(name = "git-cross-rust")]
#[command(version = "0.1.0")]
#[command(
    about = "A tool for vendoring git directories using worktrees [EXPERIMENTAL/WIP]",
    long_about = "Note: The Rust implementation of git-cross is currently EXPERIMENTAL and WORK IN PROGRESS. The Go implementation is the primary focus and recommended for production use."
)]
struct Cli {
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
    remote: String,
    remote_path: String,
    local_path: String,
    worktree: String,
    #[tabled(skip)]
    branch: String,
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

const METADATA_PATH: &str = ".git/cross/metadata.json";
const CROSSFILE_PATH: &str = "Crossfile";

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

fn load_metadata() -> Result<Metadata> {
    if Path::new(METADATA_PATH).exists() {
        let content = fs::read_to_string(METADATA_PATH)?;
        Ok(serde_json::from_str(&content)?)
    } else {
        Ok(Metadata {
            patches: Vec::new(),
        })
    }
}

fn save_metadata(metadata: &Metadata) -> Result<()> {
    let dir = Path::new(METADATA_PATH).parent().unwrap();
    fs::create_dir_all(dir)?;
    let content = serde_json::to_string_pretty(metadata)?;
    fs::write(METADATA_PATH, content)?;
    Ok(())
}

fn update_crossfile(line: &str) -> Result<()> {
    let mut content = if Path::new(CROSSFILE_PATH).exists() {
        fs::read_to_string(CROSSFILE_PATH)?
    } else {
        String::new()
    };

    if !content.lines().any(|l| l.trim() == line.trim()) {
        if !content.is_empty() && !content.ends_with('\n') {
            content.push('\n');
        }
        content.push_str(line);
        content.push('\n');
        fs::write(CROSSFILE_PATH, content)?;
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
                run_cmd(&["git", "-C", &wt_dir, "sparse-checkout", "init", "--cone"])?;
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
                existing.remote = spec.remote.clone();
                existing.remote_path = spec.remote_path.clone();
                existing.branch = branch_name.clone();
                existing.worktree = wt_dir.clone();
            } else {
                metadata.patches.push(Patch {
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

                run_cmd(&[
                    "git",
                    "-C",
                    &patch.worktree,
                    "pull",
                    "--rebase",
                    &patch.remote,
                    &patch.branch,
                ])?;

                log_info(&format!("Syncing files to {}...", patch.local_path));
                let src = format!("{}/{}/", patch.worktree, patch.remote_path);
                let dst = format!("{}/", patch.local_path);
                run_cmd(&["rsync", "-av", "--delete", "--exclude", ".git", &src, &dst])?;
            }
            log_success("Sync completed.");
        }
        Commands::List => {
            let metadata = load_metadata()?;
            if metadata.patches.is_empty() {
                println!("No patches configured.");
            } else {
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
            if !Path::new(CROSSFILE_PATH).exists() {
                println!("No Crossfile found.");
                return Ok(());
            }

            let curr_exe = std::env::current_exe()?;
            let script = format!(
                r#"cross() {{ "{}" "$@"; }}; source "{}" "#,
                curr_exe.display(),
                CROSSFILE_PATH
            );
            let status = duct::cmd!("bash", "-c", script).unchecked().run()?;

            if status.status.success() {
                log_success("Replay completed.");
            } else {
                return Err(anyhow::anyhow!("Replay failed"));
            }
        }
        Commands::Init => {
            if Path::new(CROSSFILE_PATH).exists() {
                log_info("Crossfile already exists.");
            } else {
                fs::write(CROSSFILE_PATH, "# git-cross configuration\n")?;
                log_success("Crossfile initialized.");
            }
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
