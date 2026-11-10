#!/usr/bin/env python3
"""Validated USBGuard backup, export, and crash-safe restore helpers."""

from __future__ import annotations

import argparse
import datetime
import gzip
import hashlib
import io
import json
import os
import secrets
import stat
import sys
import tarfile
import uuid
from pathlib import Path
from typing import Any

MAX_DOCUMENT_SIZE = 4 * 1024 * 1024
MAX_ARCHIVE_SIZE = 16 * 1024 * 1024
MAX_ARCHIVE_MEMBERS = 8
MAX_RULE_COUNT = 10000
EXPORT_KEYS = {"schema_version", "permanent_rules", "ttl_records"}
TTL_KEYS = {
    "managed_id",
    "rule",
    "rule_sha256",
    "expires_at",
    "status",
    "correlation_id",
}
TTL_STATUSES = {"pending", "active", "inconsistent", "recovery_required", "expired"}
PAYLOAD_PATHS = {
    "config/approval-manager.conf",
    "state/ttl.json",
    "policy/export.json",
}
TARGET_KEYS = {"config", "ttl", "policy"}


class LifecycleError(Exception):
    """A validation, archive, or restore transaction error."""


class _BoundedReader:
    def __init__(self, source: Any, limit: int) -> None:
        self._source = source
        self._limit = limit
        self._read = 0

    def read(self, size: int = -1) -> bytes:
        requested = self._limit - self._read + 1 if size < 0 else size
        chunk = self._source.read(min(requested, self._limit - self._read + 1))
        self._read += len(chunk)
        if self._read > self._limit:
            raise LifecycleError("uncompressed archive exceeds the size limit")
        return chunk


