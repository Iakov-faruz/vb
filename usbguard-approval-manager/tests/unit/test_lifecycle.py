import hashlib
import io
import importlib.util
import json
import os
import tarfile
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
HELPER_PATH = ROOT / "scripts" / "lib" / "lifecycle.py"
SPEC = importlib.util.spec_from_file_location("lifecycle", HELPER_PATH)
assert SPEC is not None and SPEC.loader is not None
lifecycle = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lifecycle)


def ttl_record(rule: str, status: str = "active") -> dict[str, object]:
    return {
        "managed_id": str(uuid.uuid4()),
        "rule": rule,
        "rule_sha256": hashlib.sha256(rule.encode()).hexdigest(),
        "expires_at": 2_000_000_000,
        "status": status,
        "correlation_id": str(uuid.uuid4()),
    }


class LifecycleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="usbam-lifecycle-")
        self.root = Path(self.temp.name)
        self.config = self.root / "approval-manager.conf"
        self.ttl = self.root / "ttl.json"
        self.export = self.root / "export.json"
        self.config.write_text("BACKUP_KEEP=5\n", encoding="utf-8")
        self.ttl.write_text(
            json.dumps({"schema_version": 1, "records": [ttl_record("allow id 1234:5678")]})
            + "\n",
            encoding="utf-8",
        )
        self.export.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "permanent_rules": ["allow id 1234:5678"],
                    "ttl_records": [
                        {"rule": "allow id abcd:ef01", "expires_at": 2_000_000_000}
                    ],
                }
            )
            + "\n",
            encoding="utf-8",
        )
        self.backup_dir = self.root / "backups"
        self.backup_dir.mkdir(mode=0o700)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_backup_round_trip_has_closed_manifest_and_payloads(self) -> None:
        archive = lifecycle.create_backup(
            self.config, self.ttl, self.export, self.backup_dir, keep=2
        )

        payloads = lifecycle.read_backup(archive)

        self.assertEqual(set(payloads), lifecycle.PAYLOAD_PATHS)
        extracted = self.root / "extracted"
        lifecycle.extract_backup(archive, extracted)
        for name, data in payloads.items():
            target = extracted / name
            self.assertEqual(target.read_bytes(), data)
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)
        with tarfile.open(archive, "r:gz") as archive_file:
            manifest_member = archive_file.extractfile("manifest.json")
            self.assertIsNotNone(manifest_member)
            manifest = json.loads(manifest_member.read())
        self.assertEqual(
            {entry["path"] for entry in manifest["entries"]}, lifecycle.PAYLOAD_PATHS
        )
        self.assertTrue(all(entry["mode"] == 0o600 for entry in manifest["entries"]))

    def test_import_rejects_system_data_extra_fields_and_duplicate_rules(self) -> None:
        for document in (
            {
                "schema_version": 1,
                "permanent_rules": ["allow id 1234:5678", "allow id 1234:5678"],
                "ttl_records": [],
            },
            {
                "schema_version": 1,
                "permanent_rules": ["allow id 1234:5678"],
                "ttl_records": [],
                "system": [],
            },
            {
                "schema_version": 1,
                "permanent_rules": ["allow id 1234:5678"],
                "ttl_records": [
                    {"rule": "allow id 1234:5678 00-system.rules", "expires_at": 2_000_000_000}
                ],
            },
        ):
            with self.subTest(document=document), self.assertRaises(lifecycle.LifecycleError):
                lifecycle.validate_export(document)

    def test_export_enforces_rule_count_and_expiry_bounds(self) -> None:
        with self.assertRaisesRegex(lifecycle.LifecycleError, "too many rules"):
            lifecycle.validate_export(
                {
                    "schema_version": 1,
                    "permanent_rules": ["allow id 1234:5678"] * 10001,
                    "ttl_records": [],
                }
            )
        with self.assertRaisesRegex(lifecycle.LifecycleError, "expires_at"):
            lifecycle.validate_export(
                {
                    "schema_version": 1,
                    "permanent_rules": [],
                    "ttl_records": [
                        {"rule": "allow id 1234:5678", "expires_at": 253402300800}
                    ],
                }
            )

    def test_archive_rejects_traversal_and_hash_mismatch(self) -> None:
        archive = lifecycle.create_backup(
            self.config, self.ttl, self.export, self.backup_dir, keep=2
        )
        traversal = self.root / "traversal.tar.gz"
        with tarfile.open(archive, "r:gz") as source, tarfile.open(
            traversal, "w:gz"
        ) as target:
            for member in source.getmembers():
                data = source.extractfile(member).read()
                member.name = "../" + member.name
                target.addfile(member, io.BytesIO(data))
        with self.assertRaises(lifecycle.LifecycleError):
            lifecycle.read_backup(traversal)

        altered = self.root / "altered.tar.gz"
        with tarfile.open(archive, "r:gz") as source, tarfile.open(altered, "w:gz") as target:
            for member in source.getmembers():
                data = source.extractfile(member).read()
                if member.name == "policy/export.json":
                    data = bytes([data[0] ^ 1]) + data[1:]
                target.addfile(member, io.BytesIO(data))
        with self.assertRaisesRegex(lifecycle.LifecycleError, "integrity"):
            lifecycle.read_backup(altered)

    def _restore_fixture(self) -> tuple[Path, Path, Path, Path, Path]:
        stage = self.root / "stage"
        (stage / "config").mkdir(parents=True)
        (stage / "state").mkdir()
        (stage / "policy").mkdir()
        (stage / "config" / "approval-manager.conf").write_text(
            "BACKUP_KEEP=7\n", encoding="utf-8"
        )
        (stage / "state" / "ttl.json").write_text(
            json.dumps({"schema_version": 1, "records": [ttl_record("allow id 2222:3333")]})
            + "\n",
            encoding="utf-8",
        )
        (stage / "policy" / "rules.conf").write_text("allow id 1234:5678\n", encoding="utf-8")
        targets = {
            "config": str(self.root / "target.conf"),
            "ttl": str(self.root / "target-ttl.json"),
            "policy": str(self.root / "target-rules.conf"),
        }
        for path in targets.values():
            Path(path).write_text("old\n", encoding="utf-8")
        targets_file = self.root / "targets.json"
        targets_file.write_text(json.dumps(targets), encoding="utf-8")
        journal = self.root / "state" / "restore_journal.json"
        journal.parent.mkdir()
        return stage, targets_file, journal, self.root / "rollback", self.root

    def test_restore_atomically_recovers_ttl_records_as_recovery_required(self) -> None:
        stage, targets_file, journal, rollback_root, _ = self._restore_fixture()

        lifecycle.apply_restore(journal, rollback_root, targets_file, stage)

        self.assertFalse(journal.exists())
        targets = json.loads(targets_file.read_text(encoding="utf-8"))
        restored_ttl = json.loads(Path(targets["ttl"]).read_text(encoding="utf-8"))
        self.assertEqual(restored_ttl["records"][0]["status"], "recovery_required")
        self.assertEqual(Path(targets["policy"]).read_text(encoding="utf-8"), "allow id 1234:5678\n")

    def test_recovery_can_be_retried_after_journal_cleanup_failure(self) -> None:
        stage, targets_file, journal, rollback_root, _ = self._restore_fixture()
        with mock.patch.object(
            lifecycle, "_remove_journal", side_effect=lifecycle.LifecycleError("simulated crash")
        ):
            with self.assertRaises(lifecycle.LifecycleError):
                lifecycle.apply_restore(journal, rollback_root, targets_file, stage)
        self.assertTrue(journal.exists())

        with mock.patch.object(
            lifecycle, "_remove_journal", side_effect=lifecycle.LifecycleError("simulated crash")
        ):
            with self.assertRaises(lifecycle.LifecycleError):
                lifecycle.recover_restore(journal, rollback_root, targets_file)
        lifecycle.recover_restore(journal, rollback_root, targets_file)

        self.assertFalse(journal.exists())
        targets = json.loads(targets_file.read_text(encoding="utf-8"))
        self.assertTrue(all(Path(path).read_text(encoding="utf-8") == "old\n" for path in targets.values()))

    def test_failed_recovery_keeps_journal_marked_for_recovery(self) -> None:
        stage, targets_file, journal, rollback_root, _ = self._restore_fixture()
        failure = lifecycle.LifecycleError("simulated rollback failure")
        with (
            mock.patch.object(lifecycle, "_remove_journal", side_effect=failure),
            mock.patch.object(lifecycle, "_rollback_transaction", side_effect=failure),
            self.assertRaises(lifecycle.LifecycleError),
        ):
            lifecycle.apply_restore(journal, rollback_root, targets_file, stage)
        self.assertEqual(
            json.loads(journal.read_text(encoding="utf-8"))["status"], "recovery_required"
        )

        with (
            mock.patch.object(lifecycle, "_rollback_transaction", side_effect=failure),
            self.assertRaisesRegex(lifecycle.LifecycleError, "recovery is incomplete"),
        ):
            lifecycle.recover_restore(journal, rollback_root, targets_file)
        self.assertEqual(
            json.loads(journal.read_text(encoding="utf-8"))["status"], "recovery_required"
        )

    @unittest.skipUnless(hasattr(os, "symlink"), "symlinks are unavailable")
    def test_backup_refuses_symbolic_link(self) -> None:
        link = self.root / "linked-export.json"
        link.symlink_to(self.export)
        with self.assertRaisesRegex(lifecycle.LifecycleError, "safely open"):
            lifecycle.create_backup(self.config, self.ttl, link, self.backup_dir, keep=2)


if __name__ == "__main__":
    unittest.main()
