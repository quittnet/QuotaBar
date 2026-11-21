#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
root=$(mktemp -d "${TMPDIR:-/tmp}/quotabar-update-check.XXXXXX")
chmod 700 "${root}"
sparkle=$(./fetch-sparkle.sh)
server_pid=
cleanup() {
    if [ -f "${root}/pid" ]; then kill "$(cat "${root}/pid")" 2>/dev/null || true; fi
    if [ -n "${server_pid}" ]; then kill "${server_pid}" 2>/dev/null || true; fi
    rm -r "${root}" "${sparkle}"
}
trap cleanup EXIT HUP INT TERM
cat > "${root}/Keys.swift" <<'SWIFT'
import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
let root = URL(fileURLWithPath: CommandLine.arguments[1])
try key.rawRepresentation.base64EncodedData().write(to: root.appendingPathComponent("private"))
try key.publicKey.rawRepresentation.base64EncodedData().write(to: root.appendingPathComponent("public"))
SWIFT
xcrun swift -module-cache-path "${root}/modules" "${root}/Keys.swift" "${root}"
chmod 600 "${root}/private"
cat > "${root}/Main.swift" <<'SWIFT'
import AppKit
import Foundation
@main enum UpdateCheck {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let root = URL(fileURLWithPath: Bundle.main.infoDictionary!["QuotaBarTestRoot"] as! String)
        let build = Bundle.main.infoDictionary!["CFBundleVersion"] as! String
        try! Data(String(ProcessInfo.processInfo.processIdentifier).utf8).write(to: root.appendingPathComponent("pid"))
        try! Data(build.utf8).write(to: root.appendingPathComponent("launched-" + build))
        UpdateController.shared.start()
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("stress").path) {
            for enabled in [true, false, true, false] {
                UpdateController.shared.automaticallyChecksForUpdates = enabled
                precondition(UpdateController.shared.automaticallyChecksForUpdates == enabled)
            }
        }
        // checkForUpdates() does nothing until Sparkle can check. A helper left by the previous test app can
        // delay that, so retry once per second instead of relying on a single request after launch.
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard UpdateController.shared.canCheckForUpdates else { return }
                timer.invalidate()
                UpdateController.shared.checkForUpdates()
            }
        }
        app.run()
    }
}
SWIFT
mkdir -p "${root}/feed" "${root}/installed"
if [ "${QUOTABAR_STRESS:-0}" = 1 ]; then touch "${root}/stress"; fi
python3 -u - "${root}" <<'PY' > "${root}/http.log" 2>&1 &
import http.server, pathlib, sys
root=pathlib.Path(sys.argv[1])
handler=lambda *args,**kwargs: http.server.SimpleHTTPRequestHandler(*args,directory=str(root/'feed'),**kwargs)
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),handler)
(root/'port').write_text(str(server.server_address[1]))
server.serve_forever()
PY
server_pid=$!
for _ in $(seq 1 50); do
    [ ! -f "${root}/port" ] || break
    sleep 0.1
done
test -f "${root}/port"
port=$(cat "${root}/port")
xcrun swiftc -module-cache-path "${root}/modules" -parse-as-library \
    -F "${sparkle}" -framework Sparkle -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
    Sources/Updater.swift "${root}/Main.swift" -o "${root}/QuotaBarUpdateCheck"
for build in 1 2; do
    app="${root}/build-${build}/QuotaBar Update Check.app"
    mkdir -p "${app}/Contents/MacOS" "${app}/Contents/Frameworks"
    cp "${root}/QuotaBarUpdateCheck" "${app}/Contents/MacOS/QuotaBarUpdateCheck"
    ditto --noextattr --norsrc "${sparkle}/Sparkle.framework" "${app}/Contents/Frameworks/Sparkle.framework"
    python3 - "${app}/Contents/Info.plist" "${root}" "${build}" "${port}" <<'PY'
import plistlib,sys,pathlib
path,root,build,port=sys.argv[1:]
info=dict(SUDefaultsDomain=str(pathlib.Path(root, 'sparkle-preferences')),CFBundleIdentifier='app.quotabar.update-check',CFBundleName='QuotaBar Update Check',CFBundleExecutable='QuotaBarUpdateCheck',CFBundleVersion=build,CFBundleShortVersionString='0.0.'+build,CFBundlePackageType='APPL',LSMinimumSystemVersion='14.0',QuotaBarTestRoot=root,SUPublicEDKey=pathlib.Path(root,'public').read_text(),SUFeedURL=f'http://127.0.0.1:{port}/appcast.xml',SUEnableAutomaticChecks=False,SUAutomaticallyUpdate=False,SUVerifyUpdateBeforeExtraction=True,SURequireSignedFeed=True,SUSignedFeedFailureExpirationInterval=0,NSAppTransportSecurity={'NSAllowsLocalNetworking':True,'NSAllowsArbitraryLoads':True})
with open(path,'wb') as file: plistlib.dump(info,file)
PY
    ./sign-quotabar.sh "${app}" "${root}" -
