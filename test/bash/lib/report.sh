#!/usr/bin/env bash
set -euo pipefail

REPORT_ITEMS=()

record_result() {
    local category="$1"
    local name="$2"
    local status="$3"
    local message="${4:-}"
    REPORT_ITEMS+=("${category}|${name}|${status}|${message}")
}

record_verification() {
    record_result "verification" "$1" "$2" "${3:-}"
}

write_report() {
    local output="$1"
    {
        printf '{"results":['
        local first=1
        local item
        for item in "${REPORT_ITEMS[@]-}"; do
            local category name status message
            IFS='|' read -r category name status message <<<"${item}"
            if [[ ${first} -eq 0 ]]; then
                printf ','
            fi
            printf '{"category":"%s","name":"%s","status":"%s"' \
                "${category}" "${name}" "${status}"
            if [[ -n "${message}" ]]; then
                local escaped_message
                escaped_message="${message//"/\\"}"
                printf ',"message":"%s"' "${escaped_message}"
            fi
            printf '}'
            first=0
        done
        printf ']}'
    } >"${output}"
}
