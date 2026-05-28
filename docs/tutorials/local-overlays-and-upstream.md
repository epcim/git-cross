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
  .crossignore
```

## Step 1: Register Upstream

```bash
git cross use app https://github.com/example/app.git
```

This creates a named upstream alias, here `app`.

## Step 2: Patch The Upstream Directory Locally

```bash
git cross patch app:src vendor/app
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
cat > vendor/app/.crossignore <<'EOF'
.env
compose.override.yaml
EOF
```

## Step 4: Review Local State

```bash
git cross status
git cross diff vendor/app
```

What you should see:

- `status` reports `Override` for `vendor/app`
- `diff` prints manual compare commands for the override paths

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

## Step 6: Pull New Upstream Changes Later

```bash
git cross sync vendor/app
```

Then review again:

```bash
git cross status
git cross diff vendor/app
```

Especially if local-only files live next to upstream-managed files, keep the review loop explicit.

## Step 7: Prepare A Clean Upstream Contribution

When you want to send a fix upstream, first separate the changes that belong upstream from the changes that belong only in your repo.

The cleanest setup is to track a writable fork from the start, then open a PR or MR from that fork to the original project.

If your current patch points at a read-only upstream remote, switch the tracked remote to your fork before using `git cross push`.

Before pushing upstream-bound changes:

1. review `git cross diff vendor/app`
2. make sure local-only overlay files are not part of what you intend to send upstream
3. keep the upstream contribution limited to upstream-managed files

Then push:

```bash
git cross push vendor/app --message "Fix parser bug"
```

After that, open a PR or MR from your fork branch to the original upstream project.

## Practical Advice

- Use your main repo `origin` for your final combined product state.
- Use a fork remote for upstream contribution.
- Keep local secrets and machine config clearly marked in `.crossignore`.
- Treat `.crossignore` entries as review helpers, not as permission to stop thinking about what gets pushed.

## When To Use A Sandbox

If you want to try this workflow without giving an agent or tool access to your whole repository, use the repo-local kit:

```bash
sbx run opencode --kit ./sbx-kits/opencode
```

Then mount only the vendored path you want the tool to edit.

See `sbx-kits/README.md` for the layout.
