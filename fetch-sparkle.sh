#!/bin/sh
set -eu
version=2.10.1
checksum=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
cache=${QUOTABAR_SPARKLE_CACHE:-${TMPDIR:-/tmp}/quotabar-sparkle-${version}}
mkdir -p "${cache}"
cache=$(cd "${cache}" && pwd)
archive="${cache}/Sparkle-${version}.tar.xz"
temporary=
stage=
cleanup() {
    if [ -n "${temporary}" ]; then rm -f "${temporary}"; fi
    if [ -n "${stage}" ]; then rm -r "${stage}"; fi
}
trap cleanup EXIT HUP INT TERM
if [ ! -f "${archive}" ]; then
    temporary=$(mktemp "${cache}/.download.XXXXXX")
    curl --fail --location --proto '=https' --tlsv1.2 \
        "https://github.com/sparkle-project/Sparkle/releases/download/${version}/Sparkle-${version}.tar.xz" -o "${temporary}"
    printf '%s  %s\n' "${checksum}" "${temporary}" | shasum -a 256 -c - >&2
    mv "${temporary}" "${archive}"
    temporary=
fi
printf '%s  %s\n' "${checksum}" "${archive}" | shasum -a 256 -c - >&2
# Extract from the checked archive for each build so an edited cache cannot replace the framework.
stage=$(mktemp -d "${cache}/distribution.XXXXXX")
tar -xJf "${archive}" -C "${stage}"
codesign --verify --deep --strict "${stage}/Sparkle.framework"
trap - EXIT HUP INT TERM
printf '%s\n' "${stage}"
