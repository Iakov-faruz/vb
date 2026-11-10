#!/usr/bin/env python3
"""Append one validated Audit JSONL record to the protected Audit log.

סקירה כללית — מה הקובץ עושה?
כלי/מודול זה מוסיף רשומת Audit אחת בפורמט JSONL לקובץ לוג מוגן.
המטרה: תיעוד מובנה ועמיד של פעולות (מי ביצע, מה הפעולה, תוצאה, correlation_id).

עקרונות מרכזיים:
- ולידציה מחמירה של שדות (אורך, תווים אסורים, ערכי policy_result מותרים).
- אימות הרשאות/בעלות של תיקיית וקובץ ה-Audit לפני כתיבה.
- פתיחה בטוחה (O_APPEND, O_NOFOLLOW, O_CLOEXEC) ומניעת symlink attacks.
- כתיבה עמידה: flush + fsync לאחר הוספת הרשומה.

הערה חשובה:
ה-docstring ההיסטורי הזכיר כתיבה דרך atomic-write.py, אך בפועל כאן מתבצעת
הוספה (append) ל-JSONL עם O_APPEND+fsync — וזה מתאים ליומן append-only.
שגיאת כתיבת Audit חייבת להיות מדווחת, תוך שמירה על תוצאת המדיניות שכבר בוצעה.
"""

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

# --- מדיניות Audit קשיחה (לא מקונפיגורציה) ---
# נתיב ותכונות הקובץ נקבעים בקוד כדי להקטין תלות בקונפיג חיצוני.
AUDIT_DIRECTORY = Path("/var/log/usbguard-approval-manager")
AUDIT_FILE = AUDIT_DIRECTORY / "audit.jsonl"
AUDIT_GROUP = "usbadmins"
AUDIT_UID = 0                       # root
DIRECTORY_MODE = 0o750              # rwxr-x--- (root:usbadmins)
FILE_MODE = 0o640                   # rw-r----- (root:usbadmins)

# מגבלות אורך לשדות — מונעות רשומות חריגות/שימוש לרעה.
FIELD_LIMITS = {
    "action": 128,
    "policy_result": 64,
    "correlation_id": 128,
    "details": 4096,
}
# סטטוסים חוקיים לתוצאת מדיניות (רשימה סגורה).
POLICY_RESULTS = {"applied", "not_applied", "unknown", "not_applicable"}


class AuditWriteError(Exception):
    """חריגה המייצגת כשל בכתיבת רשומת Audit בצורה בטוחה."""


def _reject_json_constant(value: str) -> NoReturn:
    """דחיית קבועי JSON לא תקניים (למשל NaN/Infinity) אם יופיעו בסריאליזציה."""
    raise ValueError(f"invalid JSON constant: {value}")


def _validated_text(name: str, value: str, *, allow_empty: bool = False) -> str:
    """ולידציה של שדה טקסטואלי: אי-ריק (לפי הצורך), אורך מרבי, וללא תווי שליטה."""
    if not allow_empty and not value:
        raise AuditWriteError(f"{name} must not be empty")
    if len(value) > FIELD_LIMITS[name]:
        raise AuditWriteError(f"{name} exceeds its maximum length")
    # תווי שליטה עלולים לשבור מבנה JSONL או להקשות על עיבוד לוגים.
    if any(ord(character) < 32 or ord(character) == 127 for character in value):
        raise AuditWriteError(f"{name} must not contain control characters")
    return value


def _actor_uid() -> int | str:
    """זיהוי ה-UID של המבצע לצורך Audit.

    אם הריצה דרך sudo, SUDO_UID מייצג לרוב את המשתמש המקורי — עדיף לתיעוד.
    """
    sudo_uid = os.environ.get("SUDO_UID", "")
    if re.fullmatch(r"[0-9]+", sudo_uid):
        return int(sudo_uid)
    try:
        return os.getuid()
    except AttributeError:
        return "unknown"


