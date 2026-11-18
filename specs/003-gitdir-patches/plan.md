> **RENAME-NOTE (post-0.5.0, unreleased):** command names changed after this document
> was written: `patch`→`set`, `remove`→`del`, `set`→`cfg`, `list`→`ls`, `completion`→`comp`;
> `wt <git-args>` was retired (the bare `git cross <git-args>` fall-through is the only
> git passthrough; `wt [path]` is an alias of `cd`). This file is kept as the historical
> v0.5.0 design record — see CHANGELOG.md [Unreleased] for the current command surface.

# git-cross v0.5.0 — GIT_DIR patches (no rsync, no linked worktrees)

**Status:** DRAFT — awaiting approval  
**Target version:** 0.5.0 (breaking change)  
**Sources:** Google AI Mode conversation (share.google/aimode/ysFzGIioTEMrALUAQ), this session's POC validation (`/tmp/poc*`), user decisions below.

---

## 1. Goal

Replace the 0.4 mechanism (sparse `git worktree` under `.cross/worktrees/<remote>_<hash8>` + `rsync` worktree→local) with a **per-patch standalone gitdir** whose *work tree lives directly inside the primary repo at the patch path*:

- **No rsync anywhere.** The patch directory IS the upstream checkout.
- **No `.git` file inside the patch directory.** The primary repo tracks patch files as *normal files* (no embedded-repo/submodule gitlink — POC check 9/10 proved a `.git` file breaks primary tracking).
- **Upstream git operations** (status/diff/log/push vs upstream) run through `GIT_DIR` + `GIT_WORK_TREE` exported by `git cross` when standing in a patch directory — the "WT_GIT" wrapper concept from the AI Mode conversation.
- **No migration path.** Deleting `.cross/` and re-running `git cross update` from the Crossfile is the (existing) recovery/migration flow.

## 2. Locked decisions (from this session)

