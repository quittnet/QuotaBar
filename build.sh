#!/bin/sh
set -eu
cd "$(dirname "$0")"
target_arch=$(uname -m)
output_dir=${1:-build}
mkdir -p "${output_dir}"
output_dir=$(cd "${output_dir}" && pwd)
stage=$(mktemp -d "${output_dir}/.quotabar-build.XXXXXX")
sparkle=
trap 'rm -r "${stage}"; if [ -n "${sparkle}" ]; then rm -r "${sparkle}"; fi' EXIT
trap 'exit 1' HUP INT TERM
app="${stage}/QuotaBar.app"
mkdir -p "${app}/Contents/MacOS" "${app}/Contents/Helpers" "${app}/Contents/Resources/ProviderLogos"
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
while IFS= read -r file || [ -n "${file}" ]; do
    case "${file}" in
        Sources/*.swift) set -- "$@" "${file}" ;;
        *) ;;
    esac
done < release-files.txt
set -- "$@" -F "${sparkle}" -framework Sparkle -Xlinker -rpath -Xlinker '@executable_path/../Frameworks'
xcrun swiftc -swift-version 5 -module-cache-path "${stage}/modules" -O -parse-as-library \
    -target "${target_arch}-apple-macosx14.0" "$@" -o "${app}/Contents/MacOS/QuotaBar"
xcrun swiftc -swift-version 5 -module-cache-path "${stage}/modules" -O -parse-as-library \
    -target "${target_arch}-apple-macosx14.0" Sources/PrivateFile.swift Sources/ClaudeProfile.swift \
    Sources/ClaudeSettingsDocument.swift Sources/ClaudeConnection.swift Helpers/ClaudeDisconnect.swift \
    -o "${app}/Contents/Helpers/QuotaBarClaudeDisconnect"
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
./sign-quotabar.sh "${app}" "${stage}" "${sign_identity}"
python3 Helpers/PublishArchives.py bundle "${output_dir}" "${stage}"
