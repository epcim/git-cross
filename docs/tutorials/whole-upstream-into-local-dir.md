# Tutorial: Whole Upstream Into A Local Directory

## Goal

This tutorial shows how to vendor an entire upstream repository into a local directory such as `vendor/upstream-app`.

Use this when:

- you want the whole upstream tree, not just one subdirectory
- you still want normal files in your repository
- you want to pull updates later or send changes back upstream

This tutorial vendors the whole upstream into a local directory, not into repo root.

## Scenario

Assume you want to embed the complete contents of an upstream repository into:

```text
vendor/upstream-app
```

That keeps the workflow simple and keeps cleanup safer than a repo-root experiment.

## Step 1: Register Upstream

```bash
git cross use app https://github.com/example/app.git
```

## Step 2: Patch The Whole Repository

You can use either `:.` or `:/`.

```bash
git cross patch app:. vendor/upstream-app
```

Equivalent form:

```bash
git cross patch app:/ vendor/upstream-app
```

After that, `vendor/upstream-app` contains the full upstream checkout as normal files.

## Step 3: Inspect The Imported Tree

```bash
git cross status
git cross diff vendor/upstream-app
```

At this point the patch should normally be `Clean` and `Synced`.

## Step 4: Customize The Vendored Tree

Edit files under `vendor/upstream-app` as needed.

For example:

```bash
printf '\nlocal customization\n' >> vendor/upstream-app/README.md
```

Review the result:

```bash
git cross diff vendor/upstream-app
```

## Step 5: Keep Local-Only Files Next To It

If you need machine-local or product-local files alongside the imported tree, create them locally and mark them in `.crossignore`.

Example:

```bash
touch vendor/upstream-app/.env

cat > vendor/upstream-app/.crossignore <<'EOF'
.env
EOF
```

Current behavior:

- `git cross status` reports `Override`
- `git cross diff vendor/upstream-app` prints a manual compare command for `.env`

Treat this as a review aid. Local-only files still need human review before any upstream push.

## Step 6: Pull New Upstream Changes Later

```bash
git cross sync vendor/upstream-app
```

Then review again:

```bash
git cross status
git cross diff vendor/upstream-app
```

## Step 7: Publish To Your Own Repo

Your own product repository is still plain Git:

```bash
git add vendor/upstream-app
git commit -m "Update vendored upstream app"
git push origin main
```

## Step 8: Contribute Back Upstream

If some of your changes belong upstream:

1. review `git cross diff vendor/upstream-app`
2. make sure local-only files are not part of the upstream contribution
3. prefer tracking a writable fork for the patch remote

Then push:

```bash
git cross push vendor/upstream-app --message "Fix upstream issue"
```

After that, open a PR or MR from your fork branch to the original project.

## When This Pattern Is Better Than A Subdirectory Patch

Use whole-upstream vendoring when:

- the upstream project is small enough to vendor completely
- you need several directories from the upstream project together
- the upstream build or runtime layout assumes repo-wide paths

Use a subdirectory patch when:

- you only need one component
- you want a smaller local footprint
- you want AI or sandbox tooling scoped to a smaller subtree
