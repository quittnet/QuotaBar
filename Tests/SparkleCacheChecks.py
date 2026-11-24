"""Test interruption recovery with a private cache, a pinned local fixture and no network."""
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile


def main(root):
    source = Path(__file__).resolve().parents[1] / "fetch-sparkle.sh"
    archive = root / "distribution.tar.xz"
    tool = root / "fixture-tool"
    subprocess.run(["xcrun", "clang", "-x", "c", "-", "-o", tool],
                   input="int main(void) { return 0; }", text=True, check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", tool], check=True)
    with tarfile.open(archive, "w:xz") as bundle:
        bundle.add(tool, arcname="Sparkle.framework")
    contents = source.read_text()
    pin = hashlib.sha256(archive.read_bytes()).hexdigest()
    contents, replacements = re.subn(r"^checksum=[0-9a-f]{64}$", "checksum=" + pin, contents, flags=re.M)
    assert replacements == 1
    fixture = root / "fetch.sh"
    fixture.write_text(contents)
    version = re.search(r"^version=(.+)$", contents, re.M)[1]
    cache = root / "cache"
    cache.mkdir(mode=0o700)
    stored = cache / f"Sparkle-{version}.tar.xz"
    commands = root / "commands"
    commands.mkdir()
    curl = commands / "curl"
    curl.write_text('#!/bin/sh\nset -eu\necho request >> "$REQUEST_LOG"\n'
                    'while [ "$#" -gt 1 ]; do\n'
                    '    if [ "$1" = "-o" ]; then cp "$LOCAL_DOWNLOAD" "$2"; exit; fi\n'
                    '    shift\ndone\nexit 64\n')
    getconf = commands / "getconf"
    getconf.write_text('#!/bin/sh\nprintf "%s\\n" "$MISSING_USER_TEMP"\n')
    for command in (curl, getconf):
        command.chmod(0o700)
    requests = root / "requests"
    env = dict(os.environ, PATH=f"{commands}:/usr/bin:/bin:/usr/sbin:/sbin", QUOTABAR_SPARKLE_CACHE=str(cache),
               REQUEST_LOG=str(requests), MISSING_USER_TEMP=str(root / "previously-removed-temp"))

    def fetch(download, success, count):
        requests.write_text("")
        result = subprocess.run(["/bin/sh", fixture], env=dict(env, LOCAL_DOWNLOAD=str(download)),
                                capture_output=True, text=True)
        if result.returncode == 0:
            stage = Path(result.stdout.strip()).resolve()
            assert stage.parent == Path("/private/tmp") and stage.name.startswith("quotabar-sparkle-dist.")
            try:
                assert (stage / "Sparkle.framework").is_file()
            finally:
                shutil.rmtree(stage)
        assert (result.returncode == 0) == success, result.stderr
        assert len(requests.read_text().splitlines()) == count

    fetch(archive, True, 1)
    fetch(archive, True, 0)
    stored.write_bytes(b"incomplete cached download")
    short = root / "short"
    short.write_bytes(b"incomplete remote download")
    fetch(short, False, 1)
    assert stored.read_bytes() == b"incomplete cached download"
    fetch(archive, True, 1)
    fetch(archive, True, 0)
    assert stored.read_bytes() == archive.read_bytes()
    assert not list(cache.glob(".archive.*"))
    print("Sparkle cache recovery passed for cold, warm, failed and repaired downloads with a missing user temp.")


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="quotabar-cache-check-") as tmp:
        main(Path(tmp))
