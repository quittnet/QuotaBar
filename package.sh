#!/bin/sh
set -eu
cd "$(dirname "$0")"
output_dir=${1:-release}
mkdir -p "${output_dir}"
output_dir=$(cd "${output_dir}" && pwd)
stage=$(mktemp -d "${output_dir}/.quotabar-package.XXXXXX")
trap 'rm -r "${stage}"' EXIT HUP INT TERM
mkdir -p "${stage}/source/QuotaBar"
while IFS= read -r file; do
    case "${file}" in
        /*|../*|*/../*|*/..) echo "Invalid release path" >&2; exit 1 ;;
        *) ;;
    esac
    parent=$(dirname "${file}")
    while [ "${parent}" != "." ]; do
        if [ -L "${parent}" ]; then
            printf 'Symbolic release directory: %s\n' "${parent}" >&2
            exit 1
        fi
        parent=$(dirname "${parent}")
    done
    if [ ! -f "${file}" ] || [ -L "${file}" ]; then
        printf 'Missing or symbolic release file: %s\n' "${file}" >&2
        exit 1
    fi
    mkdir -p "${stage}/source/QuotaBar/$(dirname "${file}")"
    cp -X "${file}" "${stage}/source/QuotaBar/${file}"
done < release-files.txt
"${stage}/source/QuotaBar/check.sh"
"${stage}/source/QuotaBar/build.sh" "${stage}/app"
(cd "${stage}/app" && zip -X -q -r "${stage}/QuotaBar-macOS.zip" QuotaBar.app)
(cd "${stage}/source" && zip -X -q -r "${stage}/QuotaBar-source.zip" QuotaBar)
unzip -t -q "${stage}/QuotaBar-macOS.zip"
unzip -t -q "${stage}/QuotaBar-source.zip"
mv "${stage}/QuotaBar-macOS.zip" "${output_dir}/QuotaBar-macOS.zip"
mv "${stage}/QuotaBar-source.zip" "${output_dir}/QuotaBar-source.zip"
printf 'Release archives saved in %s\n' "${output_dir}"
