"""Unit tests for the standalone atomic JSON writer."""

from __future__ import annotations

import importlib.util
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

LIBRARY_PATH = (
    Path(__file__).resolve().parents[2] / "scripts" / "lib" / "atomic-write.py"
)
SPEC = importlib.util.spec_from_file_location("atomic_write", LIBRARY_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load atomic writer from {LIBRARY_PATH}")
atomic_write = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(atomic_write)


@unittest.skipUnless(os.name == "posix", "requires POSIX directory fsync")
class AtomicWriteTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.directory = Path(self.temp_dir.name)
        self.target = self.directory / "state.json"

    def test_creates_json_with_restricted_mode(self) -> None:
        atomic_write.atomic_write_json(self.target, '{"ready": true}\n')

        self.assertEqual({"ready": True}, json.loads(self.target.read_text()))
        self.assertEqual(0o600, stat.S_IMODE(self.target.stat().st_mode))
        self.assertEqual(["state.json"], sorted(path.name for path in self.directory.iterdir()))

    def test_replaces_existing_file_atomically(self) -> None:
        self.target.write_text('{"old": true}\n')

        atomic_write.atomic_write_json(self.target, '{"new": true}\n')

        self.assertEqual({"new": True}, json.loads(self.target.read_text()))
        self.assertEqual(0o600, stat.S_IMODE(self.target.stat().st_mode))
        self.assertEqual(["state.json"], sorted(path.name for path in self.directory.iterdir()))

    def test_invalid_json_does_not_change_existing_file(self) -> None:
        self.target.write_text('{"old": true}\n')

        with self.assertRaises(atomic_write.AtomicWriteError):
            atomic_write.atomic_write_json(self.target, "{invalid")

        self.assertEqual('{"old": true}\n', self.target.read_text())
        self.assertEqual(["state.json"], sorted(path.name for path in self.directory.iterdir()))

    def test_invalid_unicode_does_not_create_target(self) -> None:
        with self.assertRaises(atomic_write.AtomicWriteError):
            atomic_write.atomic_write_json(self.target, '"\ud800"')

        self.assertFalse(self.target.exists())
        self.assertEqual([], list(self.directory.iterdir()))

    def test_rejects_nonstandard_json_constants(self) -> None:
        for document in ("NaN", "Infinity", "-Infinity"):
            with self.subTest(document=document):
                with self.assertRaises(atomic_write.AtomicWriteError):
                    atomic_write.atomic_write_json(self.target, document)
        self.assertEqual([], list(self.directory.iterdir()))

    def test_rejects_duplicate_json_object_keys(self) -> None:
        with self.assertRaises(atomic_write.AtomicWriteError):
            atomic_write.atomic_write_json(
                self.target,
                '{"status": "active", "status": "expired"}',
            )

        self.assertFalse(self.target.exists())

    def test_file_fsync_failure_preserves_existing_file_and_cleans_temp(self) -> None:
        self.target.write_text('{"old": true}\n')
        real_fsync = os.fsync

        def fail_first_fsync(file_descriptor: int) -> None:
            if stat.S_ISREG(os.fstat(file_descriptor).st_mode):
                raise OSError("simulated file fsync failure")
            real_fsync(file_descriptor)

        with patch.object(atomic_write.os, "fsync", side_effect=fail_first_fsync):
            with self.assertRaises(atomic_write.AtomicWriteError) as error:
                atomic_write.atomic_write_json(self.target, '{"new": true}\n')

        self.assertFalse(error.exception.replaced)
        self.assertEqual('{"old": true}\n', self.target.read_text())
        self.assertEqual(["state.json"], sorted(path.name for path in self.directory.iterdir()))

    def test_directory_fsync_failure_reports_visible_replacement(self) -> None:
        self.target.write_text('{"old": true}\n')
        real_fsync = os.fsync
        call_count = 0

        def fail_directory_fsync(file_descriptor: int) -> None:
            nonlocal call_count
            call_count += 1
            if call_count == 2:
                raise OSError("simulated directory fsync failure")
            real_fsync(file_descriptor)

        with patch.object(atomic_write.os, "fsync", side_effect=fail_directory_fsync):
            with self.assertRaises(atomic_write.AtomicWriteError) as error:
                atomic_write.atomic_write_json(self.target, '{"new": true}\n')

        self.assertTrue(error.exception.replaced, str(error.exception))
        self.assertEqual(2, call_count)
        self.assertIn("durability is uncertain", str(error.exception))
        self.assertEqual({"new": True}, json.loads(self.target.read_text()))
        self.assertEqual(["state.json"], sorted(path.name for path in self.directory.iterdir()))

    def test_refuses_symbolic_link_target(self) -> None:
        link = self.directory / "state-link.json"
        link.symlink_to(self.target)

        with self.assertRaises(atomic_write.AtomicWriteError):
            atomic_write.atomic_write_json(link, '{"new": true}\n')

        self.assertFalse(self.target.exists())
        self.assertTrue(link.is_symlink())

    def test_command_line_reports_invalid_json(self) -> None:
        completed = subprocess.run(
            [
                sys.executable,
                str(LIBRARY_PATH),
                "--file",
                str(self.target),
                "--data",
                "{invalid",
            ],
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(1, completed.returncode)
        self.assertIn("input is not valid JSON", completed.stderr)
        self.assertFalse(self.target.exists())

    def test_command_line_writes_valid_json(self) -> None:
        completed = subprocess.run(
            [
                sys.executable,
                str(LIBRARY_PATH),
                "--file",
                str(self.target),
                "--data",
                '{"ready": true}',
            ],
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(0, completed.returncode, completed.stderr)
        self.assertEqual({"ready": True}, json.loads(self.target.read_text()))
        self.assertEqual(0o600, stat.S_IMODE(self.target.stat().st_mode))


if __name__ == "__main__":
    unittest.main()
