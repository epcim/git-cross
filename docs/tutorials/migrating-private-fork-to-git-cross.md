# Tutorial: Migrate A Private Fork To `git-cross`

## Goal

This tutorial shows a cautious migration path for a private repository that started life as a fork or derivative of an upstream project and now contains:

- private files such as `.env`
- machine-local or company-local overrides
- upstream-derived files mixed together at repo root

The end state is:

- the repo root is tracked as a `git-cross` patch
- upstream relationship is managed through a hidden worktree
- local-only files are restored and marked for review with `.crossignore`

## Important Safety Note

This is an advanced workflow.

Current shipped behavior:

- non-comment entries in `.crossignore` affect review surfaces such as `status` and `diff`
- they do **not** guarantee protection during the initial repo-root materialization step

So for the first migration patch, do **not** rely on `.crossignore` alone.

Use:

1. a backup branch or tag
2. a fresh clone or throwaway migration branch
3. an external copy of all local-only files before running `git cross patch upstream:. .`

## Scenario

Assume:

- current repo root contains upstream-derived application files
- your private repo also contains local-only files such as `.env`, `.env.local`, `docker-compose.override.yml`, or private config directories
- you want the repo to stay at repo root, not move upstream content into `vendor/...`

## Before Step 1: Decide Where The Upstream Comes From

There are two valid starting points.

### Case A: A Clean Upstream Repo Already Exists

If you already have a real upstream repository that contains only the shareable code, continue with Step 1.

### Case B: Your Current Private Repo Is The Only Copy

If the current private repo is the only place where the code exists and it mixes:

- upstream-worthy project files
- private files such as `.env`
- machine-local or company-local overrides

create a clean upstream seed repository first, then come back and migrate the private repo with `git-cross`.

This split has its own focused walkthrough:
`docs/tutorials/split-repo-into-upstream-and-private.md`.

The core idea there is a single shared rule: one `.crossignore` lists the private
patterns, and `git ls-files` selects the matching files for both jobs —

```bash
# back up / keep (rsync): include untracked too
git ls-files -z --cached --others --ignored --exclude-from=.crossignore

# remove from upstream seed (delete from copy): tracked only
git ls-files -z --cached --ignored --exclude-from=.crossignore
```

- the tracked list, deleted with `rm -rf` then `git add -A`, strips those files from the new upstream seed
- the full list piped to `rsync` in your private repo *backs up and keeps* them

Use `rm` + `git add -A` rather than `git rm` for the seed: `git rm` aborts the
whole batch on untracked pathspecs or on a submodule it cannot name. Deleting from
the working tree and restaging handles files, directories, and submodule gitlinks
uniformly.

Do the split there, then return here at Step 1 with a clean upstream in hand.

Important note:

- if secrets or private files were ever committed into Git history and you plan to publish that history, do a real history rewrite first
- the split tutorial only covers the working-tree split, not secret-history cleanup

## Step 1: Make A Safety Snapshot

Before changing anything, create a backup branch or tag.

Example:

```bash
git checkout -b backup/pre-git-cross-migration
git push origin backup/pre-git-cross-migration
```

If you prefer tags:

```bash
git tag pre-git-cross-migration
git push origin pre-git-cross-migration
```

## Step 2: Work In A Fresh Clone Or Throwaway Branch

The safest migration is done in a fresh clone of your private repo.

That way, if the first root patch is not what you expected, you can discard the whole working copy.

## Step 3: Inventory Local-Only Files And Draft `.crossignore`

Make a list of files that must stay private or local-only.

Typical examples:

- `.env`
- `.env.local`
- `docker-compose.override.yml`
- `config/private/`
- machine-local certificate files

For current shipped behavior, write them into `.crossignore` first.

Current parsing rules are simple:

- each non-empty, non-comment line is one override pattern
- a plain basename entry such as `.env` matches that name in any subdirectory under the patch
- plain entries such as `.env` or `config/private` are supported
- basename globs such as `*.env` are supported anywhere under the patch
- directory entries such as `config` or `config/` are supported
- full gitignore semantics are **not** supported today

