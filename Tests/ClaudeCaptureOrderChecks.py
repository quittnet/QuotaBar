"""Exercise overlapping status-line captures through QuotaBar's command-line entry point."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
from tempfile import TemporaryDirectory


def payload(used):
    return json.dumps({
        "session_id": f"session-{used}",
        "rate_limits": {"five_hour": {"used_percentage": used}},
    }).encode()


def timed_out(_signal, _frame):
    raise TimeoutError("Timed out waiting for the overlapping Claude captures")


def check_overlap(binary, root, older_payload, expected_status):
    env = {
        "HOME": str(root), "CFFIXED_USER_HOME": str(root), "PATH": os.defpath,
        "CLAUDE_CONFIG_DIR": str(root / ".claude"), "CODEX_HOME": str(root / ".codex"),
    }
    command = [binary, "--capture-claude-quota"]
    with subprocess.Popen(command, env=env, stdin=subprocess.PIPE) as older:
        try:
            # Exceed the pipe capacity to ensure the first process is reading before starting the second.
            older.stdin.write(b" " * 262144)
            older.stdin.flush()
            subprocess.run(command, input=payload(36), env=env, timeout=10, check=True)
            try:
                older.stdin.write(older_payload)
                older.stdin.close()
            except BrokenPipeError:
                pass
            assert older.wait(timeout=10) == expected_status
        finally:
            if older.poll() is None:
                older.kill()
    cache, = (root / "Library/Caches/app.quotabar.QuotaBar/claude").glob("*.json")
    assert json.loads(cache.read_bytes())["limits"]["five_hour"]["used_percentage"] == 36


def check_sign_ins(binary, root):
    env = {"HOME": str(root), "CFFIXED_USER_HOME": str(root), "CODEX_HOME": str(root / ".codex"), "PATH": os.defpath}
    command = [binary, "--capture-claude-quota"]
    for config, used in ((None, 12), (str(root / ".claude"), 36), (None, 48)):
        if config is not None:
            env["CLAUDE_CONFIG_DIR"] = config
        else:
            env.pop("CLAUDE_CONFIG_DIR", None)
        subprocess.run(command, input=payload(used), env=env, check=True, timeout=10)
    caches = (root / "Library/Caches/app.quotabar.QuotaBar/claude").glob("*.json")
    amounts = sorted(json.loads(p.read_bytes())["limits"]["five_hour"]["used_percentage"] for p in caches)
    assert amounts == [36, 48], f"Expected separate Claude sign-in caches, got {amounts}"


if __name__ == "__main__":
    signal.signal(signal.SIGALRM, timed_out)
    for data, status in ((payload(12), 0), (b"{", 1), (b" " * 1024 * 1024, 1)):
        with TemporaryDirectory(prefix="quotabar-capture-") as directory:
            root = Path(directory)
            (root / ".claude" / "projects").mkdir(parents=True)
            signal.alarm(25)
            try:
                check_overlap(sys.argv[1], root, data, status)
            finally:
                signal.alarm(0)
    print("Overlapping older valid, malformed and oversized inputs preserved the newer Claude percentage.")
    with TemporaryDirectory(prefix="quotabar-sign-in-") as directory:
        (Path(directory) / ".claude").mkdir()
        check_sign_ins(sys.argv[1], Path(directory))
    print("Implicit and explicit sign-ins sharing the normal Claude folder kept independent percentages.")
