Known issues:

- [x] Update In README.md, an example how users can implement their "post-hook" actions. They shall override `just cross` in their `Justfile` in their repo, similarly as @Justfile does. But call pre and post actions implemented on their Justfile to process. The other option is to implement shell call functions in "Crossfile" as it's either executed (this time purelly in bash) during `just cross replay`.
- [x] Implement the test 006 for "push" command. (Note: Files kept but implementation deferred - test/006_push.sh exits 0).
- [x] Implement the test 007 for "status" command. 
- [x] Wire test 7 to github CI workflow (auto-discovered by test/run-all.sh).
- [x] Suggest cleanup of the repository from no-longer required code and descriptions.
- [ ] Implement "cross" command in Rust with the same functionality as `just cross` (cross-platform, shared test cases).
- [ ] Update README.md with the new "cross" command implemented in Rust as a `.gitconfig` alias and `git cross` usage.