| # | Decision |
|---|----------|
| L1 | Layout: `.cross/worktrees/<remote>/<local_path_with_underscores>/` — the per-patch gitdir itself. No hash suffix (paths are unique), no nested `worktrees/` layer, no shared bare base. |
| L2 | Per-patch standalone gitdir (shallow/sparse clone). Most remotes have one patch; a shared bare base is not worth the complexity. Multi-patch remotes simply re-clone (shallow keeps it cheap). |
| L3 | `git worktree` machinery is **not** used at all — no linked worktrees, no `worktree add`, no `git worktree list`. The registry is `metadata.json` (+ directory traversal). |
| L4 | Bare clone (`git clone --bare`) per patch; porcelain ops always pass work tree explicitly (env or `--git-dir/--work-tree`). Relative `core.worktree` config is unusable (resolves from invocation CWD — POC poc3); absolute breaks portability. Pure env-driven = no absolute paths stored anywhere. |
| L5 | No migration command; `.cross/` is disposable state rebuilt from Crossfile (user-confirmed feature). |
| L6 | **Phase 0 (prune-first) is a suggestion, not mandatory** — old code stays visible in git history/diff. Preserve style/approach of existing recipes/functions where possible. |
| L7 | **ff-merge stays** as the automated update path; non-ff divergence is resolved by the user via manual **rebase** in the upstream context. **rerere stays enabled on BOTH sides**: the primary repo (0.4 behavior) and every per-patch gitdir (new — gitdirs are standalone and do not inherit the primary's config; each keeps its own `rr-cache`). |
| L8 | **Command namespace (user-decided):** cross commands must not shadow native git subcommands — unknown/native names fall through to the wt passthrough (upstream context inside a patch dir, plain git elsewhere). `wt <git-args>` and `git cross <native-cmd>` are the two passthrough forms; shell aliases won't apply (gitconfig aliases only — accepted limitation). Renames: `status`→`stat`, `prune`→`purge`, `diff` dedicated command DROPPED (= passthrough `git diff`), `init`→`set` with **`init` preserved as alias** (native `git init` passthrough is a chicken-egg impossibility). Retired `push`/`sync`/`replay`/`exec` deleted → `git cross push` inside a patch pushes to upstream. crosscd/crosswt wrappers kept (low usage expected). |

## 3. Open decisions (need user call before/at POC time)

| # | Question | Recommendation |
|---|----------|----------------|
| D3 | `remote_path` semantics: worktree root = local_path means upstream structure is mirrored → `patch khue:/metal deploy/metal` yields `deploy/metal/metal/*` (nested). Options: (a) accept nesting — `remote_path` becomes a sparse filter only; (b) whole-repo patches only (`.`) in 0.5.0; (c) subtree-commit synthesis (re-rooted, complex). | **(a)** accept nesting for the POC; revisit (c) post-0.5.0 |
| D4 | Shallow/partial fetch defaults: `--depth 1` by default? `--filter=blob:none`? plain full clone? | opt-in flags on `patch` (`--depth`, `--filter`), plain full clone default; test covers shallow variant |
| D6 | `remove` when patch files are primary-tracked: (a) leave files, delete only cross state (patch stays as dead files); (b) delete files too (`rm -rf` + visible as deletions in primary status) — 0.4 parity | **(b)** 0.4 parity: remove cross state AND the patch directory |
| D7 | Gitdir naming edge case: `deploy/metal` vs `deploy_metal` both underscore to `deploy_metal`. Collision handling | if gitdir exists and metadata says it belongs to a different local_path → error (ask user to `remove` first). Rare; no hash fallback in v0.5.0 |
| D8 | ~~`wt` semantics~~ **DECIDED (user):** `wt` does what 0.4 `cd` did — prints/enters the patch `local_path`. There is no user reason to visit `.cross/worktrees/...` anymore (the work tree lives in the repo). Upstream-context git runs via `git cross git` (GIT_DIR/GIT_WORK_TREE passthrough). |

## 4. Architecture

```
primary-repo/
├── .cross/                                   # disposable state (gitignored)
│   ├── metadata.json                         # v2 schema (below)
│   └── worktrees/
│       └── <remote>/                         # one dir per remote name
│           └── <local_path_slash→underscore>/ # per-patch bare gitdir = ".git content"
│               ├── HEAD, config, objects/, refs/, packed-refs
│               └── info/sparse-checkout      # sparse pattern (this patch only)
├── vendor/docs/                              # THE PATCH: plain files, tracked by primary
└── src/                                      # primary's own code
```

- Patch dir contains **no `.git`** → primary `git add vendor/docs` records normal blobs (validated: POC checks 11–13).
- Standing in a patch dir, plain `git` (without cross env) operates on the **primary** — that is how primary commits work.
- Upstream operations: `git cross` resolves the patch via CWD (existing `_resolve_context2` ladder) and runs git with `GIT_DIR=<gitdir> GIT_WORK_TREE=<patchdir>`.
- `crosscd`/`crosswt` shell wrappers (from `git cross completion`) export the pair, so plain `git status/push` inside the patch dir targets the upstream.

### Metadata v2 schema

```json
{
  "patches": [
    {
      "remote": "khue",
      "remote_url": "https://github.com/khuedoan/homelab.git",
      "remote_path": "metal",
      "local_path": "deploy/metal",
      "branch": "master",
      "gitdir": ".cross/worktrees/khue/deploy_metal",
      "shallow": true
    }
  ]
}
```

(Fields dropped vs 0.4: `id`, `worktree`. `remote_url` added so `use` state is reconstructable without the primary's git remotes — remotes now live in the gitdir, NOT in the primary repo.)

## 5. Validated reference mechanics (POC evidence)

All commands below were executed and verified in this session (git 2.53).

### 5.1 Create a patch (replaces worktree+rsync block)

```bash
GD=".cross/worktrees/<remote>/<local_path_underscored>"   # e.g. .cross/worktrees/khue/deploy_metal
L="<local_path>"                                          # e.g. deploy/metal

mkdir -p "$L"                                             # work tree must exist BEFORE read-tree
git clone --bare [--depth 1] [--filter=blob:none] <url> "$GD"
git --git-dir="$GD" config rerere.enabled true           # gitdir is standalone — does NOT inherit primary config
# sparse filter for remote_path (skip when remote_path is "."):
git --git-dir="$GD" config core.sparseCheckout true
echo "<remote_path>/" > "$GD/info/sparse-checkout"       # trailing / — same requirement as 0.4
git --git-dir="$PWD/$GD" --work-tree="$PWD/$L" read-tree -mu HEAD   # materialize in place
```

Notes:
- `sparse-checkout init/set` CLI refuses on a bare repo ("must be run in a work tree") — the two manual config lines above are the equivalent plumbing (validated).
- `--depth`/`--filter` are ignored on plain local paths; tests must use `file://` URLs for local fixtures (real remotes unaffected).
- No `.git` file is ever created inside `$L`.

### 5.2 Upstream ops standing in the patch dir (what cross exports)

```bash
cd deploy/metal
GIT_DIR=.cross/worktrees/khue/deploy_metal GIT_WORK_TREE=. \
  git status --short --branch     # divergence vs installed upstream
GIT_DIR=... GIT_WORK_TREE=. git log --oneline
GIT_DIR=... GIT_WORK_TREE=. git push origin HEAD:master   # targets UPSTREAM, not primary
```

`GIT_DIR` may be relative (resolved from CWD — validated); compute it from the patch dir via metadata. Nothing absolute is stored.

### 5.3 Update flow (fetch + ff-merge, preserve local edits)

```bash
git --git-dir="$GD" fetch origin "+refs/heads/<branch>:refs/remotes/origin/<branch>"
NEW=$(git --git-dir="$GD" rev-parse "refs/remotes/origin/<branch>")
GIT_DIR="$GD" GIT_WORK_TREE="$L" git merge --ff-only "$NEW"
```

- Clean tree → files update in place, HEAD advances (validated).
- Local edits on untouched files → preserved, merge succeeds (validated).
- Local edit on a file upstream also changed → merge aborts, **everything preserved**; report `'<local_path>' differs from upstream; local copy preserved` — 0.4 philosophy intact, now enforced by git itself instead of rsync dry-runs.
- Non-ff divergence (local commits in the upstream context, e.g. via `crosswt` + `git commit`) → user runs the **rebase** manually in the upstream context (`crosswt` → `git rebase origin/<branch>`); **rerere remembers conflict resolutions on both sides**:
  - gitdir: `rerere.enabled` set at patch creation (each gitdir keeps its own `rr-cache`); `update` re-ensures it and announces when newly enabled (self-heals older gitdirs),
  - primary: unchanged 0.4 behavior — `init`/`update` enable rerere in the primary config, so primary-side rebases (patch files are primary-tracked) also reuse resolutions.

### 5.4 Comparison / status (replaces rsync `-rlcn` and the `.git`-mirror dance)

```bash
GIT_DIR="$GD" GIT_WORK_TREE="$L" git status --porcelain   # local vs installed upstream
GIT_DIR="$GD" GIT_WORK_TREE="$L" git diff                  # visual diff
GIT_DIR="$GD" GIT_WORK_TREE="$L" git diff origin/<branch>  # vs latest fetched upstream
```

### 5.5 Remove

```bash
rm -rf "$GD" "$L"     # that's all — no worktree machinery, no prune dance
```

### 5.6 Things that simply disappear

- `.git`-free mirror for `git diff --no-index` (worktree roots had a `.git` pointer file; patch dirs no longer do).
- `rsync -av --delete` sync, `rsync -rlcn --itemize-changes` compare, `--exclude .git` everywhere.
- Primary-repo pollution: 0.4 ran `git fetch <remote>` in the **primary** (upstream objects landed in the primary's ODB). 0.5.0 keeps upstream objects strictly inside `.cross/`.

## 6.1 Rollout stages (user-directed: don't implement all at once)

| Stage | Scope | Status |
|---|---|---|
| 1 | checkout + patch creation (use/patch), `wt` passthrough + bare-fallback UX, first tests (025: Just + Go) | **DONE** — test 025 green for both implementations; Go extended commands (update/stat/compare/remove/purge/set) ported and smoke-validated |
| 2 | full lifecycle test (update conflict paths, remove, purge) as test/026; old 0.4-era tests update (009/012/013/014/016/017/019/021/023 assert worktree/rsync paths) | next |
| 3 | docs: README/CHANGELOG/TODO/AGENTS.md, VERSION → 0.5.0 | next |

## 6. Implementation plan

Order (per AGENTS.md): Justfile.cross → Go → tests → docs. POC = Phase 1 + Phase 2.

### Phase 0 — prune-first (SUGGESTION ONLY, not mandatory)

Delete before rewriting, so new code lands in clearly-shaped holes (old code remains in git history):

**Justfile.cross**
- `patch`: the worktree-setup block (`git worktree add`, sparse `init/set`, `read-tree`, rsync sync, `git add $l_path`)
- `_update_patch`: rsync compare + rsync sync blocks
- `diff`: `.git`-mirror / `--no-index` logic
- `prune`: `git worktree prune` + orphaned-worktrees block

**src-go/main.go**
- `grsync` dependency (go.mod + import), `runSync`, `localDiffersFromWorktree`, `directoriesDiffer`
- `.git`-mirror logic in `runNoIndexDiff`
- worktree setup/branch/hash blocks in `patchCmd`; rsync blocks in `updateCmd`

Keep helpers whose shape survives: `_resolve_context2`, `_log`, `_list_patches`, `_select_patch`, `update_crossfile`, Crossfile parsing in `update`, Go's `resolvePathToRepoRelative`, `findPatchForPath`, `selectPatchInteractive`, `printPatchRows`.

### Phase 1 — Justfile.cross POC (fish)

New/changed recipes (drop-in, same style):

```fish
# Internal: gitdir path for a patch: local_path slashes -> underscores
[no-cd]
_patch_gitdir remote local_path:
    #!/usr/bin/env fish
    set -l lp (string replace -a / _ "{{local_path}}" | string replace -a './' '')
    echo ".cross/worktrees/{{remote}}/$lp"

# Internal: export GIT_DIR/GIT_WORK_TREE for a patch (source this)
[no-cd]
_cross_env local_path:
    #!/usr/bin/env fish
    set -l entry (jq -c --arg lp (string replace -a './' '' "{{local_path}}") \
        '.patches[] | select(.local_path == $lp)' "{{REPO_DIR}}/.cross/metadata.json" | head -1)
    test -n "$entry"; or exit 1
    set -l gd (echo "$entry" | jq -r .gitdir)
    set -l lp (echo "$entry" | jq -r .local_path)
    echo "set -x GIT_DIR $gd"
    echo "set -x GIT_WORK_TREE $lp"

# Patch a directory from a remote into a local path (v2: gitdir + GIT_DIR worktree)
patch remote_spec local_path="": check-deps
    #!/usr/bin/env fish
    # --- parse spec (unchanged from 0.4) ---
    set parts (string split : {{remote_spec}})
    # ... same 3/2-part parsing, branch default detection ...
    # --- normalize paths (unchanged) ---
    # --- v2: bare clone per patch, work tree = local_path ---
    set gd (just cross _patch_gitdir $remote $l_path)
    if not test -d "$gd/.cross" ; and not test -d "$gd"
        mkdir -p (dirname "$gd") "$l_path"
        git clone --bare {{url-of-remote}} "$gd"          # url from metadata/`git remote get-url`
        if test "$r_path" != "."
            git --git-dir="$gd" config core.sparseCheckout true
            echo "$r_path/" > "$gd/info/sparse-checkout"
        end
        git --git-dir="$PWD/$gd" --work-tree="$PWD/$l_path" read-tree -mu HEAD
    end
    # --- Crossfile + metadata v2 (drop id/worktree, add gitdir+remote_url) ---
    just cross update_crossfile "cross patch $remote:$remote_branch:$r_path $l_path"
    # ... jq entry upsert ...
```

`_update_patch` v2 core:

```fish
set gd (echo "$entry" | jq -r .gitdir)
set gd_abs "{{REPO_DIR}}/$gd"
# rerere: gitdir is standalone (no shared primary config) — ensure + announce when newly enabled
if not git --git-dir="$gd_abs" config --get rerere.enabled >/dev/null
    git --git-dir="$gd_abs" config rerere.enabled true
    and just cross _log info "Enabled rerere in gitdir: conflict resolutions are remembered for later updates."
end
git --git-dir="$gd_abs" fetch $remote_url "+refs/heads/$branch:refs/remotes/origin/$branch"
set new (git --git-dir="$gd_abs" rev-parse "refs/remotes/origin/$branch")
if not GIT_DIR="$gd_abs" GIT_WORK_TREE="{{REPO_DIR}}/$l_path" git merge --ff-only "$new" 2>/dev/null
    just cross _log warn "'$l_path' differs from upstream; local copy preserved (rebase manually via 'git cross wt'; rerere remembers resolutions)"
end
```

`diff` v2 core (replaces mirror + `--no-index`):

```fish
printf '%s\n' $ctx | source
set -l gd "{{REPO_DIR}}/$gitdir"
GIT_DIR="$gd" GIT_WORK_TREE="{{REPO_DIR}}/$local_path" git diff
```

`remove` v2: Crossfile + metadata cleanup unchanged; replace the `git worktree remove` block with `rm -rf "$gd"` (keep the "shared worktree" check? — no longer needed: gitdirs are per-patch).

`wt`/`cd`: `wt` enters the patch dir with upstream env (`_cross_env | source; cd <local_path>`); `cd` stays plain (primary context). `completion` wrappers: `crosswt` sources `_cross_env`-equivalent exports before cd — emit `GIT_DIR=<gitdir> GIT_WORK_TREE=. git "$@"` passthrough function.

### Phase 2 — early test: `test/025_gitdir_patch.sh`

New self-contained test (Just-first), covering the user's list — *"new kind of .cross/worktrees/<remote>/<patch> (git repo, sparse, shallow fetch etc.) and the created patch worktree with code in main repo structure"*:

```bash
#!/bin/bash
# 025 — v0.5.0 gitdir patches: bare gitdir under .cross/worktrees/<remote>/<patch>,
#       work tree directly in primary repo, no rsync, no .git file in patch dir.
. "$(dirname "$0")/common.sh"            # setup_sandbox, create_upstream
setup_sandbox
create_upstream docs-upstream main      # fixture with docs/, src/, README.md

# 1. use + patch (shallow fixture via file://)
just cross use demo "file://$UPSTREAM"
just cross patch demo:main:docs vendor/docs
assert_dir ".cross/worktrees/demo/vendor_docs"              # gitdir = .git content only
test -f .cross/worktrees/demo/vendor_docs/HEAD              # bare layout
test ! -e vendor/docs/.git                                  # NO .git file in patch dir
assert_file vendor/docs/docs/guide.md                       # sparse: only docs/ materialized

# 2. primary tracks patch files as normal files (not gitlink)
git add vendor/docs
test "$(git ls-files -s vendor/docs | awk '{print $1}')" = "100644"

# 3. upstream ops via GIT_DIR/GIT_WORK_TREE reach upstream, not primary
( cd vendor/docs && GIT_DIR=../../.cross/worktrees/demo/vendor_docs GIT_WORK_TREE=. \
    git remote -v | grep -q "$UPSTREAM" )

# 4. shallow/sparse state
grep -q "docs/" .cross/worktrees/demo/vendor_docs/info/sparse-checkout
test -f .cross/worktrees/demo/vendor_docs/shallow            # when --depth used

# 5. update: upstream advance + local edit preserved
edit_upstream docs-upstream main docs/guide.md "v2"
echo "local note" >> vendor/docs/docs/guide.md
just cross update vendor/docs
grep -q "local note" vendor/docs/docs/guide.md

# 6. remove
just cross remove vendor/docs
test ! -e .cross/worktrees/demo/vendor_docs
test ! -e vendor/docs
```

(Actual test written with `common.sh` helpers; sketch above shows intent.)

### Phase 3 — Go (`src-go/main.go`)

- `runGitDir(patch, args...)` helper: `exec.Command("git", ...)`, `Env: GIT_DIR+GIT_WORK_TREE` — one style, `os/exec` only (per AGENTS.md; this rewrite removes the last `gogs/git-module` usage in patch/update paths).
- `patchCmd`: clone via `git clone --bare [<depth>] [<filter>] <url> <gitdir>`, rerere enable in gitdir, manual sparse config (two config lines), `read-tree -mu`, metadata v2.
- `updateCmd`: fetch refspec → `merge --ff-only` via env; re-ensure rerere in gitdir (announce when newly enabled); on failure → preserved-report with rebase hint (replaces `localDiffersFromWorktree`).
- `diffCmd`/`statusCmd`: `git status/diff` via env (delete mirror logic).
- `removeSinglePatch`/`pruneCmd`: `rm -rf gitdir`, no `worktree remove/prune`; orphaned-gitdir sweep by traversing `.cross/worktrees/<remote>/`.
- `cd`/`wt`/`completion`: `crosswt` exports both env vars; `makeDirCmd` gains an `upstream` mode.
- go.mod: drop `grsync`.

### Phase 4 — docs & housekeeping

- `README.md` + `docs/`: new architecture section, usage (`git push` inside patch via `crosswt`, primary commits via plain `git add`), migration note ("delete `.cross/`, run `git cross update`").
- `CHANGELOG.md` (0.5.0 entry), `TODO.md`, `AGENTS.md` (file map, implementation details, coverage matrix), `VERSION` → 0.5.0.
- Update tests 009/012/013/014/016/017/019/021/023 where they assert `.cross/worktrees/<remote>_<hash>` paths, `.git` pointer behavior, or rsync semantics (assertions on file presence/behavior mostly survive — user-confirmed "tests shall need only smaller changes").

## 7. Command-by-command impact

| Command | v0.4 (worktree+rsync) | v0.5.0 (gitdir+GIT_DIR) |
|---|---|---|
| `use` | adds remote to PRIMARY repo | records `remote_url` in metadata; remotes live in per-patch gitdirs (primary untouched) |
| `patch` | worktree add + sparse + rsync + `git add` | bare clone → sparse config → `read-tree`; patch dir = work tree (user `git add`s to primary as desired) |
| `update` | fetch in primary + ff worktree + rsync dance | fetch in gitdir + `merge --ff-only` via env; abort = preserve + report |
| `diff` | `git diff --no-index` vs `.git`-mirror | `git diff` (work tree vs installed upstream) via env |
| `status` | rsync dry-runs ×2 + git states | `git status --porcelain` via env + primary tracking check |
| `compare` | dirdiff worktree vs local | dirdiff `HEAD` (via `git difftool --dir-diff` in env context) vs patch dir |
| `remove` | `git worktree remove --force` + rm local | `rm -rf gitdir + local` |
| `prune` | `git worktree prune` + orphan sweep | traverse `.cross/worktrees/<remote>/`, drop unreferenced gitdirs |
| `cd` | cd local (primary ctx) | unchanged |
| `wt` | cd worktree dir | cd patch dir **with upstream env exported** (D8) |
| `list`/rows | `local_path<TAB>worktree` | `local_path<TAB>gitdir` |
| `completion` | crosscd/crosswt wrappers | crosswt additionally exports `GIT_DIR`/`GIT_WORK_TREE` |

## 8. Risks & mitigations

| Risk | Mitigation |
|---|---|
| User `git clean -fd` in primary deletes untracked patch files (before they're committed to primary) | same exposure as 0.4; document; `git cross status` detects missing files vs gitdir (`git status` shows deletions) and re-`read-tree` repairs |
| Gitdir naming collision (D7) | refuse with clear error if gitdir exists for a different local_path |
| Local edits + upstream touch same file → merge aborts | intended (preserve + report + `diff`/`compare` review); ff-merge retained, manual rebase via `crosswt` for non-ff divergence; rerere on both primary and gitdir remembers resolutions |
| Primary `.gitignore` must ignore `.cross/` | existing `ensureGitignore` unchanged |
| Shallow clone can't push old history | pushing from patch works for normal branches (POC check 8); document `--depth` trade-off |
| git version requirements | only plumbing from 2.20+; POC validated on 2.53; `read-tree -mu` + manual sparse config avoid the `sparse-checkout` CLI quirks |

## 9. Approval checklist

- [ ] Approve overall plan
- [ ] D3 nesting semantics (recommend a)
- [ ] D4 shallow defaults (recommend opt-in flags)
- [ ] D6 remove semantics (recommend b, 0.4 parity)
- [ ] D8 wt semantics (recommend a)
- [ ] Start Phase 1 (Just POC) + Phase 2 (test 025) — code shown for early review before Go
