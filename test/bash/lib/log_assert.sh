#!/usr/bin/env bash
set -euo pipefail

log_assert_before() {
    local logfile="$1"
    local first="$2"
    local second="$3"

    if [[ ! -f "${logfile}" ]]; then
        echo "Log file ${logfile} missing" >&2
        return 1
    fi

    local first_line second_line
    first_line=$(grep -n "${first}" "${logfile}" | head -1 | cut -d: -f1)
    second_line=$(grep -n "${second}" "${logfile}" | head -1 | cut -d: -f1)

    if [[ -z "${first_line}" || -z "${second_line}" ]]; then
        echo "Unable to find expected markers '${first}' or '${second}' in ${logfile}" >&2
        return 1
    fi

    if (( first_line < second_line )); then
        return 0
    fi

    echo "Marker '${first}' appears after '${second}' in ${logfile}" >&2
    return 1
}
