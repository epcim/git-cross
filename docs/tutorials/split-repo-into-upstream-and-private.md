# Tutorial: Split One Repo Into A Clean Upstream And A Private Overlay

Start from one **original repo** that mixes shareable code with secrets, and end
with two repos:

| Role | Path | What it holds |
|------|------|---------------|
| **original repo** | `project/` | where you start: everything mixed together |
| **upstream repo** | `../project-upstream/` | new, clean, publishable, no secrets |
| **private fork** | `project/` (same dir as original) | the original repo, now tracking upstream via git-cross + local overlays |

The original repo *becomes* the private fork in place. The upstream repo is a new
clean copy you publish. Each step below marks which repo you run it in.

Use this when the original repo is the only copy of the code. If a clean upstream
already exists, use `docs/tutorials/migrating-private-fork-to-git-cross.md`.

> Safety: this only splits the working tree, not Git history. If secrets were
> ever committed and you will publish the full history, rewrite it first with
> `git filter-repo` or BFG. Seeding a fresh snapshot repo (below) avoids that —
> the new upstream starts from one clean commit.

## 1. Snapshot the original repo · *run in: original repo*

```bash
git checkout -b backup/pre-split && git push origin backup/pre-split
```

## 2. Write `.crossignore` · *run in: original repo*

This one file is the single source of truth. It drives what the upstream seed
drops, what you back up, and the overlay markers — so the sets cannot drift.

```bash
cat > .crossignore <<'EOF'
.env*
*.env
docker-compose.override.yml
config/
test/
EOF
```

Patterns are gitignore-style. Match what you mean:

- `.env` is only the literal file; `.env*` also catches `.env.local` / `.env.secrets`
- `config/` is the whole `config` tree
- `test/` matches a directory named `test` **at any depth** (recursive). Do not
  use `*/test/*` — `*` never crosses `/`, so that only matches `test` one level
  deep and only its immediate children

### The shared rule

Both jobs select files from the same `.crossignore` with `git ls-files`. The only
difference is one flag, because the two destinations handle different file sets:

```bash
# back up (rsync): include untracked files too — rsync copies whatever exists
git ls-files -z --cached --others --ignored --exclude-from=.crossignore

# remove from upstream (delete from copy): tracked files only
git ls-files -z --cached --ignored --exclude-from=.crossignore
```

The upstream side drops `--others`: untracked or gitignored files
(`node_modules/`, `.envrc.local`, …) are never part of the upstream commit
anyway, so they need no removal.

The upstream side also deletes with `rm`, **not** `git rm`. `git rm` aborts the
whole command on anything it cannot resolve — an untracked pathspec
(`pathspec ... did not match any files`) or a submodule / embedded repo
(`could not lookup name for submodule ...`). Deleting from the working tree and
re-running `git add -A` sidesteps both and treats files, directories, and
submodule gitlinks uniformly.

**It is a preview, so refine it in a loop.** Run the command on its own first,
read the output, edit `.crossignore`, run again — repeat until it lists exactly
the files you want to keep private. Only then pipe it anywhere.

**Nothing is deleted from your repo.** The deletion in step 3 only strips the
*throwaway upstream copy*; your originals never leave the private fork. The split
just sorts files by role: private files stay in the fork, shareable files go
upstream.

## 3. Create the upstream repo · *original repo → upstream repo*

Copy the tree out, then delete the tracked files matched by `.crossignore` so
exactly the private files are dropped.

```bash
# from the original repo
mkdir -p ../project-upstream
rsync -av --exclude .git ./ ../project-upstream/

# now work in the upstream repo
cd ../project-upstream
git init -b main
git add -A

# preview: refine .crossignore until this lists exactly the private files
git ls-files --cached --ignored --exclude-from=.crossignore

# delete the matched paths (files, dirs, and submodule gitlinks), then restage
git ls-files -z --cached --ignored --exclude-from=.crossignore | xargs -0 -r rm -rf --
git add -A

rm -f .crossignore                      # overlay marker does not belong upstream
git add -A
git commit -m "Initial upstream seed"
git remote add origin git@github.com:your-org/project.git
git push -u origin main

cd -                                    # back to the original repo
```

`rm` has no `--dry-run`. To dry-run the destructive line, print the command
instead of running it, or ask for confirmation:

```bash
# print what would run, run nothing
git ls-files -z --cached --ignored --exclude-from=.crossignore | xargs -0 -r echo rm -rf --

# delete with a confirmation prompt (Linux rm -rI = one prompt; macOS rm -ri = per file)
# xargs -o reopens the terminal so the prompt can read your keypress; drop -f or it skips the prompt
git ls-files -z --cached --ignored --exclude-from=.crossignore | xargs -0 -r -o rm -ri --
```

Verify no secrets survived before pushing:

```bash
# inside ../project-upstream, before pushing
git ls-files | grep -Ei 'secret|\.env' || echo "no obvious secrets tracked"
```

If a private file is still tracked, your pattern missed it — fix `.crossignore`
(e.g. `*.env*` to also catch `.env.secrets`) and re-run the preview + delete.

## 4. Back up the private files · *run in: original repo*

Same `.crossignore`, this time with `--others` added so untracked private files
are backed up too, piped to `rsync` (only existing files are copied, so globs and
missing paths cause no error):

```bash
mkdir -p ../private-overrides-backup
git ls-files -z --cached --others --ignored --exclude-from=.crossignore \
  | rsync -av --from0 --files-from=- ./ ../private-overrides-backup/
```

## 5. Turn the original repo into the private fork · *run in: original repo*

This is the transition: the original repo now tracks the upstream repo via
git-cross.

```bash
git cross use upstream git@github.com:your-org/project.git
git cross patch upstream:. .            # `upstream:/` is equivalent
```

Register a writable fork instead if you plan to contribute back.

## 6. Restore overlays and review · *run in: private fork*

```bash
rsync -av ../private-overrides-backup/ ./ 2>/dev/null || true
cat .crossignore                        # confirm it survived the patch
git cross status                        # shows `Override` for the root patch
git cross diff .
```

## 7. Commit and day-2 workflow · *run in: private fork*

```bash
git add Crossfile .crossignore . && git commit -m "Track upstream via git-cross"
git push origin main
```

- pull upstream: `git cross sync .`
- review: `git cross diff .` / `git cross status`
- contribute upstream: `git cross push . --message "..."` after confirming no
  private files are included

## Related

- `docs/tutorials/migrating-private-fork-to-git-cross.md` — clean upstream already exists
- `docs/tutorials/whole-upstream-into-local-dir.md` — vendor into `vendor/...` instead of root
- `docs/tutorials/local-overlays-and-upstream.md` — overlay a single subdirectory
