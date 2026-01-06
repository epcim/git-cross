
# coding agent
CA_CMD := "opencode run"
CA_AGENT := "--agent GitSummary"
CA_MODEL := "--model openai/gpt-5.2"

# git squash and commit with ai assisted commit message against @{upstream}... only your changes
git-squash I="":
  #!/usr/bin/env fish
  set msg "$(begin echo "$I"; git log @{u}...HEAD; git diff @{u}...HEAD; end | {{CA_CMD}} "Generate: Commit message" {{CA_AGENT}} {{CA_MODEL}} )" \
  && git reset --soft @{u} && git commit -m "$msg" && git log -1

# print summary of changes in git repository
git-summary D="3":
  #!/usr/bin/env fish
  begin; git log "@{$D day ago}" 2>/dev/null; git diff "@{$D day ago}" 2>/dev/null; end | {{CA_CMD}} "Generate: Changelog summary" {{CA_AGENT}} {{CA_MODEL}} | tee /dev/stderr | pbcopy

