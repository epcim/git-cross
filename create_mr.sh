#!/bin/bash
# Create GitLab Merge Request

# Check if GitLab CLI is available
if command -v glab &> /dev/null; then
    echo "Creating MR with GitLab CLI..."
    glab mr create \
        --title "Git-Cross Deep Analysis & CI/CD Pipeline" \
        --description "$(cat MR_TEMPLATE.md)" \
        --source-branch "cursor/check-status-of-last-task-868c" \
        --target-branch "master" \
        --assignee "@me" \
        --label "enhancement,ci-cd,testing,documentation"
else
    echo "GitLab CLI not available. Please create MR via web interface."
    echo "Repository URL: https://github.com/epcim/git-cross"
    echo "Use the content of MR_TEMPLATE.md as the description"
fi
