"""Check the names of real preferences without opening or deleting any plist."""

import json
import os
import pathlib
import pwd
import sys


def main():
    action, snapshot = sys.argv[1:]
    # HOME and CFFIXED_USER_HOME may point to an offline fixture.
    directory = pathlib.Path(pwd.getpwuid(os.getuid()).pw_dir, "Library", "Preferences")
    try:
        names = {name for name in os.listdir(directory) if name.startswith(("QuotaBar", "app.quotabar."))}
    except FileNotFoundError:
        names = set()
    snapshot = pathlib.Path(snapshot)
    if action == "snapshot":
        snapshot.write_text(json.dumps(sorted(names)))
    elif action == "verify":
        added = names.difference(json.loads(snapshot.read_text()))
        if added:
            print("New real preference domains appeared:", file=sys.stderr)
            for name in sorted(added):
                print(directory / name, file=sys.stderr)
            sys.exit(1)
        print("Preference isolation passed: no new QuotaBar* or app.quotabar.* domains.")
    else:
        raise ValueError(action)


if __name__ == "__main__":
    main()
