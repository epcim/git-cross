#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/../.. && pwd)"
TEMPLATE_ROOT="${ROOT_DIR}/test/fixtures/templates"
REMOTE_ROOT="${ROOT_DIR}/test/fixtures/remotes"

GIT_USER_NAME="git-cross-fixtures"
GIT_USER_EMAIL="fixtures@example.com"

seed_remote() {
    local name="$1"
    local template_dir="${TEMPLATE_ROOT}/${name}"
    local remote_dir="${REMOTE_ROOT}/${name}.git"
    local tmp_dir
    local work_dir

    if [[ ! -d "${template_dir}" ]]; then
        echo "Skipping ${name}: template directory ${template_dir} not found" >&2
        return 0
    fi

    rm -rf "${remote_dir}"
    mkdir -p "${REMOTE_ROOT}"
    git init --bare --initial-branch=master "${remote_dir}" >/dev/null 2>&1 || {
        git init --bare "${remote_dir}" >/dev/null 2>&1
        git --git-dir="${remote_dir}" symbolic-ref HEAD refs/heads/master >/dev/null 2>&1 || true
    }

    tmp_dir="$(mktemp -d)"
    work_dir="${tmp_dir}/work"
    git init "${work_dir}" >/dev/null 2>&1
    git -C "${work_dir}" config user.name "${GIT_USER_NAME}" >/dev/null 2>&1
    git -C "${work_dir}" config user.email "${GIT_USER_EMAIL}" >/dev/null 2>&1

    mkdir -p "${work_dir}"
    rsync -a "${template_dir}/" "${work_dir}/" >/dev/null 2>&1

    git -C "${work_dir}" add -A >/dev/null 2>&1
    if git -C "${work_dir}" diff --cached --quiet; then
        touch "${work_dir}/.seed-placeholder"
        git -C "${work_dir}" add .seed-placeholder >/dev/null 2>&1
    fi
    git -C "${work_dir}" commit -m "Seed ${name} fixture" >/dev/null 2>&1
    git -C "${work_dir}" branch -M master >/dev/null 2>&1
    git -C "${work_dir}" remote add origin "${remote_dir}" >/dev/null 2>&1
    git -C "${work_dir}" push -f origin master >/dev/null 2>&1

    rm -rf "${tmp_dir}"
    echo "Seeded ${name} fixture -> ${remote_dir}"
}

main() {
    local templates
    templates=()
    while IFS= read -r entry; do
        entry="${entry##*/}"
        if [[ "${entry}" == ".gitkeep" ]]; then
            continue
        fi
        templates+=("${entry}")
    done < <(find "${TEMPLATE_ROOT}" -maxdepth 1 -mindepth 1 -type d | sort)

    if [[ ${#templates[@]} -eq 0 ]]; then
        echo "No fixture templates found under ${TEMPLATE_ROOT}" >&2
        exit 1
    fi

    for name in "${templates[@]}"; do
        seed_remote "${name}"
    done
}

main "$@"
