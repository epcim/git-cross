> **v0.5.0 note.** The crossed directory *is* the upstream work tree now (bare gitdir
> under `.cross/worktrees/`, no rsync, no linked worktree), `status` is `stat`,
> `prune` is `purge`, `diff` is the upstream-context passthrough (`cd` into the
> patch first), and `compare` was removed. `.crossignore` is no longer read by
> `git-cross` — treat any such file as your own plain ignore list.

# Tutorial: Local Overlays And Upstream Contribution

## Goal

This tutorial shows a practical workflow where you:

- vendor an upstream directory into your repo
- add local-only files on top of it
- publish the combined result to your own `origin`
- later send a clean change back upstream

This tutorial uses a local subdirectory such as `vendor/app`, because that is the safest supported pattern today.

## Scenario

Assume:

- your repo is the product repo your team owns
- upstream repo contains a reusable app or library
- you want local custom files next to the upstream-managed files

Example local layout after patching:

```text
vendor/app/
  README.md
  src/
  .env
  compose.override.yaml
  .gitignore          # your own ignore list for local-only files
```

## Step 1: Register Upstream

```bash
git cross use app https://github.com/example/app.git
```

This creates a named upstream alias, here `app`.

## Step 2: Patch The Upstream Directory Locally

```bash
git cross set app:src vendor/app
```

Now `vendor/app` contains normal files from the upstream `src` directory.

## Step 3: Add Local-Only Overlay Files

Create the local files you need:

```bash
touch vendor/app/.env
touch vendor/app/compose.override.yaml
```

Then mark them as local overrides:

```bash
cat > vendor/app/.gitignore <<'EOF'
.env
compose.override.yaml
EOF
```

## Step 4: Review Local State

```bash
git cross stat
cd vendor/app && git cross diff
```

What you should see:

- `git cross stat` reports `vendor/app` as modified in your repo
- `git cross diff` (inside the patch) shows only tracked upstream files — the
  local-only files are untracked, so they never reach upstream's diff

This is a deliberate review point.

If a file is local-only, treat it as local-only all the way through your review process.

## Step 5: Publish The Combined Result To Your Own Repo

Your own repo is still just normal Git.

```bash
git add vendor/app
git commit -m "Vendor app and keep local overlays"
git push origin main
```

This publishes the combined result to your own team repository.

That is separate from contributing changes back to the upstream project.

## Step 6: Update From Upstream Later

```bash
git cross update vendor/app
```

Then review again:

```bash
git cross stat
cd vendor/app && git cross diff
```

Especially if local-only files live next to upstream-managed files, keep the review loop explicit.

## Step 7: Prepare A Clean Upstream Contribution

When you want to send a fix upstream, first separate the changes that belong upstream from the changes that belong only in your repo.

The cleanest setup is to track a writable fork from the start, then open a PR or MR from that fork to the original project.

To manually prepare upstream-bound changes:

1. `cd vendor/app` (the crossed directory is upstream's work tree)
2. `git cross diff` — your edits against upstream `HEAD`
3. stage only the upstream-worthy files: `git cross add <paths>`
4. `git cross commit -m "..."` then `git cross push` (this pushes to the PATCH's
   upstream, not your repo)

## Practical Advice

- Use your main repo `origin` for your final combined product state.
- Use a fork remote if you plan to contribute upstream.
- Keep local secrets and machine config in your own `.gitignore` (cross no longer
  reads `.crossignore` — that feature was removed in 0.5.0).
- Local-only files never affect `git cross update` and never appear in the
  upstream-context diff, but they do appear as untracked files in your repo.

## When To Use A Sandbox

If you want to try this workflow without giving an agent or tool access to your whole repository, use the repo-local kit:

```bash
sbx run opencode --kit ./sbx-kits/opencode
```

Then mount only the vendored path you want the tool to edit.

See `sbx-kits/README.md` for the layout.