def _check_directory(group_id: int) -> None:
    """אימות תיקיית ה-Audit: קיימת, ספרייה, בעלות והרשאות כפי שנדרש."""
    try:
        # lstat: לא עוקבים אחרי symlink על התיקייה עצמה.
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
    """פתיחה/יצירה בטוחה של קובץ ה-Audit עם בדיקות הרשאות מחמירות.

    - אם הקובץ לא קיים: נוצר עם O_EXCL ונקבעים בעלות/הרשאות.
    - אם קיים: נפתח ב-O_APPEND ונבדק שהוא קובץ רגיל עם הרשאות נכונות.
    """
    flags = os.O_WRONLY | os.O_APPEND | os.O_CREAT
    flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)

    try:
        # ניסיון יצירה אטומי של קובץ חדש.
        file_fd = os.open(AUDIT_FILE, flags | os.O_EXCL, FILE_MODE)
        created = True
    except FileExistsError:
        try:
            # קובץ קיים — פתיחה להוספה בלבד (ללא יצירה).
            file_fd = os.open(AUDIT_FILE, flags & ~os.O_CREAT, FILE_MODE)
            created = False
        except OSError as error:
            raise AuditWriteError("Audit file could not be opened safely") from error
    except OSError as error:
        raise AuditWriteError("Audit file could not be opened safely") from error

    try:
        if created:
            # קובץ חדש: קביעת בעלות והרשאות מפורשות (לא מסתמכים רק על umask).
            os.fchown(file_fd, AUDIT_UID, group_id)
            os.fchmod(file_fd, FILE_MODE)

        info = os.fstat(file_fd)
        if not stat.S_ISREG(info.st_mode):
            raise AuditWriteError("Audit target is not a regular file")
        # אימות הרשאות גם לקובץ קיים — מונע כתיבה ליעד שהוחלש/הוחלף בצורה לא בטוחה.
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
    """ולידציה, בניית רשומת Audit והוספה עמידה (append+flush+fsync) לקובץ JSONL."""
    # --- שלב 1: ולידציה של השדות ---
    action = _validated_text("action", action)
    policy_result = _validated_text("policy_result", policy_result)
    if policy_result not in POLICY_RESULTS:
        raise AuditWriteError("policy_result is not a supported status")
    correlation_id = _validated_text("correlation_id", correlation_id)
    details = _validated_text("details", details, allow_empty=True)

    # --- שלב 2: אימות קבוצת מערכת ותיקיית Audit ---
    try:
        group_id = grp.getgrnam(AUDIT_GROUP).gr_gid
    except KeyError as error:
        raise AuditWriteError("required Audit group is unavailable") from error
    _check_directory(group_id)

    # --- שלב 3: בניית הרשומה לפי שדות ה-SRS ---
    record = {
        # חותמת זמן ב-UTC בפורמט ISO 8601 עם 'Z'.
        "timestamp_utc": dt.datetime.now(dt.timezone.utc)
        .isoformat(timespec="seconds")
        .replace("+00:00", "Z"),
        "actor_uid": _actor_uid(),
        "action": action,
        "policy_result": policy_result,
        "correlation_id": correlation_id,
        "details": details,
    }

    # --- שלב 4: סריאליזציה ל-JSON קומפקטי בשורה אחת (JSONL) ---
    try:
        payload = (
            json.dumps(
                record,
                ensure_ascii=False,    # שומר טקסט UTF-8 קריא
                separators=(",", ":"), # ללא רווחים מיותרים
                allow_nan=False,       # אוסר NaN/Infinity
            )
            + "\n"
        ).encode("utf-8")
    except (TypeError, ValueError, UnicodeEncodeError) as error:
        raise AuditWriteError("Audit record could not be serialized") from error

    # --- שלב 5: כתיבה ועמידות בדיסק ---
    file_fd = _open_audit_file(group_id)
    try:
        # closefd=False כדי שנוכל לסגור את ה-FD במפורש ב-finally.
        with os.fdopen(file_fd, "ab", closefd=False) as audit_file:
            audit_file.write(payload)
            audit_file.flush()     # ריקון buffer של ספריית Python
            os.fsync(file_fd)      # הבטחת כתיבה למדיה (durability)
    except OSError as error:
        raise AuditWriteError("Audit record could not be durably written") from error
    finally:
        os.close(file_fd)


def _parse_args(arguments: list[str]) -> argparse.Namespace:
    """פרסור ארגומנטים ל-CLI של כתיבת Audit.

    כל השדות הלוגיים של הרשומה מתקבלים כארגומנטים נפרדים כדי לאפשר ולידציה
    ברורה לפני סריאליזציה וכתיבה לקובץ ה-JSONL המוגן.
    """
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--action", required=True)
    parser.add_argument("--policy-result", required=True)
    parser.add_argument("--correlation-id", required=True)
    parser.add_argument("--details", default="")
    return parser.parse_args(arguments)


def main(arguments: list[str] | None = None) -> int:
    """נקודת כניסה ל-CLI: הוספת רשומת Audit אחת לפי ארגומנטים שסופקו.

    קודי יציאה:
    - 0: הרשומה נכתבה בהצלחה (כולל fsync).
    - 1: כשל ולידציה/הרשאות/גישה/כתיבה — מפורט ב-stderr.
    """
    # שימוש בארגומנטים שהועברו פנימית או ב-argv של התהליך.
    options = _parse_args(sys.argv[1:] if arguments is None else arguments)
    try:
        # בניית הרשומה וכתיבתה העמידה לקובץ ה-Audit.
        append_audit_record(
            options.action,
            options.policy_result,
            options.correlation_id,
            options.details,
        )
    except AuditWriteError as error:
        # כשל Audit מדווח במפורש כדי שהקורא (למשל סקריפט Bash) ידע לטפל בכך.
        print(f"audit: ERROR: {error}", file=sys.stderr)
        return 1
    # הצלחה: הרשומה סוריאלזה ונוספה בצורה עמידה.
    return 0


if __name__ == "__main__":
    # המרת קוד ההחזרה של main לקוד יציאה של התהליך.
    raise SystemExit(main())