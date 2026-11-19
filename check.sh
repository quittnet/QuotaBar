#!/bin/sh
set -eu
cd "$(dirname "$0")"
target_arch=$(uname -m)
case "${1:-}" in
    ""|--live|--lint|--timing|--network) ;;
    *) echo "Usage: $0 [--lint | --timing | --network | --live [capture paths...]]" >&2; exit 64 ;;
esac
checks_dir=$(mktemp -d "${TMPDIR:-/tmp}/quotabar-check.XXXXXX")
trap 'rm -r "${checks_dir}"' EXIT
compile() {
    xcrun swiftc -module-cache-path "${TMPDIR:-/tmp}/quotabar-build-modules" -swift-version 5 \
        -strict-concurrency=complete -warnings-as-errors -target "${target_arch}-apple-macosx14.0" -parse-as-library "$@"
}
compile -typecheck Sources/*.swift
if [ "${1:-}" = "--lint" ]; then
    sh -n build.sh
    sh -n check.sh
    sh -n package.sh
    if command -v shellcheck >/dev/null 2>&1; then shellcheck --enable=all -s sh build.sh check.sh package.sh; fi
    plutil -lint Resources/Info.plist
    xcrun swift-format lint --strict --recursive Sources Tests
    exit 0
fi
compile_app_check() {
    # Compile the same source set as the app, with the test supplying its own entry point.
    test_entry=$1
    binary=$2
    shift 2
    for source_file in Sources/*.swift; do
        if [ "${source_file}" != "Sources/Main.swift" ]; then set -- "$@" "${source_file}"; fi
    done
    cp -R Resources/ProviderLogos "${checks_dir}/ProviderLogos"
    compile "$@" "${test_entry}" -o "${binary}"
}
if [ "${1:-}" = "--timing" ]; then
    compile_app_check Tests/RefreshChecks.swift "${checks_dir}/timing"
    mkdir -p "${checks_dir}/profile"
    CFFIXED_USER_HOME="${checks_dir}/profile" CODEX_HOME="${checks_dir}/codex" CLAUDE_CONFIG_DIR="${checks_dir}/claude" \
        "${checks_dir}/timing" "${checks_dir}"
    exit 0
fi
if [ "${1:-}" = "--network" ]; then
    compile_app_check Tests/NetworkChecks.swift "${checks_dir}/network"
    mkdir -p "${checks_dir}/profile" "${checks_dir}/codex" "${checks_dir}/claude"
    CFFIXED_USER_HOME="${checks_dir}/profile" CODEX_HOME="${checks_dir}/codex" CLAUDE_CONFIG_DIR="${checks_dir}/claude" \
        "${checks_dir}/network" "${checks_dir}"
    exit 0
fi
compile Sources/PrivateFile.swift Sources/ClaudeConnection.swift Tests/ClaudeConnectionChecks.swift -o "${checks_dir}/claude-connection"
"${checks_dir}/claude-connection"
compile Sources/QuotaCore.swift Tests/CoreChecks.swift -o "${checks_dir}/core"
"${checks_dir}/core"
compile Sources/QuotaCore.swift Sources/Presentation.swift Tests/PresentationChecks.swift -o "${checks_dir}/presentation"
"${checks_dir}/presentation"
compile Sources/PrivateFile.swift Sources/QuotaCore.swift Sources/Presentation.swift Sources/UsageResets.swift Tests/ResetFlowChecks.swift -o "${checks_dir}/resets"
"${checks_dir}/resets"
compile Sources/PrivateFile.swift Sources/TokenHistory.swift Tests/TokenChecks.swift -o "${checks_dir}/tokens"
"${checks_dir}/tokens"
compile Sources/PrivateFile.swift Sources/QuotaCore.swift Sources/ClaudeQuota.swift Tests/ClaudeQuotaChecks.swift -o "${checks_dir}/claude-quota"
"${checks_dir}/claude-quota"
compile Sources/QuotaCore.swift Sources/ClaudeUsageClient.swift Tests/ClaudeUsageChecks.swift -o "${checks_dir}/claude-usage"
"${checks_dir}/claude-usage"
compile Sources/PrivateFile.swift Sources/TokenHistory.swift Sources/ClaudeTokenHistory.swift Tests/ClaudeTokenChecks.swift -o "${checks_dir}/claude-tokens"
"${checks_dir}/claude-tokens"
if [ "${1:-}" = "--live" ]; then
    compile_app_check Tests/MenuChecks.swift "${checks_dir}/menu"
    shift
    if [ "${QUOTABAR_TEST_FIXTURES:-0}" = 1 ]; then
        mkdir -p "${checks_dir}/profile" "${checks_dir}/codex/sessions" "${checks_dir}/claude/projects"
        CFFIXED_USER_HOME="${checks_dir}/profile" CODEX_HOME="${checks_dir}/codex" CLAUDE_CONFIG_DIR="${checks_dir}/claude" \
            "${checks_dir}/menu" "$@"
    else
        "${checks_dir}/menu" "$@"
    fi
fi