done
ditto -c -k --norsrc --keepParent "${root}/build-2/QuotaBar Update Check.app" "${root}/feed/QuotaBar-macOS.zip"
signature=$("${sparkle}/bin/sign_update" --ed-key-file "${root}/private" -p "${root}/feed/QuotaBar-macOS.zip")
python3 - "${root}" "${port}" "${signature}" <<'PY'
import pathlib,sys
root=pathlib.Path(sys.argv[1]); port,sig=sys.argv[2:]
(root/'feed/appcast.xml').write_text(f'''<?xml version="1.0" encoding="utf-8"?><rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>QuotaBar Test</title><item><title>Test Update</title><sparkle:version>2</sparkle:version><sparkle:shortVersionString>0.0.2</sparkle:shortVersionString><sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion><enclosure url="http://127.0.0.1:{port}/QuotaBar-macOS.zip" sparkle:edSignature="{sig}" length="{(root/'feed/QuotaBar-macOS.zip').stat().st_size}" type="application/octet-stream" /></item></channel></rss>''')
PY
"${sparkle}/bin/sign_update" --ed-key-file "${root}/private" "${root}/feed/appcast.xml"
ui() {
    pid=$(cat "${root}/pid") || return 1
    osascript - "${pid}" "$1" <<'APPLESCRIPT'
on run argv
    tell application "System Events"
        tell first application process whose unix id is (item 1 of argv as integer)
            if item 2 of argv is "read" then return value of every static text of window 1
            click button (item 2 of argv) of window 1
        end tell
    end tell
end run
APPLESCRIPT
}
# Sparkle can replace or close its window between steps, so retry a click briefly before failing.
click() {
    for _ in $(seq 1 50); do
        # shellcheck disable=SC2310
        if ui "$1" >/dev/null 2>&1; then return; fi
        sleep 0.2
    done
    ui "$1"
}
wait_for() {
    expected=$1
    for _ in $(seq 1 100); do
        # A missing window is expected while Sparkle prepares its UI. Both ui commands return errors explicitly.
        # shellcheck disable=SC2310
        window_text=$(ui read 2>/dev/null) || window_text=
        if printf '%s\n' "${window_text}" | grep -Eiq "${expected}"; then return; fi
        sleep 0.2
    done
    ui read
    echo "Timed out waiting for ${expected}" >&2
    exit 1
}
launch_old() {
    if [ -f "${root}/pid" ]; then
        kill "$(cat "${root}/pid")" 2>/dev/null || true
        sleep 1
    fi
    if [ -d "${root}/installed/QuotaBar Update Check.app" ]; then
        mv "${root}/installed/QuotaBar Update Check.app" "${root}/previous-${1}.app"
    fi
    ditto --norsrc "${root}/build-1/QuotaBar Update Check.app" "${root}/installed/QuotaBar Update Check.app"
    mkdir -p "${root}/profile"
    open -n --env "CFFIXED_USER_HOME=${root}/profile" --env "HOME=${root}/profile" "${root}/installed/QuotaBar Update Check.app"
    wait_for "${2:-new version}"
}
assert_installed_build() {
    actual=$(plutil -extract CFBundleVersion raw "${root}/installed/QuotaBar Update Check.app/Contents/Info.plist")
    test "${actual}" = "$1"
}
launch_old valid
click 'Install Update'
wait_for 'Ready to Install'
click 'Install and Relaunch'
for _ in $(seq 1 100); do
    [ ! -f "${root}/launched-2" ] || break
    sleep 0.2
done
relaunched=$(cat "${root}/launched-2")
test "${relaunched}" = 2
assert_installed_build 2
printf 'Signed update installed and relaunched build 2.\n'
if [ "${QUOTABAR_STRESS:-0}" = 1 ]; then
    wait_for 'up to date|latest version|newest version'
    mv "${root}/feed/appcast.xml" "${root}/saved-feed.xml"
    launch_old missing-feed 'Update Error|error occurred'
    assert_installed_build 1
    mv "${root}/saved-feed.xml" "${root}/feed/appcast.xml"
    launch_old restored-feed
    printf 'Current build reported up to date. A missing feed surfaced an error; restoring the signed feed offered the update again.\n'
fi
printf 'tampered' >> "${root}/feed/QuotaBar-macOS.zip"
launch_old tampered
click 'Install Update'
wait_for 'improperly signed'
assert_installed_build 1
printf 'Tampered update rejected, installed build remained 1.\n'
# Dismissing the rejection is cleanup only; the next launch replaces this process either way.
# shellcheck disable=SC2310
click 'Cancel Update' || printf 'The rejection window closed before Cancel Update; continuing with a fresh launch.\n'
python3 - "${root}/feed/appcast.xml" <<'PYCODE'
from pathlib import Path
import sys
feed = Path(sys.argv[1])
feed.write_text(feed.read_text().replace('Test Update', 'Tampered Update'))
PYCODE
launch_old invalid-feed 'Update Error'
assert_installed_build 1
window_text=$(ui read)
if printf '%s\n' "${window_text}" | grep -q 'new version'; then exit 1; fi
printf 'Tampered signed feed rejected before offering an update.\n'
