#!/bin/sh
set -eu
cd "$(dirname "$0")"
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
    -) ;;
    'Developer ID Application: '*)
        : "${QUOTABAR_NOTARY_PROFILE:?Set the notarytool Keychain profile}"
        ;;
    *) echo 'Use ad-hoc signing or a Developer ID Application identity.' >&2; exit 1 ;;
esac
export QUOTABAR_SIGN_IDENTITY="${sign_identity}"
export QUOTABAR_UPDATE_PUBLIC_KEY="${update_key}"
architecture=$(uname -m)
if [ "${architecture}" != arm64 ]; then
    echo 'Update releases currently require an Apple Silicon build machine.' >&2
    exit 1
fi
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
build=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Resources/Info.plist)
case "${version}" in
    ''|*[!0-9.]*) echo 'Use a numeric release version.' >&2; exit 1 ;;
    *) ;;
esac
output_dir=${1:-"release-updates/v${version}"}
mkdir -p "${output_dir}"
output_dir=$(cd "${output_dir}" && pwd)
for name in QuotaBar-macOS.zip appcast.xml SHA256SUMS.txt; do
    if [ -e "${output_dir}/${name}" ] || [ -L "${output_dir}/${name}" ]; then
        printf 'Release output already exists: %s\n' "${name}" >&2
        exit 1
    fi
done
stage=
sparkle=$(./fetch-sparkle.sh)
cleanup() {
    if [ -n "${stage}" ]; then rm -r "${stage}"; fi
    rm -r "${sparkle}"
}
trap cleanup EXIT HUP INT TERM
account=${QUOTABAR_UPDATE_KEY_ACCOUNT:-quotabar-updates}
public_key=$("${sparkle}/bin/generate_keys" --account "${account}" -p)
if [ "${public_key}" != "${QUOTABAR_UPDATE_PUBLIC_KEY}" ]; then
    echo 'The existing Sparkle Keychain key does not match the configured public key.' >&2
    exit 1
fi
./check.sh
stage=$(mktemp -d "${output_dir}/.quotabar-update.XXXXXX")
./build.sh "${stage}/build"
app="${stage}/build/QuotaBar.app"
embedded_key=$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "${app}/Contents/Info.plist")
if [ "${embedded_key}" != "${public_key}" ]; then
    echo 'The app embeds a different update key.' >&2
    exit 1
fi
codesign --verify --deep --strict "${app}"
if [ "${sign_identity}" != - ]; then
    /usr/bin/ditto -c -k --norsrc --keepParent "${app}" "${stage}/notarization.zip"
    xcrun notarytool submit "${stage}/notarization.zip" --keychain-profile "${QUOTABAR_NOTARY_PROFILE}" \
        --wait --output-format plist > "${stage}/notarization.plist"
    status=$(/usr/libexec/PlistBuddy -c 'Print status' "${stage}/notarization.plist")
    if [ "${status}" != Accepted ]; then
        echo 'Apple did not accept this build for notarization.' >&2
        exit 1
    fi
    xcrun stapler staple "${app}"
    xcrun stapler validate "${app}"
    codesign --verify --deep --strict "${app}"
    spctl --assess --type execute "${app}"
fi
mkdir "${stage}/updates"
archive="${stage}/updates/QuotaBar-macOS.zip"
/usr/bin/ditto -c -k --norsrc --keepParent "${app}" "${archive}"
mkdir "${stage}/verified"
/usr/bin/ditto -x -k "${archive}" "${stage}/verified"
verified_app="${stage}/verified/QuotaBar.app"
codesign --verify --deep --strict "${verified_app}"
if [ "${sign_identity}" != - ]; then
    xcrun stapler validate "${verified_app}"
    spctl --assess --type execute "${verified_app}"
fi
"${sparkle}/bin/generate_appcast" --account "${account}" --maximum-deltas 0 \
    --download-url-prefix "https://github.com/quittnet/QuotaBar/releases/download/v${version}/" \
    -o "${stage}/updates/appcast.xml" "${stage}/updates"
feed="${stage}/updates/appcast.xml"
signature=$(/usr/bin/xmllint --nonet --xpath 'string(//*[local-name()="enclosure"]/@*[local-name()="edSignature"])' "${feed}")
if [ -z "${signature}" ]; then
    echo 'The generated appcast has no archive signature.' >&2
    exit 1
fi
"${sparkle}/bin/sign_update" --account "${account}" --verify "${archive}" "${signature}"
"${sparkle}/bin/sign_update" --account "${account}" --verify "${feed}"
feed_version=$(/usr/bin/xmllint --nonet --xpath 'string(//*[local-name()="item"]/*[local-name()="version"])' "${feed}")
feed_url=$(/usr/bin/xmllint --nonet --xpath 'string(//*[local-name()="enclosure"]/@url)' "${feed}")
if [ "${feed_version}" != "${build}" ] || \
    [ "${feed_url}" != "https://github.com/quittnet/QuotaBar/releases/download/v${version}/QuotaBar-macOS.zip" ]; then
    echo 'The appcast version or download URL does not match this build.' >&2
    exit 1
fi
(cd "${stage}/updates" && shasum -a 256 QuotaBar-macOS.zip appcast.xml > SHA256SUMS.txt)
for name in QuotaBar-macOS.zip appcast.xml SHA256SUMS.txt; do
    mv "${stage}/updates/${name}" "${output_dir}/${name}"
done
printf 'Verified signed update artifacts saved in %s\n' "${output_dir}"
