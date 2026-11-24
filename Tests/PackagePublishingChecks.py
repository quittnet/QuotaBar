"""Exercise release output handling with fixture scripts and no signing identity."""
import errno
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock
import zipfile

REPO = Path(__file__).resolve().parents[1]
APP = "QuotaBar-macOS.zip"
SOURCE = "QuotaBar-source.zip"


class PackageChecks(unittest.TestCase):
    def setUp(self):
        sandbox = tempfile.TemporaryDirectory(prefix="QuotaBar packaging ")
        self.addCleanup(sandbox.cleanup)
        self.root = Path(sandbox.name)
        self.output = self.root / "release files"
        self.output.mkdir()
        shutil.copy2(REPO / "package.sh", self.root)
        helper = Path("Helpers/PublishArchives.py")
        (self.root / helper.parent).mkdir()
        shutil.copy2(REPO / helper, self.root / helper)
        (self.root / "check.sh").write_text("#!/bin/sh\nexit 0\n")
        (self.root / "build.sh").write_text(
            '#!/bin/sh\nset -eu\nmkdir -p "$1/QuotaBar.app"\n'
            'cp "$(dirname "$0")/payload" "$1/QuotaBar.app/payload"\n'
        )
        for script in ["build.sh", "check.sh"]:
            (self.root / script).chmod(0o755)
        (self.root / "payload").write_text("first")
        (self.root / "last entry").write_text("last")
        (self.root / "release-files.txt").write_text("build.sh\ncheck.sh\npayload\nlast entry")

    def package(self):
        return subprocess.run([self.root / "package.sh", self.output], capture_output=True, text=True)

    def test_rerun_replaces_both_archives(self):
        for generation in ["first", "second"]:
            (self.root / "payload").write_text(generation)
            run = self.package()
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertEqual({p.name for p in self.output.iterdir()}, {APP, SOURCE})
            for name, base in [(APP, "QuotaBar.app"), (SOURCE, "QuotaBar")]:
                with zipfile.ZipFile(self.output / name) as archive:
                    self.assertEqual(archive.read(f"{base}/payload"), generation.encode())

    def test_unterminated_manifest_entry_is_included(self):
        run = self.package()
        self.assertEqual(run.returncode, 0, run.stderr)
        with zipfile.ZipFile(self.output / SOURCE) as archive:
            self.assertIn("QuotaBar/last entry", archive.namelist())

    def test_signed_release_survives_package_into_same_directory(self):
        signed = {APP: b"signed archive", "appcast.xml": b"signed feed", "SHA256SUMS.txt": b"checksums"}
        for name, data in signed.items():
            (self.output / name).write_bytes(data)
        run = self.package()
        self.assertNotEqual(run.returncode, 0)
        self.assertEqual({p.name: p.read_bytes() for p in self.output.iterdir()}, signed)

    def test_directory_at_archive_path_preserves_previous_package(self):
        (self.output / APP).write_bytes(b"previous archive")
        (self.output / SOURCE).mkdir()
        run = self.package()
        self.assertNotEqual(run.returncode, 0)
        self.assertEqual((self.output / APP).read_bytes(), b"previous archive")
        self.assertEqual(list((self.output / SOURCE).iterdir()), [])

    def test_updated_directory_is_rechecked_before_publication(self):
        publisher = self.root / "Helpers/PublishArchives.py"
        cmd = ["python3", publisher, "update", self.output]
        subprocess.run(cmd, check=True)
        # A package completed while the update builder was verifying its archive.
        run = self.package()
        self.assertEqual(run.returncode, 0, run.stderr)
        before = {p.name: p.read_bytes() for p in self.output.iterdir()}
        stage = self.root / "staged update"
        stage.mkdir()
        for name in (APP, "appcast.xml", "SHA256SUMS.txt"):
            (stage / name).write_text("update")
        run = subprocess.run([*cmd, stage], capture_output=True, text=True)
        self.assertNotEqual(run.returncode, 0)
        self.assertEqual({p.name: p.read_bytes() for p in self.output.iterdir()}, before)

    def test_interrupted_update_retries_only_unchanged_incomplete_outputs(self):
        publish = runpy.run_path(str(REPO / "Helpers/PublishArchives.py"))["publish"]
        names = (APP, "SHA256SUMS.txt", "appcast.xml")
        original_replace = os.replace
        for stop in range(1, 4):
            with self.subTest(stop=stop):
                output = self.output / str(stop)
                stage = self.root / f"update-{stop}"
                output.mkdir()
                stage.mkdir()
                for name in names:
                    (stage / name).write_text(name)

                def stop_after_rename(source, destination):
                    original_replace(source, destination)
                    if destination == output / names[stop - 1]:
                        raise SystemExit("stopped publisher")

                with mock.patch.object(os, "replace", side_effect=stop_after_rename):
                    with self.assertRaises(SystemExit):
                        publish("update", output, stage)
                with self.assertRaises(ValueError):
                    publish("package", output)
                if stop == 3:
                    with self.assertRaisesRegex(ValueError, "already exists"):
                        publish("update", output)
                    self.assertEqual({p.name: p.read_text() for p in output.iterdir()}, {n: n for n in names})
                    continue
                # A maintainer edited a partial artifact. Validate all files before cleanup.
                changed = output / names[stop - 1]
                changed.write_text("edited")
                before = {p.name: p.read_bytes() for p in output.iterdir()}
                with self.assertRaisesRegex(ValueError, "changed"):
                    publish("update", output)
                self.assertEqual({p.name: p.read_bytes() for p in output.iterdir()}, before)
                changed.write_text(changed.name)
                publish("update", output)
                self.assertEqual(list(output.iterdir()), [])
                for name in names:
                    (stage / name).write_text("retry")
                publish("update", output, stage)
                self.assertEqual({p.name: p.read_text() for p in output.iterdir()}, {n: "retry" for n in names})

    def test_rerun_on_filesystem_without_hard_links(self):
        publish = runpy.run_path(str(REPO / "Helpers/PublishArchives.py"))["publish"]
        stage = self.root / "staged package"
        stage.mkdir()
        for name in (APP, SOURCE):
            (self.output / name).write_text("original")
            (stage / name).write_text("replacement")
        with mock.patch.object(os, "link", side_effect=OSError(errno.ENOTSUP, "unsupported")):
            publish("package", self.output, stage)
        for name in (APP, SOURCE):
            self.assertEqual((self.output / name).read_text(), "replacement")

    def test_interrupted_private_package_never_leaves_a_mixed_pair(self):
        publish = runpy.run_path(str(REPO / "Helpers/PublishArchives.py"))["publish"]
        real_replace = os.replace
        for index, existing in enumerate(((), (APP,), (SOURCE,), (APP, SOURCE))):
            with self.subTest(existing=existing):
                output = self.output / str(index)
                stage = output / "stage"
                stage.mkdir(parents=True)
                for name in existing:
                    (output / name).write_text("original")
                for name in (APP, SOURCE):
                    (stage / name).write_text("replacement")

                def stop_after_first(source, destination):
                    real_replace(source, destination)
                    raise SystemExit("stopped publisher")

                with mock.patch.object(os, "replace", side_effect=stop_after_first):
                    with self.assertRaises(SystemExit):
                        publish("package", output, stage)
                shutil.rmtree(stage)
                visible = [(output / name).read_text() for name in (APP, SOURCE) if (output / name).exists()]
                self.assertEqual(visible, ["replacement"])
                if existing:
                    saved, = output.glob("QuotaBar-previous-package.*")
                    self.assertEqual({p.name: p.read_text() for p in saved.iterdir()}, {n: "original" for n in existing})
                stage.mkdir()
                for name in (APP, SOURCE):
                    (stage / name).write_text("retry")
                publish("package", output, stage)
                self.assertEqual([(output / name).read_text() for name in (APP, SOURCE)], ["retry", "retry"])

    def test_failed_bundle_install_restores_previous_bundle(self):
        publish = runpy.run_path(str(REPO / "Helpers/PublishArchives.py"))["publish"]
        stage = self.root / "staged build"
        stage.mkdir()
        destination = self.output / "QuotaBar.app"
        destination.mkdir()
        (destination / "payload").write_text("previous")
        # A missing staged app must leave the installed bundle untouched.
        with self.assertRaises(FileNotFoundError):
            publish("bundle", self.output, stage)
        self.assertEqual((destination / "payload").read_text(), "previous")
        self.assertEqual(list(self.output.iterdir()), [destination])

    def test_abrupt_bundle_replacement_keeps_launch_path_and_preserves_both_builds(self):
        publish = runpy.run_path(str(REPO / "Helpers/PublishArchives.py"))["publish"]
        exchange = publish.__globals__["swap_bundle"]
        for stop_after_swap in (False, True):
            with self.subTest(stop_after_swap=stop_after_swap):
                output = self.output / str(stop_after_swap)
                destination = output / "QuotaBar.app"
                stage = output / "stage"
                for app, data in ((destination, "original"), (stage / destination.name, "replacement")):
                    app.mkdir(parents=True)
                    (app / "payload").write_text(data)

                def stop(previous, live):
                    if stop_after_swap:
                        exchange(previous, live)
                    raise SystemExit("stopped publisher")

                with mock.patch.dict(publish.__globals__, swap_bundle=stop):
                    with self.assertRaises(SystemExit):
                        publish("bundle", output, stage)
                shutil.rmtree(stage)  # The calling shell cleans this directory.
                self.assertEqual((destination / "payload").read_text(), "replacement" if stop_after_swap else "original")
                previous, = output.glob("QuotaBar-previous.*/QuotaBar.app/payload")
                self.assertEqual(previous.read_text(), "original" if stop_after_swap else "replacement")

    def test_bundle_replacement_on_volume_without_atomic_exchange(self):
        publish = runpy.run_path(str(REPO / "Helpers/PublishArchives.py"))["publish"]
        stage = self.root / "staged build"
        destination = self.output / "QuotaBar.app"
        for app, data in ((destination, "original"), (stage / destination.name, "replacement")):
            app.mkdir(parents=True)
            (app / "payload").write_text(data)
        unavailable = mock.Mock(side_effect=OSError(errno.ENOTSUP, "unsupported"))
        with mock.patch.dict(publish.__globals__, swap_bundle=unavailable):
            publish("bundle", self.output, stage)
        self.assertEqual((destination / "payload").read_text(), "replacement")
        previous, = self.output.glob("QuotaBar-previous.*/QuotaBar.app/payload")
        self.assertEqual(previous.read_text(), "original")

    def test_failure_installing_second_archive_restores_first(self):
        publish = runpy.run_path(str(REPO / "Helpers/PublishArchives.py"))["publish"]
        stage = self.root / "staged package"
        stage.mkdir()
        original_replace = os.replace

        def fail_second(source, destination):
            if source == stage / SOURCE:
                raise OSError("Fixture write failure")
            original_replace(source, destination)

        for existing in (False, True):
            for name in (APP, SOURCE):
                (stage / name).write_text("replacement")
                if existing:
                    (self.output / name).write_text("original")
            with mock.patch.object(os, "replace", side_effect=fail_second):
                with self.assertRaisesRegex(OSError, "Fixture write failure"):
                    publish("package", self.output, stage)
            if existing:
                self.assertEqual([(self.output / n).read_text() for n in (APP, SOURCE)], ["original"] * 2)
            else:
                self.assertEqual(list(self.output.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
