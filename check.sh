#!/bin/sh
set -eu
cd "$(dirname "$0")"
target_arch=$(uname -m)
case "${1:-}" in
    ""|--update-stress|--logic-stress|--stress|--stress-gui|--claude-live|--live|--lint|--timing|--network) ;;
    *) echo "Usage: $0 [--update-stress | --logic-stress | --stress | --stress-gui | --claude-live | --lint | --timing | --network | --live [capture paths...]]" >&2; exit 64 ;;
esac
checks_dir=$(mktemp -d "${TMPDIR:-/tmp}/quotabar-check.XXXXXX")
sparkle=
cleanup() {
    rm -r "${checks_dir}"
    if [ -n "${sparkle}" ]; then rm -r "${sparkle}"; fi
}
trap cleanup EXIT
compile() {
    xcrun swiftc -module-cache-path "${TMPDIR:-/tmp}/quotabar-build-modules" -swift-version 5 \
        -strict-concurrency=complete -warnings-as-errors -target "${target_arch}-apple-macosx14.0" -parse-as-library "$@"
}
compile -typecheck Sources/*.swift
compile_claude_usage() {
    compile Sources/QuotaCore.swift Sources/Presentation.swift Sources/ClaudeUsageClient.swift \
        Tests/ClaudeUsageChecks.swift -o "${checks_dir}/claude-usage"
}
if [ "${1:-}" = "--claude-live" ]; then
    compile_claude_usage
    "${checks_dir}/claude-usage" --live
    exit 0
fi
if [ "${1:-}" = "--lint" ]; then
    sh -n build.sh
    sh -n check.sh
    sh -n package.sh
    sh -n fetch-sparkle.sh
    sh -n release-update.sh
    sh -n Tests/UpdaterChecks.sh
    if command -v shellcheck >/dev/null 2>&1; then shellcheck --enable=all -s sh build.sh check.sh package.sh fetch-sparkle.sh release-update.sh Tests/UpdaterChecks.sh; fi
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
logic_stress() {
    compile_app_check Tests/QuotaLogicChecks.swift "${checks_dir}/quota-logic"
    "${checks_dir}/quota-logic"
    compile Sources/PrivateFile.swift Sources/QuotaCore.swift Sources/Presentation.swift Sources/UsageResets.swift \
        Tests/ResetLogicStressChecks.swift -o "${checks_dir}/reset-logic"
    "${checks_dir}/reset-logic"
}
update_stress() {
    sparkle=$(./fetch-sparkle.sh)
    mkdir -p "${checks_dir}/Probe.app/Contents/MacOS"
    compile -F "${sparkle}" -framework Sparkle -Xlinker -rpath -Xlinker "${sparkle}" \
        Sources/Updater.swift Tests/UpdateStateChecks.swift -o "${checks_dir}/update-state"
    "${checks_dir}/update-state"
    compile -F "${sparkle}" -framework Sparkle -Xlinker -rpath -Xlinker "${sparkle}" \
        Tests/UpdateFeedChecks.swift -o "${checks_dir}/Probe.app/Contents/MacOS/Probe"
    python3 Tests/UpdateProbeChecks.py "${checks_dir}" "${sparkle}"
}
if [ "${1:-}" = "--update-stress" ]; then
    update_stress
    exit 0
fi
if [ "${1:-}" = "--logic-stress" ]; then
    logic_stress
    exit 0
fi
if [ "${1:-}" = "--stress-gui" ]; then
    export QUOTABAR_STRESS=1 QUOTABAR_TEST_FIXTURES=1
    echo 'Checking the real three-minute refresh interval and wake recovery.'
    ./check.sh --timing
    echo 'Checking network switches, offline reads and recovery.'
    ./check.sh --network
    echo 'Running provider, token, setup, reset and native menu checks.'
    ./check.sh --live
    echo 'Checking first-launch onboarding with missing provider CLIs.'
    compile_app_check Tests/OnboardingChecks.swift "${checks_dir}/onboarding"
    mkdir -p "${checks_dir}/profile" "${checks_dir}/codex/sessions" "${checks_dir}/claude/projects"
    CFFIXED_USER_HOME="${checks_dir}/profile" CODEX_HOME="${checks_dir}/codex" CLAUDE_CONFIG_DIR="${checks_dir}/claude" \
        "${checks_dir}/onboarding" "${checks_dir}"
    echo 'Checking installation, relaunch, and rejection of tampered updates.'
    ./Tests/UpdaterChecks.sh
    echo 'All graphical stress checks passed.'
    exit 0
fi
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
compile_claude_usage
"${checks_dir}/claude-usage"
compile Sources/PrivateFile.swift Sources/TokenHistory.swift Sources/ClaudeTokenHistory.swift Tests/ClaudeTokenChecks.swift -o "${checks_dir}/claude-tokens"
"${checks_dir}/claude-tokens"
if [ "${1:-}" = "--stress" ]; then
    logic_stress
    echo 'Exercising quota and token histories under load.'
    compile Sources/PrivateFile.swift Sources/QuotaCore.swift Sources/Presentation.swift Sources/ClaudeUsageClient.swift \
        Sources/TokenHistory.swift Sources/ClaudeTokenHistory.swift Tests/DataStressChecks.swift -o "${checks_dir}/data-stress"
    "${checks_dir}/data-stress"
    echo 'Racing reset confirmations from separate processes.'
    compile Sources/PrivateFile.swift Sources/QuotaCore.swift Sources/Presentation.swift Sources/UsageResets.swift \
        Tests/ResetContentionChecks.swift -o "${checks_dir}/reset-contention"
    "${checks_dir}/reset-contention"
    echo 'All window-free stress checks passed.'
    exit 0
fi
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
