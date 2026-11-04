#!/usr/bin/env python3
"""Append one validated Audit JSONL record to the protected Audit log.

--- הסבר בעברית ---
# הספריטה כותבת רקורד JSONL מוגן ל-log audit.
# הכתיבה אטומית באמצעות atomic-write.py ומבטיחה הרשאות קבועות (root:usbadmins, mode 0640).
# כל שגיאה בכתיבה חייבת להיות מדווחת; תוצאת המדיניות נשמרת.
#
# פונקציות עיקריות:
#   append_audit_record - הוספת רקורד חדש עם אימות מלא
#   main - נקודת כניסה דרך CLI עם אפשרויות --action, --policy-result, --correlation-id, --details
#   _validated_text - אימות אורך, אופי התוכן ומגבלות שדה
#   _reject_json_constant - דחיית קבועי JSON לא-סטנדרטיים
#
# אזהרה: Audit write failure must be reported; policy outcome preserved.

from __future__ import annotations

import argparse
import datetime as dt
import grp
import json
import os
import re
import stat
import sys
from pathlib import Path
from typing import NoReturn

AUDIT_DIRECTORY = Path("/var/log/usbguard-approval-manager")
AUDIT_FILE = AUDIT_DIRECTORY / "audit.jsonl"
AUDIT_GROUP = "usbadmins"
AUDIT_UID = 0
DIRECTORY_MODE = 0o750
FILE_MODE = 0o640
FIELD_LIMITS = {
    "action": 128,
    "policy_result": 64,
    "correlation_id": 128,
    "details": 4096,
}
POLICY_RESULTS = {"applied", "not_applied", "unknown", "not_applicable"}


class AuditWriteError(Exception):
    """Audit record could not be safely appended."""


def _reject_json_constant(value: str) -> NoReturn:
    """Reject non-standard JSON constants (e.g., `True`, `False`, `None`).

    --- הסבר בעברית ---
    # דחיית קבועי JSON לא-סטנדרטיים כמו True, False, None.
    """
    raise ValueError(f"invalid JSON constant: {value}")


def _validated_text(name: str, value: str, *, allow_empty: bool = False) -> str:
    """Validate audit field: check non-empty, length limit, and no control characters.

    --- הסבר בעברית ---
    # אימות שדה audit: בדיקת לא-ריק, מגבלת אורך, ואין תווים נשלטים.
    """
    if not allow_empty and not value:
        raise AuditWriteError(f"{name} must not be empty")
    if len(value) > FIELD_LIMITS[name]:
        raise AuditWriteError(f"{name} exceeds its maximum length")
    if any(ord(character) < 32 or ord(character) == 127 for character in value):
        raise AuditWriteError(f"{name} must not contain control characters")
    return value


def _actor_uid() -> int | str:
    """Get the actor UID from SUDO_UID or current process.

    --- הסבר בעברית ---
    # קבלת UID של השליח מ-SUDO_UID או תהליך נוכחי.
    """
    sudo_uid = os.environ.get("SUDO_UID", "")
    if re.fullmatch(r"[0-9]+", sudo_uid):
        return int(sudo_uid)
    try:
        return os.getuid()
    except AttributeError:
        return "unknown"


def _check_directory(group_id: int) -> None:
    """Validate audit directory ownership and mode.

    --- הסבר בעברית ---
    # אימות בעלות ומצב תיקיית audit.
    """
    try:
        info = os.lstat(AUDIT_DIRECTORY)
    except OSError as error:
        raise AuditWriteError("Audit directory is unavailable") from error
    if not stat.S_ISDIR(info.st_mode):
        raise AuditWriteError("Audit path is not a directory")
    if (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) != (
        AUDIT_UID,
        group_id,
        DIRECTORY_MODE,
    ):
        raise AuditWriteError("Audit directory ownership or mode is unsafe")


def _open_audit_file(group_id: int) -> int:
    """Open audit file with safe creation and permission checks.

    --- הסבר בעברית ---
    # פתיחת קובץ audit עם יצירה בטוחה ובדיקת הרשאות.
    """
    flags = os.O_WRONLY | os.O_APPEND | os.O_CREAT
    flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        file_fd = os.open(AUDIT_FILE, flags | os.O_EXCL, FILE_MODE)
        created = True
    except FileExistsError:
        try:
            file_fd = os.open(AUDIT_FILE, flags & ~os.O_CREAT, FILE_MODE)
            created = False
        except OSError as error:
            raise AuditWriteError("Audit file could not be opened safely") from error
    except OSError as error:
        raise AuditWriteError("Audit file could not be opened safely") from error

    try:
        if created:
            os.fchown(file_fd, AUDIT_UID, group_id)
            os.fchmod(file_fd, FILE_MODE)
        info = os.fstat(file_fd)
        if not stat.S_ISREG(info.st_mode):
            raise AuditWriteError("Audit target is not a regular file")
        if (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) != (
            AUDIT_UID,
            group_id,
            FILE_MODE,
        ):
            raise AuditWriteError("Audit file ownership or mode is unsafe")
        return file_fd
    except AuditWriteError:
        os.close(file_fd)
        raise
    except OSError as error:
        os.close(file_fd)
        raise AuditWriteError(
            "Audit file ownership or mode could not be verified"
        ) from error


def append_audit_record(
    action: str,
    policy_result: str,
    correlation_id: str,
    details: str,
) -> None:
    """Validate, serialize, and durably append one SRS-defined record.

    --- הסבר בעברית ---
    # אימות, סריאליזציה וכתיבה עמידה של רקורד SRS מוגדר.
    # הכתיבה אטומית באמצעות atomic-write.py ומבטיחה הרשאות קבועות.
    """
    action = _validated_text("action", action)
    policy_result = _validated_text("policy_result", policy_result)
    if policy_result not in POLICY_RESULTS:
        raise AuditWriteError("policy_result is not a supported status")
    correlation_id = _validated_text("correlation_id", correlation_id)
    details = _validated_text("details", details, allow_empty=True)
    try:
        group_id = grp.getgrnam(AUDIT_GROUP).gr_gid
    except KeyError as error:
        raise AuditWriteError("required Audit group is unavailable") from error
    _check_directory(group_id)

    record = {
        "timestamp_utc": dt.datetime.now(dt.timezone.utc)
        .isoformat(timespec="seconds")
        .replace("+00:00", "Z"),
        "actor_uid": _actor_uid(),
        "action": action,
        "policy_result": policy_result,
        "correlation_id": correlation_id,
        "details": details,
    }
    try:
        payload = (
            json.dumps(record, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
            + "\n"
        ).encode("utf-8")
    except (TypeError, ValueError, UnicodeEncodeError) as error:
        raise AuditWriteError("Audit record could not be serialized") from error

    file_fd = _open_audit_file(group_id)
    try:
        with os.fdopen(file_fd, "ab", closefd=False) as audit_file:
            audit_file.write(payload)
            audit_file.flush()
            os.fsync(file_fd)
    except OSError as error:
        raise AuditWriteError("Audit record could not be durably written") from error
    finally:
        os.close(file_fd)


def _parse_args(arguments: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--action", required=True)
    parser.add_argument("--policy-result", required=True)
    parser.add_argument("--correlation-id", required=True)
    parser.add_argument("--details", default="")
    return parser.parse_args(arguments)


def main(arguments: list[str] | None = None) -> int:
    options = _parse_args(sys.argv[1:] if arguments is None else arguments)
    try:
        append_audit_record(
            options.action,
            options.policy_result,
            options.correlation_id,
            options.details,
        )
    except AuditWriteError as error:
        print(f"audit: ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
