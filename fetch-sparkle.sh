#!/bin/sh
set -eu
umask 077
version=2.10.1
checksum=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
stage=$(mktemp -d /private/tmp/quotabar-sparkle-dist.XXXXXX)
temporary=
cleanup() {
    if [ -n "${temporary}" ]; then rm -f "${temporary}"; fi
    if [ -n "${stage}" ]; then rm -r "${stage}"; fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
uid=$(id -u)
user_temp=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null) || user_temp=
# Sandboxed builders may have no per-user temp path, or TMPDIR may point to shared /tmp.
# In either case retain the archive only for this invocation unless a private cache was specified.
default_cache="${stage}/cache"
if [ -d "${user_temp}" ]; then
    access=$(stat -Lf '%u:%OLp' "${user_temp}") || access=
    if [ "${access}" = "${uid}:700" ]; then default_cache="${user_temp%/}/quotabar-sparkle-${version}"; fi
fi
cache=${QUOTABAR_SPARKLE_CACHE:-${default_cache}}
mkdir -p "${cache}"
if [ -L "${cache}" ] || [ ! -d "${cache}" ]; then
    echo 'Sparkle cache must be a real directory.' >&2
    exit 1
fi
cd -P "${cache}"
owner=$(stat -f %u .)
if [ "${owner}" != "${uid}" ]; then
    echo 'Sparkle cache must be owned by the current user.' >&2
    exit 1
fi
# Older versions created this one application-owned directory with the caller's umask.
if [ "${cache}" = "${default_cache}" ]; then chmod 700 .; fi
mode=$(stat -f %OLp .)
if [ "${mode}" != 700 ]; then
    echo 'Sparkle cache must have permissions 0700.' >&2
    exit 1
fi
archive="Sparkle-${version}.tar.xz"
snapshot="${stage}/${archive}"
if [ -L "${archive}" ] || { [ -e "${archive}" ] && [ ! -f "${archive}" ]; }; then
    echo 'Expected a regular cached Sparkle archive.' >&2
    exit 1
fi
manifest="${stage}/archive.sha256"
printf '%s  %s\n' "${checksum}" "${snapshot}" > "${manifest}"
# Verify the private snapshot used for extraction. A damaged cache can be repaired
# only with a download that passes the same pinned checksum.
if [ ! -f "${archive}" ] || ! cp -X "${archive}" "${snapshot}" || ! shasum -a 256 -c "${manifest}" >&2; then
    curl --fail --location --proto '=https' --tlsv1.2 \
        "https://github.com/sparkle-project/Sparkle/releases/download/${version}/${archive}" -o "${snapshot}"
    shasum -a 256 -c "${manifest}" >&2
    temporary=$(mktemp .archive.XXXXXX)
    cp -X "${snapshot}" "${temporary}"
    mv -f "${temporary}" "${archive}"
    temporary=
fi
# Keep normal distribution modes inside the private directory for the packaged app.
(umask 022 && tar -xJf "${snapshot}" -C "${stage}")
rm "${snapshot}" "${manifest}"
codesign --verify --deep --strict "${stage}/Sparkle.framework"
printf '%s\n' "${stage}"
stage=
