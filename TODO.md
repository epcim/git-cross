Known issues:

- re-test `replay` of default Crossfile and add additional test cases
- patch/replay fails if "vendor" folder dont exist, `patch` function shall create required directories
- Crossfile commands shall start with "cross"
- Feature post hook. How to implement some clenaup per "patch". Alt1: Crossfile could be understood as "shell" file. Alt2: we could define post_hooks in Crossfile per patch, and innter would be shell cmds to executed.
