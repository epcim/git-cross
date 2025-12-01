Known issues:

- [x] re-test `replay` of default Crossfile and add additional test cases
- [x] patch/replay fails if "vendor" folder dont exist, `patch` function shall create required directories
- [x] Crossfile commands shall start with "cross" (or plugin name). Future: "cross" could be the name of the tracking remote/plugin. `replay` should support 3rd party actions (e.g., `just <plugin> <cmd>`).
- Crossfile commands shall start with "cross" (or plugin name). Future: "cross" could be the name of the tracking remote/plugin. `replay` should support 3rd party actions (e.g., `just <plugin> <cmd>`).
- Crossfile commands shall start with "cross" (or plugin name). Future: "cross" could be the name of the tracking remote/plugin. `replay` should support 3rd party actions (e.g., `just <plugin> <cmd>`).
- [x] Feature post hook: Implemented via `cross exec <cmd>`. User can add `cross exec just posthook` to Crossfile to trigger their own Justfile recipes.
