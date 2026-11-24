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
QUOTABAR_TEST_PREFERENCES=
preference_snapshot="${checks_dir}/real-preferences.json"
python3 Tests/PreferenceDomainChecks.py snapshot "${preference_snapshot}"
cleanup() {
    status=$?
    python3 Tests/PreferenceDomainChecks.py verify "${preference_snapshot}" || status=1
    rm -r "${checks_dir}"
    if [ -n "${QUOTABAR_TEST_PREFERENCES}" ]; then rm -r "${QUOTABAR_TEST_PREFERENCES}"; fi
    if [ -n "${sparkle}" ]; then rm -r "${sparkle}"; fi
    exit "${status}"
}
trap cleanup EXIT
# cfprefsd can read an absolute suite here even when the runner's per-user TMPDIR is sandboxed.
QUOTABAR_TEST_PREFERENCES=$(mktemp -d /private/tmp/quotabar-preferences.XXXXXX)
export QUOTABAR_TEST_PREFERENCES
compile() {
    xcrun swiftc -module-cache-path "${checks_dir}/modules" -swift-version 5 \
        -strict-concurrency=complete -warnings-as-errors -target "${target_arch}-apple-macosx14.0" -parse-as-library "$@"
}
compile -typecheck Sources/*.swift
compile_claude_usage() {
    compile Sources/ClaudeProfile.swift Sources/ProviderExecutable.swift Sources/ProviderProcess.swift Sources/QuotaCore.swift Sources/Presentation.swift Sources/ClaudeUsageClient.swift \
        Tests/TestPreferences.swift Tests/ClaudeUsageChecks.swift -o "${checks_dir}/claude-usage"
}
if [ "${1:-}" = "--claude-live" ]; then
    compile_claude_usage
    "${checks_dir}/claude-usage" --live
    exit 0
fi
if [ "${1:-}" = "--lint" ]; then
    sh -n sign-quotabar.sh
    sh -n build.sh
    sh -n check.sh
    sh -n package.sh
    sh -n fetch-sparkle.sh
    sh -n release-update.sh
    sh -n Tests/UpdaterChecks.sh
    if command -v shellcheck >/dev/null 2>&1; then
        shellcheck --enable=all -s sh sign-quotabar.sh build.sh check.sh package.sh fetch-sparkle.sh release-update.sh Tests/UpdaterChecks.sh
    else
        echo 'Warning: shellcheck is unavailable. Skipped shell script linting with shellcheck.' >&2
    fi
    plutil -lint Resources/Info.plist
    xcrun swift-format lint --strict --recursive Sources Helpers Tests
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
    compile "$@" Tests/TestPreferences.swift "${test_entry}" -o "${binary}"
}
offline_run() {
    mkdir -p "${checks_dir}/profile" "${checks_dir}/codex" "${checks_dir}/claude"
    HOME="${checks_dir}/profile" CFFIXED_USER_HOME="${checks_dir}/profile" CODEX_HOME="${checks_dir}/codex" \
        CLAUDE_CONFIG_DIR="${checks_dir}/claude" "$@"
}
logic_stress() {
    compile_app_check Tests/QuotaLogicChecks.swift "${checks_dir}/quota-logic"
    offline_run "${checks_dir}/quota-logic"
    compile Sources/PrivateFile.swift Sources/ClaudeProfile.swift Sources/ProviderExecutable.swift Sources/ProviderProcess.swift Sources/QuotaCore.swift Sources/Presentation.swift Sources/UsageResets.swift \
        Tests/ResetLogicStressChecks.swift -o "${checks_dir}/reset-logic"
    offline_run "${checks_dir}/reset-logic"
}
update_stress() {
    python3 Tests/PackagePublishingChecks.py
    python3 Tests/SparkleCacheChecks.py
    sparkle=$(./fetch-sparkle.sh)
    mkdir -p "${checks_dir}/Probe.app/Contents/MacOS"
    compile -F "${sparkle}" -framework Sparkle -Xlinker -rpath -Xlinker "${sparkle}" \
        Sources/Updater.swift Tests/UpdateStateChecks.swift -o "${checks_dir}/update-state"
    "${checks_dir}/update-state"
    compile -F "${sparkle}" -framework Sparkle -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
        Tests/UpdateFeedChecks.swift -o "${checks_dir}/Probe.app/Contents/MacOS/Probe"
    python3 Tests/UpdateProbeChecks.py "${checks_dir}" "${sparkle}"
    python3 Tests/LibraryConstraintChecks.py "${checks_dir}" "${sparkle}"
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
compile Sources/PrivateFile.swift Sources/ClaudeProfile.swift Sources/ClaudeSettingsDocument.swift Sources/ClaudeConnection.swift Helpers/ClaudeDisconnect.swift -o "${checks_dir}/QuotaBarClaudeDisconnect"
compile Sources/PrivateFile.swift Sources/ClaudeProfile.swift Sources/ClaudeSettingsDocument.swift Sources/ClaudeConnection.swift Tests/TestPreferences.swift Tests/ClaudeConnectionChecks.swift -o "${checks_dir}/claude-connection"
offline_run "${checks_dir}/claude-connection"
compile Sources/ClaudeProfile.swift Sources/ProviderExecutable.swift Sources/ProviderProcess.swift Sources/QuotaCore.swift Tests/CoreChecks.swift -o "${checks_dir}/core"
offline_run "${checks_dir}/core"
compile Sources/ClaudeProfile.swift Sources/ProviderExecutable.swift Sources/ProviderProcess.swift Sources/QuotaCore.swift Sources/Presentation.swift Tests/TestPreferences.swift Tests/PresentationChecks.swift -o "${checks_dir}/presentation"
offline_run "${checks_dir}/presentation"
compile Sources/NetworkChanges.swift Tests/NetworkSignalChecks.swift -o "${checks_dir}/network-signals"
offline_run "${checks_dir}/network-signals"
compile Sources/PrivateFile.swift Sources/ClaudeProfile.swift Sources/ProviderExecutable.swift Sources/ProviderProcess.swift Sources/QuotaCore.swift Sources/Presentation.swift Sources/UsageResets.swift Tests/ResetFlowChecks.swift -o "${checks_dir}/resets"
offline_run "${checks_dir}/resets"
compile Sources/PrivateFile.swift Sources/CodexHistoryCache.swift Sources/TokenPricing.swift Sources/TokenHistory.swift Tests/TokenPricingChecks.swift Tests/TokenChecks.swift -o "${checks_dir}/tokens"
offline_run "${checks_dir}/tokens"
compile Sources/PrivateFile.swift Sources/ClaudeProfile.swift Sources/ProviderExecutable.swift Sources/ProviderProcess.swift Sources/QuotaCore.swift Sources/ClaudeQuota.swift Tests/ClaudeQuotaChecks.swift -o "${checks_dir}/claude-quota"
offline_run "${checks_dir}/claude-quota"
compile_claude_usage
offline_run "${checks_dir}/claude-usage"
compile Sources/ClaudeProfile.swift Sources/ProviderExecutable.swift Sources/ProviderProcess.swift Sources/QuotaCore.swift Sources/Presentation.swift Sources/ClaudeUsageClient.swift \
    Tests/ProviderProcessChecks.swift -o "${checks_dir}/provider-process"
offline_run "${checks_dir}/provider-process"
compile Sources/PrivateFile.swift Sources/ClaudeProfile.swift Sources/CodexHistoryCache.swift Sources/TokenPricing.swift Sources/TokenHistory.swift Sources/ClaudeHistoryIndex.swift Sources/ClaudeTokenHistory.swift Tests/ClaudeTokenChecks.swift -o "${checks_dir}/claude-tokens"
offline_run "${checks_dir}/claude-tokens"
compile Sources/PrivateFile.swift Sources/ClaudeProfile.swift Sources/CodexHistoryCache.swift Sources/TokenPricing.swift Sources/TokenHistory.swift Sources/ClaudeHistoryIndex.swift Sources/ClaudeTokenHistory.swift \
    Tests/LiveTokenHistoryChecks.swift -o "${checks_dir}/live-token-history"
offline_run "${checks_dir}/live-token-history"
compile Sources/PrivateFile.swift Sources/ClaudeProfile.swift Sources/CodexHistoryCache.swift Sources/TokenPricing.swift Sources/TokenHistory.swift Sources/ClaudeHistoryIndex.swift Sources/ClaudeTokenHistory.swift \
    Tests/ClaudeHistoryMemoryChecks.swift -o "${checks_dir}/claude-history-memory"
offline_run "${checks_dir}/claude-history-memory"
if [ "${1:-}" = "--stress" ]; then
    logic_stress
    compile Sources/*.swift -o "${checks_dir}/QuotaBar"
    offline_run python3 Tests/ClaudeCaptureOrderChecks.py "${checks_dir}/QuotaBar"
    echo 'Exercising quota and token histories under load.'
    compile Sources/PrivateFile.swift Sources/ClaudeProfile.swift Sources/ProviderExecutable.swift Sources/ProviderProcess.swift Sources/QuotaCore.swift Sources/Presentation.swift Sources/ClaudeUsageClient.swift \
        Sources/CodexHistoryCache.swift Sources/TokenPricing.swift Sources/TokenHistory.swift Sources/ClaudeHistoryIndex.swift Sources/ClaudeTokenHistory.swift Tests/DataStressChecks.swift -o "${checks_dir}/data-stress"
    offline_run "${checks_dir}/data-stress"
    echo 'Racing reset confirmations from separate processes.'
    compile Sources/PrivateFile.swift Sources/ClaudeProfile.swift Sources/ProviderExecutable.swift Sources/ProviderProcess.swift Sources/QuotaCore.swift Sources/Presentation.swift Sources/UsageResets.swift \
        Tests/ResetContentionChecks.swift -o "${checks_dir}/reset-contention"
    offline_run "${checks_dir}/reset-contention"
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