def _reject_constant(value: str) -> None:
    raise ValueError(f"non-standard JSON constant: {value}")


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _json_loads(data: bytes, label: str) -> Any:
    if len(data) > MAX_DOCUMENT_SIZE:
        raise LifecycleError(f"{label} exceeds the document size limit")
    try:
        return json.loads(
            data.decode("utf-8"),
            object_pairs_hook=_unique_object,
            parse_constant=_reject_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
        raise LifecycleError(f"{label} is invalid: {error}") from error


def _read_regular(path: Path, label: str, limit: int = MAX_DOCUMENT_SIZE) -> tuple[bytes, os.stat_result]:
    try:
        file_fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except OSError as error:
        raise LifecycleError(f"cannot safely open {label}: {error}") from error
    try:
        info = os.fstat(file_fd)
        if not stat.S_ISREG(info.st_mode):
            raise LifecycleError(f"{label} is not a regular file")
        chunks: list[bytes] = []
        size = 0
        while True:
            chunk = os.read(file_fd, min(65536, limit + 1 - size))
            if not chunk:
                break
            chunks.append(chunk)
            size += len(chunk)
            if size > limit:
                raise LifecycleError(f"{label} exceeds the size limit")
        return b"".join(chunks), info
    finally:
        os.close(file_fd)


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _canonical_allow_rule(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value or value != value.strip():
        raise LifecycleError(f"{label} must be a non-empty canonical rule")
    if any(ord(character) < 32 or ord(character) == 127 for character in value):
        raise LifecycleError(f"{label} contains a control character")
    if "00-system.rules" in value or not value.startswith("allow "):
        raise LifecycleError(f"{label} is not an exportable allow rule")
    return value


def _validate_config_text(data: bytes, label: str) -> None:
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise LifecycleError(f"{label} is not valid UTF-8") from error
    if any(
        (ord(character) < 32 and character != "\n") or ord(character) == 127
        for character in text
    ):
        raise LifecycleError(f"{label} contains a control character")


def validate_export(document: Any) -> dict[str, Any]:
    if not isinstance(document, dict) or set(document) != EXPORT_KEYS:
        raise LifecycleError("export must contain exactly schema_version, permanent_rules, and ttl_records")
    if type(document["schema_version"]) is not int or document["schema_version"] != 1:
        raise LifecycleError("unsupported export schema_version")
    permanent = document["permanent_rules"]
    ttl_records = document["ttl_records"]
    if not isinstance(permanent, list) or not isinstance(ttl_records, list):
        raise LifecycleError("permanent_rules and ttl_records must be arrays")
    if len(permanent) + len(ttl_records) > MAX_RULE_COUNT:
        raise LifecycleError("export contains too many rules")

    normalized_permanent: list[str] = []
    seen_rules: set[str] = set()
    for index, value in enumerate(permanent):
        rule = _canonical_allow_rule(value, f"permanent_rules[{index}]")
        if rule in seen_rules:
            raise LifecycleError("duplicate permanent rule")
        seen_rules.add(rule)
        normalized_permanent.append(rule)

    normalized_ttl: list[dict[str, Any]] = []
    seen_ttl_rules: set[str] = set()
    for index, value in enumerate(ttl_records):
        if not isinstance(value, dict) or set(value) != {"rule", "expires_at"}:
            raise LifecycleError(f"ttl_records[{index}] must contain exactly rule and expires_at")
        rule = _canonical_allow_rule(value["rule"], f"ttl_records[{index}].rule")
        expires_at = value["expires_at"]
        if type(expires_at) is not int or not 0 < expires_at <= 253402300799:
            raise LifecycleError(f"ttl_records[{index}].expires_at must be a positive integer")
        if rule in seen_rules or rule in seen_ttl_rules:
            raise LifecycleError("rule appears more than once or in both export categories")
        seen_ttl_rules.add(rule)
        normalized_ttl.append({"rule": rule, "expires_at": expires_at})
    return {
        "schema_version": 1,
        "permanent_rules": normalized_permanent,
        "ttl_records": normalized_ttl,
    }


def validate_ttl_state(document: Any) -> dict[str, Any]:
    if not isinstance(document, dict) or set(document) != {"schema_version", "records"}:
        raise LifecycleError("ttl.json must contain exactly schema_version and records")
    if type(document["schema_version"]) is not int or document["schema_version"] != 1:
        raise LifecycleError("unsupported ttl.json schema_version")
    if not isinstance(document["records"], list):
        raise LifecycleError("ttl.json records must be an array")
    managed_ids: set[str] = set()
    correlations: set[str] = set()
    for index, record in enumerate(document["records"]):
        if not isinstance(record, dict) or set(record) != TTL_KEYS:
            raise LifecycleError(f"ttl.json record {index} has an invalid shape")
        managed_id = record["managed_id"]
        correlation_id = record["correlation_id"]
        try:
            if str(uuid.UUID(managed_id)) != managed_id or uuid.UUID(managed_id).version != 4:
                raise ValueError
            if (
                str(uuid.UUID(correlation_id)) != correlation_id
                or uuid.UUID(correlation_id).version != 4
            ):
                raise ValueError
        except (AttributeError, TypeError, ValueError) as error:
            raise LifecycleError(f"ttl.json record {index} has an invalid UUID") from error
        if managed_id in managed_ids or correlation_id in correlations:
            raise LifecycleError("ttl.json contains duplicate identifiers")
        managed_ids.add(managed_id)
        correlations.add(correlation_id)
        rule = record["rule"]
        if not isinstance(rule, str) or not rule or any(
            ord(character) < 32 or ord(character) == 127 for character in rule
        ):
            raise LifecycleError(f"ttl.json record {index} has an invalid rule")
        if "00-system.rules" in rule or not rule.startswith("allow "):
            raise LifecycleError(f"ttl.json record {index} contains a protected or non-allow rule")
        if not isinstance(record["rule_sha256"], str) or record["rule_sha256"] != _sha256(
            rule.encode("utf-8")
        ):
            raise LifecycleError(f"ttl.json record {index} has an invalid rule hash")
        if type(record["expires_at"]) is not int or record["expires_at"] <= 0:
            raise LifecycleError(f"ttl.json record {index} has an invalid expires_at")
        if not isinstance(record["status"], str) or record["status"] not in TTL_STATUSES:
            raise LifecycleError(f"ttl.json record {index} has an invalid status")
        if record["expires_at"] > 253402300799:
            raise LifecycleError(f"ttl.json record {index} has an out-of-range expires_at")
    return document


def _fsync_directory(path: Path) -> None:
    directory_fd = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)


def _atomic_replace(path: Path, data: bytes, mode: int = 0o600) -> None:
    parent = path.parent
    try:
        resolved_parent = parent.resolve(strict=True)
    except OSError as error:
        raise LifecycleError(f"target directory is unavailable: {parent}") from error
    if resolved_parent != parent.absolute():
        raise LifecycleError(f"target directory contains a symbolic link: {parent}")
    directory_fd = os.open(
        resolved_parent,
        os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0),
    )
    temp_name = f".{path.name}.{secrets.token_hex(8)}.tmp"
    try:
        try:
            info = os.stat(path.name, dir_fd=directory_fd, follow_symlinks=False)
        except FileNotFoundError:
            info = None
        if info is not None and not stat.S_ISREG(info.st_mode):
            raise LifecycleError(f"refusing to replace non-regular target: {path}")
        fd = os.open(
            temp_name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            mode,
            dir_fd=directory_fd,
        )
        try:
            os.fchmod(fd, mode)
            view = memoryview(data)
            while view:
                written = os.write(fd, view)
                if written <= 0:
                    raise OSError("short write")
                view = view[written:]
            os.fsync(fd)
        finally:
            os.close(fd)
        os.replace(temp_name, path.name, src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
        os.fsync(directory_fd)
    except (OSError, LifecycleError) as error:
        try:
            os.unlink(temp_name, dir_fd=directory_fd)
        except FileNotFoundError:
            pass
        if isinstance(error, LifecycleError):
            raise
        raise LifecycleError(f"atomic replacement failed for {path}: {error}") from error
    finally:
        os.close(directory_fd)


def create_backup(
    config_path: Path,
    ttl_path: Path,
    export_path: Path,
    backup_dir: Path,
    keep: int,
) -> Path:
    if type(keep) is not int or not 1 <= keep <= 100:
        raise LifecycleError("backup retention must be an integer from 1 to 100")
    if backup_dir.is_symlink():
        raise LifecycleError("backup directory must not be a symbolic link")
    backup_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not backup_dir.is_dir() or stat.S_IMODE(backup_dir.stat().st_mode) != 0o700:
        raise LifecycleError("backup directory must be a directory with mode 0700")

    config, _ = _read_regular(config_path, "configuration")
    ttl_raw, _ = _read_regular(ttl_path, "ttl.json")
    export_raw, _ = _read_regular(export_path, "export JSON")
    _validate_config_text(config, "configuration")
    validate_ttl_state(_json_loads(ttl_raw, "ttl.json"))
    export = validate_export(_json_loads(export_raw, "export JSON"))
    payloads = {
        "config/approval-manager.conf": config,
        "state/ttl.json": ttl_raw,
        "policy/export.json": (
            json.dumps(export, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n"
        ).encode("utf-8"),
    }
    manifest = {
        "schema_version": 1,
        "entries": [
            {
                "path": name,
                "size": len(data),
                "mode": 0o600,
                "sha256": _sha256(data),
            }
            for name, data in sorted(payloads.items())
        ],
    }
    now = datetime.datetime.now(datetime.timezone.utc)
    stem = "usbguard-approval-manager-" + now.strftime("%Y%m%dT%H%M%SZ")
    destination = backup_dir / f"{stem}.tar.gz"
    if destination.exists() or destination.is_symlink():
        destination = backup_dir / f"{stem}-{secrets.token_hex(4)}.tar.gz"
    temp_path = backup_dir / f".{destination.name}.{secrets.token_hex(8)}.tmp"
    try:
        with tarfile.open(temp_path, mode="w:gz", format=tarfile.PAX_FORMAT) as archive:
            for name, data in sorted(payloads.items()):
                info = tarfile.TarInfo(name)
                info.size = len(data)
                info.mode = 0o600
                info.mtime = 0
                archive.addfile(info, io.BytesIO(data))
            raw_manifest = (
                json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n"
            ).encode("utf-8")
            info = tarfile.TarInfo("manifest.json")
            info.size = len(raw_manifest)
            info.mode = 0o600
            info.mtime = 0
            archive.addfile(info, io.BytesIO(raw_manifest))
        os.chmod(temp_path, 0o600)
        with temp_path.open("rb") as stream:
            os.fsync(stream.fileno())
        os.replace(temp_path, destination)
        _fsync_directory(backup_dir)
    except (OSError, tarfile.TarError) as error:
        try:
            temp_path.unlink()
        except FileNotFoundError:
            pass
        raise LifecycleError(f"backup creation failed: {error}") from error

    backups: list[Path] = []
    for candidate in backup_dir.iterdir():
        if candidate.name.startswith("usbguard-approval-manager-") and candidate.name.endswith(
            ".tar.gz"
        ):
            if candidate.is_symlink() or not candidate.is_file():
                raise LifecycleError(f"unsafe backup entry: {candidate.name}")
            backups.append(candidate)
    backups.sort(key=lambda item: (item.stat().st_mtime_ns, item.name), reverse=True)
    for old_backup in backups[keep:]:
        old_backup.unlink()
    _fsync_directory(backup_dir)
    return destination


def read_backup(backup_path: Path) -> dict[str, bytes]:
    raw_archive, _ = _read_regular(backup_path, "backup archive", MAX_ARCHIVE_SIZE)
    try:
        compressed = io.BytesIO(raw_archive)
        with gzip.GzipFile(fileobj=compressed, mode="rb") as decompressed:
            bounded = _BoundedReader(decompressed, MAX_ARCHIVE_SIZE)
            with tarfile.open(fileobj=bounded, mode="r|") as archive:
                payloads: dict[str, bytes] = {}
                members_seen: set[str] = set()
                for member in archive:
                    if len(members_seen) >= MAX_ARCHIVE_MEMBERS:
                        raise LifecycleError("archive contains too many entries")
                    name = member.name
                    if (
                        not name
                        or name.startswith("/")
                        or "\\" in name
                        or any(part in {"", ".", ".."} for part in name.split("/"))
                    ):
                        raise LifecycleError("archive contains an unsafe path")
                    if name not in PAYLOAD_PATHS | {"manifest.json"}:
                        raise LifecycleError(f"archive contains an unexpected file: {name}")
                    if name in members_seen:
                        raise LifecycleError(f"archive contains a duplicate file: {name}")
                    members_seen.add(name)
                    if not member.isfile() or member.issym() or member.islnk():
                        raise LifecycleError(f"archive entry is not a regular file: {name}")
                    if member.mode != 0o600 or member.size > MAX_DOCUMENT_SIZE:
                        raise LifecycleError(f"archive entry has unsafe mode or size: {name}")
                    source = archive.extractfile(member)
                    if source is None:
                        raise LifecycleError(f"cannot read archive entry: {name}")
                    data = source.read(MAX_DOCUMENT_SIZE + 1)
                    if len(data) != member.size:
                        raise LifecycleError(f"archive entry size mismatch: {name}")
                    payloads[name] = data
        if "manifest.json" not in payloads:
            raise LifecycleError("archive manifest is missing")
        manifest = _json_loads(payloads.pop("manifest.json"), "manifest")
        if not isinstance(manifest, dict) or set(manifest) != {"schema_version", "entries"}:
            raise LifecycleError("manifest has an invalid shape")
        if type(manifest["schema_version"]) is not int or manifest["schema_version"] != 1:
            raise LifecycleError("unsupported manifest schema_version")
        entries = manifest["entries"]
        if not isinstance(entries, list):
            raise LifecycleError("manifest entries must be an array")
        expected: dict[str, dict[str, Any]] = {}
        for entry in entries:
            if not isinstance(entry, dict) or set(entry) != {"path", "size", "mode", "sha256"}:
                raise LifecycleError("manifest entry has an invalid shape")
            name = entry["path"]
            if (
                not isinstance(name, str)
                or name not in PAYLOAD_PATHS
                or name in expected
            ):
                raise LifecycleError("manifest contains an unexpected or duplicate path")
            if (
                type(entry["size"]) is not int
                or entry["size"] < 0
                or type(entry["mode"]) is not int
                or entry["mode"] != 0o600
                or not isinstance(entry["sha256"], str)
                or len(entry["sha256"]) != 64
                or any(char not in "0123456789abcdef" for char in entry["sha256"])
            ):
                raise LifecycleError(f"manifest metadata is invalid for {name}")
            expected[name] = entry
        if set(expected) != set(payloads):
            raise LifecycleError("archive files do not match the manifest")
        for name, data in payloads.items():
            entry = expected[name]
            if len(data) != entry["size"] or _sha256(data) != entry["sha256"]:
                raise LifecycleError(f"manifest integrity check failed for {name}")
        if set(payloads) != PAYLOAD_PATHS:
            raise LifecycleError("backup is missing a required payload")
        validate_ttl_state(_json_loads(payloads["state/ttl.json"], "backup ttl.json"))
        validate_export(_json_loads(payloads["policy/export.json"], "backup policy export"))
        _validate_config_text(payloads["config/approval-manager.conf"], "backup configuration")
        return payloads
    except (OSError, tarfile.TarError, gzip.BadGzipFile, EOFError) as error:
        raise LifecycleError(f"cannot read backup archive: {error}") from error


def extract_backup(backup_path: Path, staging_dir: Path) -> None:
    payloads = read_backup(backup_path)
    if staging_dir.exists() or staging_dir.is_symlink():
        raise LifecycleError("staging directory must not already exist")
    staging_dir.mkdir(mode=0o700, parents=False)
    for name, data in payloads.items():
        target = staging_dir / name
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        _atomic_replace(target, data)
    _fsync_directory(staging_dir)


def _load_targets(targets_path: Path) -> dict[str, Path]:
    raw, _ = _read_regular(targets_path, "restore targets")
    values = _json_loads(raw, "restore targets")
    if not isinstance(values, dict) or set(values) != TARGET_KEYS:
        raise LifecycleError("restore targets must contain exactly config, ttl, and policy")
    result: dict[str, Path] = {}
    for key, value in values.items():
        if not isinstance(value, str) or not os.path.isabs(value):
            raise LifecycleError(f"restore target {key} must be an absolute path")
        if "00-system.rules" in value or ".." in Path(value).parts:
            raise LifecycleError(f"restore target {key} is outside the safe path allowlist")
        result[key] = Path(value)
    if len(set(result.values())) != len(result):
        raise LifecycleError("restore targets must be distinct")
    return result


def _read_target(path: Path) -> bytes | None:
    try:
        data, _ = _read_regular(path, f"restore target {path}", MAX_DOCUMENT_SIZE)
        return data
    except LifecycleError as error:
        if not path.exists() and not path.is_symlink():
            return None
        raise error


def _write_json_atomic(path: Path, document: dict[str, Any]) -> None:
    raw = (json.dumps(document, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
    _atomic_replace(path, raw)


def _load_journal(journal_path: Path) -> dict[str, Any]:
    raw, info = _read_regular(journal_path, "restore journal")
    if stat.S_IMODE(info.st_mode) != 0o600:
        raise LifecycleError("restore journal must have mode 0600")
    document = _json_loads(raw, "restore journal")
    keys = {"schema_version", "transaction_id", "status", "targets"}
    if not isinstance(document, dict) or set(document) != keys:
        raise LifecycleError("restore journal has an invalid shape")
    if type(document["schema_version"]) is not int or document["schema_version"] != 1:
        raise LifecycleError("unsupported restore journal schema_version")
    try:
        transaction_id = document["transaction_id"]
        if str(uuid.UUID(transaction_id)) != transaction_id or uuid.UUID(transaction_id).version != 4:
            raise ValueError
    except (AttributeError, TypeError, ValueError) as error:
        raise LifecycleError("restore journal transaction ID is invalid") from error
    if not isinstance(document["status"], str) or document["status"] not in {
        "in_progress",
        "recovery_required",
    }:
        raise LifecycleError("restore journal has an invalid status")
    if not isinstance(document["targets"], list) or not document["targets"]:
        raise LifecycleError("restore journal has no targets")
    return document


def _verify_journal_targets(
    journal: dict[str, Any], targets: dict[str, Path]
) -> dict[str, dict[str, Any]]:
    entries: dict[str, dict[str, Any]] = {}
    for entry in journal["targets"]:
        expected_keys = {
            "key",
            "path",
            "had_previous",
            "previous_sha256",
            "desired_sha256",
            "rollback_name",
            "progress",
        }
        if not isinstance(entry, dict) or set(entry) != expected_keys:
            raise LifecycleError("restore journal target has an invalid shape")
        key = entry["key"]
        if (
            not isinstance(key, str)
            or key not in TARGET_KEYS
            or key in entries
            or not isinstance(entry["path"], str)
            or entry["path"] != str(targets[key])
        ):
            raise LifecycleError("restore journal contains a target outside the current allowlist")
        if (
            type(entry["had_previous"]) is not bool
            or entry["rollback_name"] != f"{key}.rollback"
            or not isinstance(entry["progress"], str)
            or entry["progress"] not in {"prepared", "replaced", "restored"}
        ):
            raise LifecycleError("restore journal target metadata is invalid")
        for hash_name in ("previous_sha256", "desired_sha256"):
            digest = entry[hash_name]
            if digest is not None and (
                not isinstance(digest, str)
                or len(digest) != 64
                or any(char not in "0123456789abcdef" for char in digest)
            ):
                raise LifecycleError("restore journal contains an invalid hash")
        if entry["had_previous"] != (entry["previous_sha256"] is not None):
            raise LifecycleError("restore journal previous-state metadata is inconsistent")
        entries[key] = entry
    if set(entries) != TARGET_KEYS:
        raise LifecycleError("restore journal does not cover the complete target allowlist")
    return entries


def _current_hash(path: Path) -> str | None:
    data = _read_target(path)
    return None if data is None else _sha256(data)


def _rollback_transaction(
    journal_path: Path,
    rollback_dir: Path,
    journal: dict[str, Any],
    targets: dict[str, Path],
) -> None:
    entries = _verify_journal_targets(journal, targets)
    for key in ("policy", "ttl", "config"):
        entry = entries[key]
        target = targets[key]
        current_hash = _current_hash(target)
        previous_hash = entry["previous_sha256"]
        desired_hash = entry["desired_sha256"]
        if current_hash == previous_hash:
            continue
        if current_hash != desired_hash:
            raise LifecycleError(
                f"restore target {key} has an unexpected hash; preserving journal and evidence"
            )
        if entry["had_previous"]:
            rollback_path = rollback_dir / entry["rollback_name"]
            rollback_data, _ = _read_regular(rollback_path, f"{key} rollback copy")
            if _sha256(rollback_data) != previous_hash:
                raise LifecycleError(f"{key} rollback copy failed integrity verification")
            _atomic_replace(target, rollback_data)
        else:
            target.unlink()
            _fsync_directory(target.parent)
        if _current_hash(target) != previous_hash:
            raise LifecycleError(f"failed to verify rollback for {key}")
    _remove_journal(journal_path)


def _remove_journal(journal_path: Path) -> None:
    try:
        journal_path.unlink()
        _fsync_directory(journal_path.parent)
    except OSError as error:
        raise LifecycleError(f"could not durably remove restore journal: {error}") from error


def apply_restore(
    journal_path: Path,
    rollback_dir: Path,
    targets_path: Path,
    staged_dir: Path,
) -> None:
    targets = _load_targets(targets_path)
    if journal_path.exists() or journal_path.is_symlink():
        raise LifecycleError("restore journal already exists; use --recover")
    if staged_dir.is_symlink() or not staged_dir.is_dir():
        raise LifecycleError("restore staging directory is unsafe")
    sources = {
        "config": staged_dir / "config/approval-manager.conf",
        "ttl": staged_dir / "state/ttl.json",
        "policy": staged_dir / "policy/rules.conf",
    }
    desired: dict[str, bytes] = {}
    for key, path in sources.items():
        desired[key], _ = _read_regular(path, f"staged {key}")
    ttl_state = validate_ttl_state(_json_loads(desired["ttl"], "staged ttl.json"))
    for record in ttl_state["records"]:
        if record["status"] in {"pending", "active", "inconsistent"}:
            record["status"] = "recovery_required"
    desired["ttl"] = (
        json.dumps(ttl_state, sort_keys=True, separators=(",", ":")) + "\n"
    ).encode("utf-8")
    validate_ttl_state(_json_loads(desired["ttl"], "restored ttl.json"))

    if rollback_dir.is_symlink():
        raise LifecycleError("restore rollback directory must not be a symbolic link")
    rollback_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not rollback_dir.is_dir() or stat.S_IMODE(rollback_dir.stat().st_mode) != 0o700:
        raise LifecycleError("restore rollback directory must have mode 0700")
    transaction_id = str(uuid.uuid4())
    rollback_dir = rollback_dir / transaction_id
    rollback_dir.mkdir(mode=0o700)

    entries: list[dict[str, Any]] = []
    for key in ("config", "ttl", "policy"):
        target = targets[key]
        previous = _read_target(target)
        previous_hash = None if previous is None else _sha256(previous)
        rollback_name = f"{key}.rollback"
        if previous is not None:
            _atomic_replace(rollback_dir / rollback_name, previous)
        entries.append(
            {
                "key": key,
                "path": str(target),
                "had_previous": previous is not None,
                "previous_sha256": previous_hash,
                "desired_sha256": _sha256(desired[key]),
                "rollback_name": rollback_name,
                "progress": "prepared",
            }
        )
    journal = {
        "schema_version": 1,
        "transaction_id": transaction_id,
        "status": "in_progress",
        "targets": entries,
    }
    _write_json_atomic(journal_path, journal)

    try:
        for key in ("policy", "ttl", "config"):
            _atomic_replace(targets[key], desired[key])
            entries_by_key = {entry["key"]: entry for entry in journal["targets"]}
            entries_by_key[key]["progress"] = "replaced"
            _write_json_atomic(journal_path, journal)
        for key in ("config", "ttl", "policy"):
            if _current_hash(targets[key]) != _sha256(desired[key]):
                raise LifecycleError(f"restore verification failed for {key}")
        _remove_journal(journal_path)
    except Exception as error:
        try:
            _rollback_transaction(journal_path, rollback_dir, journal, targets)
        except Exception as rollback_error:
            journal["status"] = "recovery_required"
            try:
                _write_json_atomic(journal_path, journal)
                journal_error = ""
            except Exception as journal_write_error:
                journal_error = f"; journal update also failed ({journal_write_error})"
            raise LifecycleError(
                f"restore failed ({error}); rollback requires --recover "
                f"({rollback_error}){journal_error}"
            ) from error
        raise LifecycleError(f"restore failed and was rolled back: {error}") from error


def recover_restore(journal_path: Path, rollback_root: Path, targets_path: Path) -> None:
    targets = _load_targets(targets_path)
    if not journal_path.exists() or journal_path.is_symlink():
        raise LifecycleError("restore journal is missing or unsafe")
    journal = _load_journal(journal_path)
    _verify_journal_targets(journal, targets)
    rollback_dir = rollback_root / journal["transaction_id"]
    if rollback_dir.is_symlink() or not rollback_dir.is_dir():
        raise LifecycleError("restore rollback evidence is missing or unsafe")
    try:
        _rollback_transaction(journal_path, rollback_dir, journal, targets)
    except Exception as error:
        journal["status"] = "recovery_required"
        try:
            _write_json_atomic(journal_path, journal)
            journal_error = ""
        except Exception as journal_write_error:
            journal_error = f"; journal update also failed ({journal_write_error})"
        raise LifecycleError(
            f"restore recovery is incomplete ({error}){journal_error}"
        ) from error


def validate_export_file(path: Path) -> dict[str, Any]:
    raw, _ = _read_regular(path, "import JSON")
    return validate_export(_json_loads(raw, "import JSON"))


def _parse_args(arguments: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    backup = subparsers.add_parser("backup-create")
    backup.add_argument("--config", type=Path, required=True)
    backup.add_argument("--ttl", type=Path, required=True)
    backup.add_argument("--export", type=Path, required=True)
    backup.add_argument("--directory", type=Path, required=True)
    backup.add_argument("--keep", type=int, required=True)

    extract = subparsers.add_parser("backup-extract")
    extract.add_argument("--backup", type=Path, required=True)
    extract.add_argument("--staging", type=Path, required=True)

    apply = subparsers.add_parser("restore-apply")
    apply.add_argument("--journal", type=Path, required=True)
    apply.add_argument("--rollback-root", type=Path, required=True)
    apply.add_argument("--targets", type=Path, required=True)
    apply.add_argument("--staging", type=Path, required=True)

    recover = subparsers.add_parser("restore-recover")
    recover.add_argument("--journal", type=Path, required=True)
    recover.add_argument("--rollback-root", type=Path, required=True)
    recover.add_argument("--targets", type=Path, required=True)

    validate = subparsers.add_parser("validate-export")
    validate.add_argument("--file", type=Path, required=True)

    validate_backup = subparsers.add_parser("validate-backup")
    validate_backup.add_argument("--backup", type=Path, required=True)
    return parser.parse_args(arguments)


def main(arguments: list[str] | None = None) -> int:
    options = _parse_args(sys.argv[1:] if arguments is None else arguments)
    try:
        if options.command == "backup-create":
            print(
                create_backup(
                    options.config, options.ttl, options.export, options.directory, options.keep
                )
            )
        elif options.command == "backup-extract":
            extract_backup(options.backup, options.staging)
        elif options.command == "restore-apply":
            apply_restore(
                options.journal, options.rollback_root, options.targets, options.staging
            )
        elif options.command == "restore-recover":
            recover_restore(options.journal, options.rollback_root, options.targets)
        elif options.command == "validate-export":
            print(json.dumps(validate_export_file(options.file), ensure_ascii=False))
        elif options.command == "validate-backup":
            read_backup(options.backup)
        return 0
    except (LifecycleError, OSError, ValueError) as error:
        print(f"lifecycle: ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
