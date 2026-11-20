#!/bin/sh
set -eu
cd "$(dirname "$0")"
target_arch=$(uname -m)
output_dir=${1:-build}
mkdir -p "${output_dir}"
output_dir=$(cd "${output_dir}" && pwd)
stage=$(mktemp -d "${output_dir}/.quotabar-build.XXXXXX")
sparkle=
trap 'rm -r "${stage}"; if [ -n "${sparkle}" ]; then rm -r "${sparkle}"; fi' EXIT HUP INT TERM
app="${stage}/QuotaBar.app"
mkdir -p "${app}/Contents/MacOS" "${app}/Contents/Resources/ProviderLogos"
sign_identity=${QUOTABAR_SIGN_IDENTITY:--}
update_key=${QUOTABAR_UPDATE_PUBLIC_KEY:-}
if [ -z "${update_key}" ] && [ -f Resources/UpdatePublicKey.txt ]; then
    update_key=$(cat Resources/UpdatePublicKey.txt)
fi
if [ -z "${update_key}" ]; then
    echo 'Set QUOTABAR_UPDATE_PUBLIC_KEY or add Resources/UpdatePublicKey.txt.' >&2
    exit 1
fi
case "${sign_identity}" in
    -|'Developer ID Application: '*) ;;
    *) echo 'Use ad-hoc signing or a Developer ID Application identity.' >&2; exit 1 ;;
esac
key_bytes=$(printf '%s' "${update_key}" | base64 -D | wc -c | tr -d ' ')
if [ "${key_bytes}" != 32 ]; then
    echo 'The update public key must encode exactly 32 bytes.' >&2
    exit 1
fi
sparkle=$(./fetch-sparkle.sh)
set --
while IFS= read -r file; do
    case "${file}" in
        Sources/*.swift) set -- "$@" "${file}" ;;
        *) ;;
    esac
done < release-files.txt
set -- "$@" -F "${sparkle}" -framework Sparkle -Xlinker -rpath -Xlinker '@executable_path/../Frameworks'
xcrun swiftc -swift-version 5 -module-cache-path "${TMPDIR:-/tmp}/quotabar-build-modules" -O -parse-as-library \
    -target "${target_arch}-apple-macosx14.0" "$@" -o "${app}/Contents/MacOS/QuotaBar"
cp -X Resources/Info.plist "${app}/Contents/Info.plist"
cp -X Resources/AppIcon.icns "${app}/Contents/Resources/AppIcon.icns"
cp -X Resources/ProviderLogos/OpenAI.png Resources/ProviderLogos/Claude.png "${app}/Contents/Resources/ProviderLogos/"
mkdir -p "${app}/Contents/Frameworks"
ditto --noextattr --norsrc "${sparkle}/Sparkle.framework" "${app}/Contents/Frameworks/Sparkle.framework"
cp -X "${sparkle}/LICENSE" "${app}/Contents/Resources/Sparkle-LICENSE.txt"
plist="${app}/Contents/Info.plist"
plutil -insert SUPublicEDKey -string "${update_key}" "${plist}"
plutil -insert SUFeedURL -string 'https://github.com/quittnet/QuotaBar/releases/latest/download/appcast.xml' "${plist}"
plutil -insert SUEnableAutomaticChecks -bool NO "${plist}"
plutil -insert SUAutomaticallyUpdate -bool NO "${plist}"
plutil -insert SUVerifyUpdateBeforeExtraction -bool YES "${plist}"
plutil -insert SURequireSignedFeed -bool YES "${plist}"
plutil -insert SUSignedFeedFailureExpirationInterval -integer 0 "${plist}"
framework="${app}/Contents/Frameworks/Sparkle.framework/Versions/B"
if [ "${sign_identity}" = - ]; then
    timestamp=--timestamp=none
else
    timestamp=--timestamp
fi
for nested in "${framework}/XPCServices/Downloader.xpc" "${framework}/XPCServices/Installer.xpc" \
    "${framework}/Autoupdate" "${framework}/Updater.app" "${app}/Contents/Frameworks/Sparkle.framework"; do
    codesign --force --sign "${sign_identity}" --options runtime "${timestamp}" "${nested}"
done
if [ "${sign_identity}" = - ]; then
    entitlements="${stage}/host.entitlements"
    cat > "${entitlements}" <<'ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.cs.disable-library-validation</key><true/>
</dict></plist>
ENTITLEMENTS
    codesign --force --sign - --options runtime --timestamp=none --entitlements "${entitlements}" \
        --identifier app.quotabar.QuotaBar "${app}"
else
    codesign --force --sign "${sign_identity}" --options runtime --timestamp \
        --identifier app.quotabar.QuotaBar "${app}"
fi
codesign --verify --deep --strict "${app}"
destination="${output_dir}/QuotaBar.app"
if [ -e "${destination}" ] || [ -L "${destination}" ]; then
    backup=$(mktemp -d "${output_dir}/QuotaBar-previous.XXXXXX")
    mv "${destination}" "${backup}/QuotaBar.app"
    printf 'Previous bundle preserved at %s\n' "${backup}/QuotaBar.app"
fi
mv "${app}" "${destination}"
