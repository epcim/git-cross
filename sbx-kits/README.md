# Sandbox Kits

This repository keeps sandbox starter kits under `sbx-kits/` so they can be versioned with the codebase.

Use repo-local paths such as `./sbx-kits/opencode`, not user-home examples like `~/.config/agx/...`.

## Why Keep Kits In The Repo

- easier for cautious users to try `git-cross` in an isolated environment
- sandbox setup stays reviewable in pull requests
- agent config and repo guidance evolve with the project
- contributors can run the same kit without global setup drift

## Layout

```text
sbx-kits/
├── README.md
├── claude/
│   ├── spec.yaml
│   └── files/
│       └── home/
│           └── .claude/
│               └── README.md
└── opencode/
    ├── spec.yaml
    └── files/
        └── home/
            └── .config/
                └── opencode/
                    └── README.md
```

General `sbx` kit structure:

```text
my-kit/
  spec.yaml
  files/
    home/
    workspace/
```

## Current Starter Kits

Run them with:

```bash
sbx run opencode --kit ./sbx-kits/opencode
sbx run claude --kit ./sbx-kits/claude
```

These starters are intentionally small.

They are meant to be a safe base for:

- sandbox-local OpenCode config
- sandbox-local Claude config
- repo-local skill loading from `.opencode/skills/`
- repo-local Claude entrypoints from `.claude/`
- experiments where only a vendored subdirectory is mounted into the sandbox

## Recommended Workflow

1. Set up `git-cross` on the host.
2. Patch the upstream content into a local directory such as `vendor/lib`.
3. Start a sandbox with the repo-local kit.
4. Mount only the vendored path you want the agent to edit.
5. Review the result on the host with `git cross diff` and `git cross status`.
6. Publish to your own repo or push upstream separately.

## Notes

- `files/home/` maps to `/home/agent/` in the sandbox.
- `files/workspace/` maps into the main workspace mount.
- keep secrets out of the kit files unless you are using a proper credential mechanism
- if you hit the current `sbx` static-files issue, keep the kit minimal and prefer runtime-mounted files until that bug is resolved

## Related Repo Files

- `.agents/`
- `.claude/`
- `.opencode/skills/`
- `docs/tutorials/migrating-private-fork-to-git-cross.md`
- `docs/tutorials/whole-upstream-into-local-dir.md`
- `docs/tutorials/local-overlays-and-upstream.md`

## References

- Docker Sandboxes: https://docs.docker.com/ai/sandboxes/
- Kits docs: https://docs.docker.com/ai/sandboxes/customize/kits/
- Kit examples: https://docs.docker.com/ai/sandboxes/customize/kit-examples/
- Reference kits repo: https://github.com/docker/sbx-kits-contrib
- Claude Code skills: https://code.claude.com/docs/en/skills
- Claude Code additional directories: https://code.claude.com/docs/en/memory#load-from-additional-directories
- OpenCode skills: https://opencode.ai/docs/skills/
- Known `sbx` static-files bug: https://github.com/docker/sbx-releases/issues/133
