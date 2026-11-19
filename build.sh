#!/bin/sh
set -eu
cd "$(dirname "$0")"
target_arch=$(uname -m)
output_dir=${1:-build}
mkdir -p "${output_dir}"
output_dir=$(cd "${output_dir}" && pwd)
stage=$(mktemp -d "${output_dir}/.quotabar-build.XXXXXX")
trap 'rm -r "${stage}"' EXIT HUP INT TERM
app="${stage}/QuotaBar.app"
mkdir -p "${app}/Contents/MacOS" "${app}/Contents/Resources/ProviderLogos"
set --
while IFS= read -r file; do
    case "${file}" in
        Sources/*.swift) set -- "$@" "${file}" ;;
        *) ;;
    esac
done < release-files.txt
xcrun swiftc -swift-version 5 -module-cache-path "${TMPDIR:-/tmp}/quotabar-build-modules" -O -parse-as-library \
    -target "${target_arch}-apple-macosx14.0" "$@" -o "${app}/Contents/MacOS/QuotaBar"
cp -X Resources/Info.plist "${app}/Contents/Info.plist"
cp -X Resources/AppIcon.icns "${app}/Contents/Resources/AppIcon.icns"
cp -X Resources/ProviderLogos/OpenAI.png Resources/ProviderLogos/Claude.png "${app}/Contents/Resources/ProviderLogos/"
codesign --force --sign - --options runtime --timestamp=none --identifier app.quotabar.QuotaBar "${app}"
codesign --verify --strict "${app}"
destination="${output_dir}/QuotaBar.app"
if [ -e "${destination}" ] || [ -L "${destination}" ]; then
    backup=$(mktemp -d "${output_dir}/QuotaBar-previous.XXXXXX")
    mv "${destination}" "${backup}/QuotaBar.app"
    printf 'Previous bundle preserved at %s\n' "${backup}/QuotaBar.app"
fi
mv "${app}" "${destination}"
