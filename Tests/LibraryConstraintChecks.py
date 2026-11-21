"""Exercise the release signer's ad-hoc library constraint with disposable native hosts.

The rejection case loads the framework with dlopen so the probe reports the refusal and exits normally.
A launch-time rejection would also be valid evidence, but macOS records every one as a crash report.
"""

import pathlib
import plistlib
import re
import subprocess
import sys

DLOPEN_HOST = r"""#include <dlfcn.h>
#include <stdio.h>
int main(void) {
    void *handle = dlopen("@rpath/Sparkle.framework/Versions/B/Sparkle", RTLD_NOW);
    if (handle) { fputs("LOADED", stdout); return 0; }
    printf("REJECTED %s", dlerror());
    return 0;
}
"""
LINKED_HOST = '#include <unistd.h>\nint main(void) { return write(1, "MAIN", 4) == 4 ? 0 : 1; }\n'


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def cdhash(framework):
    info = subprocess.run(
        ["codesign", "--display", "--verbose=4", "--arch", run("uname", "-m").strip(), framework],
        check=True, capture_output=True, text=True,
    )
    return re.search(r"^CDHash=([0-9a-f]{40})$", info.stderr, re.MULTILINE)[1]


def make_app(scratch, sparkle, name, source, linked):
    app = scratch / f"{name}.app"
    contents = app / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    (contents / "Frameworks").mkdir()
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": f"test.quotabar.loader-constraint.{name.lower()}",
        "CFBundleExecutable": name, "CFBundlePackageType": "APPL",
    }))
    run("ditto", "--noextattr", "--norsrc", sparkle / "Sparkle.framework", contents / "Frameworks/Sparkle.framework")
    code = scratch / f"{name}.c"
    code.write_text(source)
    binary = contents / "MacOS" / name
    link = ["-F", sparkle, "-Wl,-needed_framework,Sparkle"] if linked else []
    run("xcrun", "clang", code, "-o", binary, *link, "-Wl,-rpath,@executable_path/../Frameworks")
    if linked:
        assert "@rpath/Sparkle.framework" in run("otool", "-L", binary)
    return app, binary


def main(root, sparkle):
    scratch = root / "loader-constraint"
    scratch.mkdir()
    signer = pathlib.Path(__file__).resolve().parents[1] / "sign-quotabar.sh"

    # Like QuotaBar, this host links Sparkle at launch. The production signer must leave it launchable.
    linked_app, linked = make_app(scratch, sparkle, "LinkedProbe", LINKED_HOST, linked=True)
    (scratch / "linked-signing").mkdir()
    run(signer, linked_app, scratch / "linked-signing", "-")
    assert run(linked) == "MAIN"
    print("Native loader: a host linked to the pinned framework reached main.", flush=True)

    app, probe = make_app(scratch, sparkle, "ConstraintProbe", DLOPEN_HOST, linked=False)
    (scratch / "probe-signing").mkdir()
    run(signer, app, scratch / "probe-signing", "-")
    framework = app / "Contents/Frameworks/Sparkle.framework"
    original = cdhash(framework)
    assert run(probe) == "LOADED"

    # Change only this disposable framework's identity. Keep its Mach-O payload loadable and signed.
    plist = framework / "Resources/Info.plist"
    info = plistlib.loads(plist.read_bytes())
    info["CFBundleIdentifier"] += ".fixture"
    plist.write_bytes(plistlib.dumps(info))
    run("codesign", "--force", "--sign", "-", "--options", "runtime", "--timestamp=none", framework)
    run("codesign", "--verify", "--deep", "--strict", framework)
    changed = cdhash(framework)
    assert changed != original
    rejected = subprocess.run([probe], capture_output=True, text=True, timeout=15)
    # dyld on some macOS releases spells "constraint" as "contraint" in its rejection message.
    denial = rejected.stdout.lower()
    if (rejected.returncode != 0 or not denial.startswith("rejected ") or "sparkle.framework" not in denial
            or not re.search(r"library load cons?traint", denial)):
        raise RuntimeError(f"Expected dyld to refuse the re-signed framework under the library constraint: {rejected!r}")

    # A newly pinned host accepts the very same replacement, ruling out a broken test framework.
    run(signer, app, scratch / "probe-signing", "-")
    assert cdhash(framework) == changed and run(probe) == "LOADED"
    print("Native loader: a different valid CDHash was refused under the library load constraint; "
          "re-pinning that hash loaded it.")


if __name__ == "__main__":
    main(*(pathlib.Path(arg) for arg in sys.argv[1:]))
