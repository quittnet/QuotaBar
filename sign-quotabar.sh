#!/bin/sh
# Sign nested Sparkle components first so their final code-directory hash can be sealed into the host.
set -eu
app=${1:?application bundle required}
scratch=${2:?private working directory required}
sign_identity=${3:--}
framework="${app}/Contents/Frameworks/Sparkle.framework"
version="${framework}/Versions/B"
if [ "${sign_identity}" = - ]; then
    timestamp=--timestamp=none
else
    timestamp=--timestamp
fi
helper="${app}/Contents/Helpers/QuotaBarClaudeDisconnect"
if [ -f "${helper}" ]; then
    codesign --force --sign "${sign_identity}" --options runtime "${timestamp}" "${helper}"
fi
for nested in "${version}/XPCServices/Downloader.xpc" "${version}/XPCServices/Installer.xpc" \
    "${version}/Autoupdate" "${version}/Updater.app" "${framework}"; do
    codesign --force --sign "${sign_identity}" --options runtime "${timestamp}" "${nested}"
done

set --
if [ "${sign_identity}" = - ]; then
    # Without a Team ID the ordinary hardened library policy rejects embedded frameworks.
    # macOS 14+ checks this signed constraint for every non-system library loaded by the host.
    arch=$(uname -m)
    python3 - "${framework}" "${scratch}" "${arch}" <<'PY'
import pathlib, plistlib, re, subprocess, sys
framework, scratch = sys.argv[1], pathlib.Path(sys.argv[2])
signature = subprocess.run(
    ["codesign", "--display", "--verbose=4", "--arch", sys.argv[3], framework],
    stderr=subprocess.PIPE, text=True, check=True,
)
match = re.search(r"^CDHash=([a-fA-F0-9]{40})$", signature.stderr, re.MULTILINE)
if match is None:
    raise SystemExit("Could not identify the signed native Sparkle code directory")
(scratch / "library-constraint.plist").write_bytes(plistlib.dumps({"cdhash": bytes.fromhex(match[1])}))
(scratch / "host.entitlements").write_bytes(plistlib.dumps({"com.apple.security.cs.disable-library-validation": True}))
PY
    codesign --validate-constraint "${scratch}/library-constraint.plist"
    set -- --entitlements "${scratch}/host.entitlements" --library-constraint "${scratch}/library-constraint.plist"
fi
codesign --force --sign "${sign_identity}" --options runtime "${timestamp}" "$@" "${app}"
codesign --verify --deep --strict "${app}"
