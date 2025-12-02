use camino::Utf8PathBuf;
use std::fs;
use std::io::Write;
use std::process::Command;
use tempfile::TempDir;

fn repo_root() -> Utf8PathBuf {
    let manifest = Utf8PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest
        .parent()
        .and_then(|p| p.parent())
        .expect("unable to resolve repository root")
        .to_path_buf()
}

fn results_dir() -> Utf8PathBuf {
    let dir = repo_root().join("test/results/examples");
    fs::create_dir_all(&dir).expect("unable to create results directory");
    dir
}

fn ensure_fixtures(root: &Utf8PathBuf) {
    let status = Command::new(root.join("scripts/fixture-tooling/seed-fixtures.sh"))
        .status()
        .expect("failed to launch seed-fixtures.sh");
    assert!(status.success(), "fixture seeding failed");
}

fn clone_repo(root: &Utf8PathBuf, workspace: &TempDir, example_id: &str) -> Utf8PathBuf {
    let clone_dir = Utf8PathBuf::from_path_buf(workspace.path().join(format!("crossfile-{}-rust", example_id)))
        .expect("tempdir path not valid UTF-8");
    let status = Command::new("git")
        .args([
            "clone",
            "--local",
            "--no-hardlinks",
            root.as_str(),
            clone_dir.as_str(),
        ])
        .status()
        .expect("git clone failed");
    assert!(status.success(), "git clone exited with failure");
    clone_dir
}

fn run_cross_commands(clone_dir: &Utf8PathBuf, example_id: &str, commands: &[String], extra_env: &[(&str, &str)]) {
    let log_path = results_dir().join(format!("crossfile-{}-rust.log", example_id));
    let mut script = format!(
        "set -euo pipefail\ncd '{}'\nsource cross\nFETCHED=('')\nexport CROSS_NON_INTERACTIVE=1\nexport VERBOSE=true\n",
        clone_dir
    );
    for &(key, value) in extra_env {
        script.push_str(&format!("export {}={}\n", key, value));
    }
    script.push_str("setup\n");
    for cmd in commands {
        script.push_str(cmd);
        script.push('\n');
    }

    let output = Command::new("bash")
        .arg("-lc")
        .arg(script)
        .output()
        .expect("failed to execute cross commands");

    fs::write(&log_path, &output.stdout).expect("unable to write stdout log");
    fs::OpenOptions::new()
        .append(true)
        .create(true)
        .open(&log_path)
        .expect("unable to append stderr")
        .write_all(&output.stderr)
        .expect("unable to append stderr data");

    assert!(output.status.success(), "cross commands failed for example {}", example_id);
}

fn collect_hashes(clone_dir: &Utf8PathBuf, files: &[&str], example_id: &str) {
    let hash_path = results_dir().join(format!("crossfile-{}-rust.sha256", example_id));

    let mut cmd = Command::new("shasum");
    cmd.arg("-a").arg("256");
    for path in files {
        cmd.arg(clone_dir.join(path));
    }
    let output = cmd.output().expect("failed to run shasum");
    assert!(output.status.success(), "shasum failed for example {}", example_id);

    let mut lines: Vec<String> = String::from_utf8(output.stdout)
        .expect("invalid UTF-8 in shasum output")
        .lines()
        .map(|s| s.to_owned())
        .collect();
    lines.sort();

    let mut file = fs::File::create(&hash_path).expect("unable to create hash file");
    for line in lines {
        writeln!(file, "{}", line).expect("unable to write hash line");
    }
}

fn assert_expected_files(clone_dir: &Utf8PathBuf, files: &[&str]) {
    for path in files {
        let full = clone_dir.join(path);
        assert!(full.exists(), "expected file {} missing", full);
    }
    let unexpected = clone_dir.join("deploy/setup/flux");
    assert!(
        !unexpected.exists(),
        "unexpected directory {} present",
        unexpected
    );
}

fn run_example(example_id: &str, expected_files: &[&str], commands: &[String], extra_env: &[(&str, &str)]) {
    let root = repo_root();
    ensure_fixtures(&root);

    let workspace = TempDir::new().expect("unable to create temporary workspace");
    let clone_dir = clone_repo(&root, &workspace, example_id);

    let deploy = clone_dir.join("deploy");
    if deploy.exists() {
        fs::remove_dir_all(&deploy).unwrap();
    }
    fs::create_dir_all(&deploy).unwrap();

    run_cross_commands(&clone_dir, example_id, commands, extra_env);
    assert_expected_files(&clone_dir, expected_files);
    collect_hashes(&clone_dir, expected_files, example_id);
}

fn command_use(alias: &str, remote: &str) -> String {
    format!("use {} {}", alias, remote)
}

fn command_patch(spec: &str, path: &str) -> String {
    format!("patch {} {}", spec, path)
}

fn remote_url(name: &str) -> String {
    let root = repo_root();
    format!(
        "file://{}",
        root.join(format!("test/fixtures/remotes/{}.git", name))
            .as_str()
    )
}

#[test]
fn crossfile_001_parity() {
    run_example(
        "001",
        &["deploy/metal/docs/index.md"],
        &[
            command_use("khue", &remote_url("khue")),
            command_patch("khue:metal", "deploy/metal"),
        ],
        &[],
    );
}

#[test]
fn crossfile_002_parity() {
    run_example(
        "002",
        &[
            "deploy/metal/docs/index.md",
            "deploy/flux/cluster/cluster.yaml",
        ],
        &[
            command_use("khue", &remote_url("khue")),
            command_use("bill", &remote_url("bill")),
            command_patch("khue:metal", "deploy/metal"),
            command_patch("bill:setup/flux", "deploy/flux"),
        ],
        &[],
    );
}

#[test]
fn crossfile_003_parity() {
    run_example(
        "003",
        &[
            "deploy/metal/docs/index.md",
            "deploy/flux/cluster/cluster.yaml",
            "asciinema/README.md",
        ],
        &[
            command_use("khue", &remote_url("khue")),
            command_use("bill", &remote_url("bill")),
            command_use("core", &remote_url("core")),
            command_patch("khue:metal", "deploy/metal"),
            command_patch("bill:setup/flux", "deploy/flux"),
            command_patch("core:asciinema", "asciinema"),
        ],
        &[("CROSS_FETCH_DEPENDENCIES", "false")],
    );
}
