"""Publish staged QuotaBar build outputs on the destination filesystem."""
from contextlib import contextmanager
import ctypes
import errno
import fcntl
import hashlib
import os
from pathlib import Path
import re
import shutil
import signal
import sys
import tempfile

APP = "QuotaBar-macOS.zip"
SOURCE = "QuotaBar-source.zip"
FEED = "appcast.xml"
SUMS = "SHA256SUMS.txt"
UPDATE_NAMES = (APP, SUMS, FEED)
PENDING = ".quotabar-pending-update"


def file_digest(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def recover_update(output):
    receipt = output / PENDING
    if receipt.is_symlink() or not receipt.is_file() or os.path.lexists(output / SOURCE):
        raise ValueError(f"Cannot recover interrupted release in {output}")
    # Check every surviving output before removing any. A completed release stays intact.
    with receipt.open("rb") as stream:
        data = stream.read(65 * len(UPDATE_NAMES) + 1)
    if not re.fullmatch(rb"(?:[0-9a-f]{64}\n){3}", data):
        raise ValueError(f"Invalid interrupted release receipt: {receipt}")
    present = []
    for name, expected in zip(UPDATE_NAMES, data.decode("ascii").splitlines()):
        path = output / name
        if os.path.lexists(path):
            if path.is_symlink() or not path.is_file() or file_digest(path) != expected:
                raise ValueError(f"Interrupted release file changed: {path}")
            present.append(name)
    if present != list(UPDATE_NAMES[:len(present)]):
        raise ValueError(f"Unexpected interrupted release files in {output}")
    if len(present) < len(UPDATE_NAMES):
        for name in reversed(present):
            (output / name).unlink()
    receipt.unlink()


def check_destinations(mode, output):
    if os.path.lexists(output / PENDING):
        if mode != "update":
            raise ValueError(f"Retry the interrupted signed release before packaging into {output}")
        recover_update(output)
    if mode == "package":
        for name in (FEED, SUMS):
            if os.path.lexists(output / name):
                raise ValueError(f"Signed release output already exists: {output / name}")
        names = (APP, SOURCE)
        for name in names:
            path = output / name
            if os.path.lexists(path) and (path.is_symlink() or not path.is_file()):
                raise ValueError(f"Expected a regular archive file: {path}")
    elif mode == "update":
        names = UPDATE_NAMES
        for name in (*names, SOURCE):
            if os.path.lexists(output / name):
                raise ValueError(f"Release output already exists: {output / name}")
    else:
        raise ValueError(f"Unknown release mode: {mode}")
    return names


@contextmanager
def finish_renames():
    # Finish the short rename/rollback sequence before honoring a catchable interruption.
    old_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGHUP, signal.SIGINT, signal.SIGTERM})
    try:
        yield
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)


def swap_bundle(previous, destination):
    # Darwin's RENAME_SWAP exchanges the two directory entries in one operation.
    rename = ctypes.CDLL(None, use_errno=True).renamex_np
    rename.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
    if rename(os.fsencode(previous), os.fsencode(destination), 2) != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code), destination)


def install_bundle(output, stage):
    destination = output / "QuotaBar.app"
    staged = stage / destination.name
    if not os.path.lexists(destination):
        os.rename(staged, destination)
        return

    previous = Path(tempfile.mkdtemp(prefix="QuotaBar-previous.", dir=output)) / destination.name
    with finish_renames():
        try:
            # Both sides survive the build script's stage cleanup if the publisher is killed.
            os.rename(staged, previous)
            try:
                swap_bundle(previous, destination)
            except OSError as error:
                os.rename(previous, staged)
                if error.errno != errno.ENOTSUP:
                    raise
                # Volumes without atomic exchange still support the original rename/rollback.
                os.rename(destination, previous)
                try:
                    os.rename(staged, destination)
                except OSError:
                    os.rename(previous, destination)
                    raise
        except OSError:
            if not os.path.lexists(previous):
                previous.parent.rmdir()
            raise
    print(f"Previous bundle preserved at {previous}")


def publish_archives(mode, output, stage):
    names = check_destinations(mode, output)
    for name in names:
        if not (stage / name).is_file():
            raise ValueError(f"Missing staged file: {stage / name}")
    existing = [name for name in names if (output / name).exists()]
    previous = None
    if existing:
        # Keep the prior private archives outside the shell's disposable staging directory.
        previous = Path(tempfile.mkdtemp(prefix="QuotaBar-previous-package.", dir=output))
        try:
            for name in existing:
                try:
                    os.link(output / name, previous / name)
                except OSError as error:
                    if error.errno not in (errno.ENOTSUP, errno.EOPNOTSUPP, errno.ENOSYS, errno.EPERM, errno.EMLINK):
                        raise
                    shutil.copy2(output / name, previous / name)
        except OSError:
            shutil.rmtree(previous)
            raise
    if mode == "update":
        # The shell cleans its staging directory even when only the publisher is killed.
        # Keep this receipt beside the outputs until every final rename has completed.
        with (stage / PENDING).open("x") as stream:
            for name in names:
                print(file_digest(stage / name), file=stream)
        os.replace(stage / PENDING, output / PENDING)
    published = []
    with finish_renames():
        try:
            # Withhold the old source before replacing its matching app. If only a
            # source exists, replace it first. A visible pair always belongs together.
            if SOURCE in existing and APP in existing:
                (output / SOURCE).unlink()
                published.append(SOURCE)
            elif SOURCE in existing:
                names = (SOURCE, APP)
            for name in names:
                os.replace(stage / name, output / name)
                published.append(name)
        except OSError:
            for name in reversed(published):
                if name in existing:
                    os.replace(previous / name, output / name)
                else:
                    (output / name).unlink()
            if mode == "update":
                (output / PENDING).unlink()
            if previous is not None:
                shutil.rmtree(previous)
            raise
        if mode == "update":
            (output / PENDING).unlink()
        if previous is not None:
            shutil.rmtree(previous)


def publish(mode, output, stage=None):
    # All producers lock the output directory only for the final local file operations.
    directory = os.open(output, os.O_RDONLY)
    try:
        fcntl.flock(directory, fcntl.LOCK_EX)
        if stage is None:
            check_destinations(mode, output)
        elif mode == "bundle":
            install_bundle(output, stage)
        else:
            publish_archives(mode, output, stage)
    finally:
        os.close(directory)


if __name__ == "__main__":
    mode, destination, *staging = sys.argv[1:]
    try:
        if staging:
            publish(mode, Path(destination), Path(staging[0]))
        else:
            publish(mode, Path(destination))
    except (OSError, ValueError) as error:
        sys.exit(str(error))