Example list:

```text
.env
*.env
docker-compose.override.yml
config/
```

Examples that are still **not** promised as full gitignore-style patterns:

```text
config/*
**/*.env
!negation
```

## Step 4: Copy Local-Only Files Out Of The Repo

Before the first `git-cross` root patch, copy those files outside the repository.

If you are using the Just implementation during migration, you can reuse the current `.crossignore` matches as the backup source list:

```bash
mkdir -p ../private-overrides-backup
just cross _crossignore_overrides "$PWD" \
  | rsync -avR --files-from=- ./ ../private-overrides-backup/
```

If you are not using the Just implementation, use the same `.crossignore` file as your checklist and back up the matching files with `rsync`, `tar`, or your preferred tooling.

If a file is sensitive, verify that your backup location is safe.

Advanced alternatives if you prefer them:

- create a tar archive of the private files before migration
- temporarily move local-only files out through Git history or branch surgery tools before the root patch

Those approaches are more invasive. The external backup copy is still the simplest migration checkpoint.

## Step 5: Register The Upstream Remote

If you want upstream contribution later, the cleanest pattern is to register a writable fork from the start.

If you only want to mirror the original upstream first, register the original upstream now and switch to a fork later.

If you created a clean upstream seed repository in the earlier split step, register that repository here.

Example:

```bash
git cross use upstream https://github.com/example/project.git
```

## Step 6: Patch Upstream Root Into Repo Root

Now create the repo-root patch:

```bash
git cross patch upstream:. .
```

Equivalent form:

```bash
git cross patch upstream:/ .
```

This is the key migration step: repo root is now associated with the upstream root through a hidden worktree.

## Step 7: Restore Local-Only Files And Create `.crossignore`

Restore the local-only files you copied out earlier.

Example:

```bash
rsync -av ../private-overrides-backup/ ./ 2>/dev/null || true
```

Then write `.crossignore`:

```bash
cat > .crossignore <<'EOF'
.env
*.env
docker-compose.override.yml
config/
EOF
```

Use simple explicit patterns. The current code treats `.crossignore` here as a small override matcher, not as full gitignore-style pattern matching.

## Step 8: Review The Migrated State

Run:

```bash
git cross status
git cross diff .
```

What to expect:

- `status` should show `Override` for the root patch if override markers exist
- `diff .` should print manual `git diff --no-index ...` commands for the override files

This is the point where you confirm the repo now matches the upstream-managed tree plus your restored private files.

## Step 9: Commit The New Managed Layout To Your Private Repo

Once the migrated state looks correct, commit it to your private repository.

```bash
git add Crossfile .crossignore .
git commit -m "Migrate repo root to git-cross managed upstream"
git push origin main
```

## Step 10: Day-2 Workflow After Migration

After the migration:

- pull upstream updates with `git cross sync .`
- review root changes with `git cross diff .`
- inspect state with `git cross status`
- publish the combined result to your private `origin` with normal Git

## Step 11: Contribute Changes Back Upstream

If you want to send some changes back upstream later:

1. review `git cross diff .`
2. make sure private files are not part of the upstream contribution
3. prefer using a writable fork as the tracked remote
4. push carefully and verify the resulting branch

Example:

```bash
git cross push . --message "Fix upstream behavior"
```

Then open a PR or MR from the pushed branch.

## Practical Recommendation

If you are not forced to keep the imported project at repo root, vendoring the upstream into a local directory such as `vendor/upstream-app` is still the safer default.

Use repo-root migration when:

- the repo is already structured that way
- moving files into a subdirectory would be too disruptive
- you are willing to do a careful one-time migration with backups and review checkpoints

For the simpler whole-upstream case inside a local directory, see:

- `docs/tutorials/whole-upstream-into-local-dir.md`
