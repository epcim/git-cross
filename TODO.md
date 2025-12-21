Known issues:

- [x] Update In README.md, an example how users can implement their "post-hook" actions.
- [x] Implement the test 006 for "push" command. (Note: Files kept but implementation deferred).
- [x] Implement the test 007 for "status" command. 
- [x] Wire test 7 to github CI workflow.
- [x] Suggest cleanup of the repository from no-longer required code and descriptions.
- [x] Implement "cross" command in Rust with the same functionality as `just cross`.
- [x] Update README.md with the new "cross" command implemented in Rust.
- [x] Implement "cross" command in Golang with the same functionality as `just cross`. 
    - Use `github.com/gogs/git-module` for Git operations.
    - Use `github.com/zloylos/grsync` for `rsync` operations.
    - Rename "src" to "src-rust" and create "src-go" for the Golang implementation. 
    - Update README.md with the new "cross" command implemented in Golang.
- [x] Update `Justfile` with additional targets `cross-go` and `cross-rust` to run the appropriate implementation.