from __future__ import annotations

import grp
import importlib.util
import json
import os
import stat
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

HELPER_PATH = (
    Path(__file__).resolve().parents[2] / "scripts" / "lib" / "audit_write.py"
)
SPEC = importlib.util.spec_from_file_location("audit_write", HELPER_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("Could not load Audit writer module")
audit_write = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(audit_write)


class AuditWriteTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp_dir.name)
        self.audit_file = self.directory / "audit.jsonl"
        self.group = grp.getgrgid(os.getgid()).gr_name
        os.chmod(self.directory, 0o700)
        self.patches = (
            patch.object(audit_write, "AUDIT_DIRECTORY", self.directory),
            patch.object(audit_write, "AUDIT_FILE", self.audit_file),
            patch.object(audit_write, "AUDIT_GROUP", self.group),
            patch.object(audit_write, "AUDIT_UID", os.getuid()),
            patch.object(audit_write, "DIRECTORY_MODE", 0o700),
            patch.object(audit_write, "FILE_MODE", 0o600),
        )
        for item in self.patches:
            item.start()

    def tearDown(self) -> None:
        for item in reversed(self.patches):
            item.stop()
        self.temp_dir.cleanup()

    def test_writes_one_srs_audit_jsonl_record_with_restricted_mode(self) -> None:
        audit_write.append_audit_record(
            "approve", "applied", "correlation-1", "verified policy"
        )

        record = json.loads(self.audit_file.read_text(encoding="utf-8"))
        self.assertEqual(
            {
                "timestamp_utc",
                "actor_uid",
                "action",
                "policy_result",
                "correlation_id",
                "details",
            },
            set(record),
        )
        self.assertTrue(record["timestamp_utc"].endswith("Z"))
        self.assertEqual(os.getuid(), record["actor_uid"])
        self.assertEqual("applied", record["policy_result"])
        self.assertEqual("verified policy", record["details"])
        self.assertEqual(os.getuid(), self.audit_file.stat().st_uid)
        self.assertEqual(os.getgid(), self.audit_file.stat().st_gid)
        self.assertEqual(0o600, stat.S_IMODE(self.audit_file.stat().st_mode))
        self.assertEqual(1, len(self.audit_file.read_text(encoding="utf-8").splitlines()))

    def test_appends_without_forging_a_second_line(self) -> None:
        audit_write.append_audit_record("first", "not_applied", "id-1", "")
        audit_write.append_audit_record("second", "applied", "id-2", "done")

        lines = self.audit_file.read_text(encoding="utf-8").splitlines()
        self.assertEqual(2, len(lines))
        self.assertEqual("second", json.loads(lines[1])["action"])

    def test_control_characters_are_rejected(self) -> None:
        with self.assertRaisesRegex(audit_write.AuditWriteError, "control characters"):
            audit_write.append_audit_record("approve\nforged", "applied", "id", "")
        self.assertFalse(self.audit_file.exists())

    def test_unsupported_policy_result_is_rejected(self) -> None:
        with self.assertRaisesRegex(audit_write.AuditWriteError, "supported status"):
            audit_write.append_audit_record("approve", "partial", "id", "")
        self.assertFalse(self.audit_file.exists())

    def test_oversized_details_are_rejected(self) -> None:
        with self.assertRaisesRegex(audit_write.AuditWriteError, "maximum length"):
            audit_write.append_audit_record(
                "approve", "applied", "id", "x" * (audit_write.FIELD_LIMITS["details"] + 1)
            )
        self.assertFalse(self.audit_file.exists())

    def test_symbolic_link_target_is_rejected(self) -> None:
        target = self.directory / "target"
        target.write_text("unchanged", encoding="utf-8")
        self.audit_file.symlink_to(target)

        with self.assertRaises(audit_write.AuditWriteError):
            audit_write.append_audit_record("approve", "applied", "id", "details")
        self.assertEqual("unchanged", target.read_text(encoding="utf-8"))

    def test_unsafe_directory_permissions_are_rejected(self) -> None:
        os.chmod(self.directory, 0o777)

        with self.assertRaisesRegex(audit_write.AuditWriteError, "directory ownership or mode"):
            audit_write.append_audit_record("approve", "applied", "id", "details")
        self.assertFalse(self.audit_file.exists())

    def test_write_failure_is_reported(self) -> None:
        with patch.object(
            audit_write,
            "_open_audit_file",
            side_effect=audit_write.AuditWriteError("disk unavailable"),
        ):
            with self.assertRaises(audit_write.AuditWriteError):
                audit_write.append_audit_record("approve", "applied", "id", "details")

    def test_invoking_uid_is_used_when_valid(self) -> None:
        with patch.dict(os.environ, {"SUDO_UID": "1234"}):
            self.assertEqual(1234, audit_write._actor_uid())

    def test_invalid_sudo_uid_falls_back_to_current_uid(self) -> None:
        with patch.dict(os.environ, {"SUDO_UID": "12x"}):
            self.assertEqual(os.getuid(), audit_write._actor_uid())


if __name__ == "__main__":
    unittest.main()
