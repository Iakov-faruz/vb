#!/usr/bin/env python3
"""Write one JSON document atomically with file and directory fsync.

סקירה כללית — מה הקובץ עושה?
מודול/כלי זה מבצע כתיבה אטומית של מסמך JSON לקובץ יעד:
1. מאמת את ה-JSON (תחביר, ללא NaN/Infinity, ללא מפתחות כפולים, מגבלת גודל).
2. כותב לקובץ זמני באותה תיקייה (O_EXCL למניעת מרוץ/התקפת symlink).
3. מבצע fsync לקובץ, rename אטומי (os.replace), ואז fsync לתיקייה.
4. מטפל בשגיאות ומדווח אם היעד הוחלף אך העמידות (durability) לא ודאית.

למה זה חיוני?
כתיבה רגילה עלולה להשאיר קובץ פגום במקרה של קריסה באמצע. כאן מקבלים
"או תוכן ישן שלם, או תוכן חדש שלם" — ובנוסף זיהוי מצב חריג שבו rename הצליח
אבל fsync של התיקייה נכשל (replaced=True בחריגה).
"""

from __future__ import annotations

import argparse
import json
import os
import secrets
import stat
import sys
from pathlib import Path

# הרשאות קובץ ברירת מחדל: קריאה/כתיבה לבעלים בלבד (מונע חשיפת מצב רגיש).
FILE_MODE = 0o600
# מספר ניסיונות למציאת שם קובץ זמני ייחודי באותה תיקייה.
TEMP_ATTEMPTS = 10
# הגבלת גודל מסמך למניעת שימוש יתר בזיכרון/קלט חריג (1 MiB).
MAX_JSON_SIZE = 1 * 1024 * 1024


class AtomicWriteError(Exception):
    """חריגת כתיבה אטומית; replaced מציין האם rename ליעד כבר הושלם."""

    def __init__(self, message: str, *, replaced: bool = False) -> None:
        super().__init__(message)
        # replaced=True חשוב: היעד *הוחלף*, אך ייתכן שהעמידות לא מובטחת
        # (למשל fsync לתיקייה נכשל). קוראים חייבים להתייחס לכך כמצב רגיש.
        self.replaced = replaced


def _reject_json_constant(value: str) -> None:
    """דחיית קבועי JSON לא תקניים כמו NaN/Infinity/-Infinity."""
    # ברירת המחדל של json.loads בפייתון מקבלת ערכים שאינם JSON תקני.
    raise ValueError(f"invalid JSON constant: {value}")


def write_all(fd: int, payload: bytes) -> None:
    """כתיבת כל הבתים ל-file descriptor תוך טיפול בכתיבות חלקיות."""
    # os.write עלול לכתוב פחות מהמבוקש; memoryview מאפשר התקדמות ללא העתקות.
    view = memoryview(payload)
    while view:
        written = os.write(fd, view)
        if written <= 0:
            # לא נכתב דבר — מצב חריג/כשל כתיבה.
            raise OSError("failed to complete file write")
        view = view[written:]


def _reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    """דחיית מסמכי JSON עם מפתחות כפולים (מונע עמימות/עקיפת ולידציה)."""
    # ברירת מחדל של json: "האחרון מנצח" — מסוכן בהקשרי אבטחה/מצב.
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def validate_json_document(document: str) -> None:
    """ולידציה של מסמך JSON: קידוד UTF-8, גודל, תחביר וחוקי מבנה מחמירים."""
    try:
        encoded = document.encode("utf-8")
    except UnicodeEncodeError as error:
        raise AtomicWriteError("input contains invalid Unicode text") from error
    if len(encoded) > MAX_JSON_SIZE:
        raise AtomicWriteError(f"input exceeds maximum JSON size of {MAX_JSON_SIZE} bytes")
    try:
        json.loads(
            document,
            parse_constant=_reject_json_constant,      # דחיית NaN/Infinity
            object_pairs_hook=_reject_duplicate_keys, # דחיית מפתחות כפולים
        )
    except (json.JSONDecodeError, ValueError) as error:
        raise AtomicWriteError(f"input is not valid JSON: {error}") from error


def _create_temp_file(directory_fd: int, target_name: str) -> tuple[int, str]:
    """יצירת קובץ זמני ייחודי בתיקיית היעד באמצעות O_EXCL.

    פתיחה יחסית ל-directory_fd מפחיתה סיכוני TOCTOU על נתיב התיקייה.
    """
    # O_EXCL+O_CREAT: יצירה רק אם לא קיים (אטומי).
    # O_NOFOLLOW: הגנה מפני מעקב אחרי symlink בשם הזמני.
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    flags |= getattr(os, "O_NOFOLLOW", 0)

    for _ in range(TEMP_ATTEMPTS):
        # טוקן אקראי קריפטוגרפית לשם זמני ייחודי.
        temp_name = f".{target_name}.{secrets.token_hex(8)}.tmp"
        try:
            file_fd = os.open(
                temp_name,
                flags,
                FILE_MODE,
                dir_fd=directory_fd,
            )
        except FileExistsError:
            # התנגשיות נדירה — מנסים שוב עם שם אחר.
            continue
        try:
            # אכיפת הרשאות גם אם umask של התהליך שונה.
            os.fchmod(file_fd, FILE_MODE)
        except OSError:
            os.close(file_fd)
            os.unlink(temp_name, dir_fd=directory_fd)
            raise
        return file_fd, temp_name

    raise AtomicWriteError("could not reserve a unique temporary file")


def atomic_write_json(target_path: str | os.PathLike[str], document: str) -> None:
    """אימות והחלפה אטומית של target_path במסמך JSON שסופק.

    הזרימה: ולידציה → כתיבה לקובץ זמני → fsync(file) → os.replace → fsync(dir).
    במקרה של כשל לאחר replace, החריגה תכלול replaced=True כדי לסמן חוסר ודאות
    בעמידות הנתונים על הדיסק.
    """
    validate_json_document(document)
    try:
        payload = document.encode("utf-8")
    except UnicodeEncodeError as error:
        raise AtomicWriteError("input contains invalid Unicode text") from error

    target = Path(target_path)
    # הגנה מפני שמות יעד לא תקינים.
    if target.name in ("", ".", ".."):
        raise AtomicWriteError("target must name a file")

    try:
        # resolve(strict=True): תיקיית האב חייבת להתקיים בפועל.
        parent = target.parent.resolve(strict=True)
        directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
        # פתיחת FD לתיקייה מאפשרת פעולות rename/unlink/fsync יחסיות ובטוחות יותר.
        directory_fd = os.open(parent, directory_flags)
    except OSError as error:
        raise AtomicWriteError("target directory is unavailable") from error

    temp_name: str | None = None
    replaced = False
    try:
        # --- בדיקת יעד קיים ---
        try:
            existing = os.stat(
                target.name,
                dir_fd=directory_fd,
                follow_symlinks=False,  # לא עוקבים אחרי symlink על היעד
            )
        except FileNotFoundError:
            existing = None

        if existing is not None:
            # סירוב להחליף symlink מונע תקיפת הפניית כתיבה לקובץ רגיש אחר.
            if stat.S_ISLNK(existing.st_mode):
                raise AtomicWriteError("refusing to replace a symbolic link")
            if not stat.S_ISREG(existing.st_mode):
                raise AtomicWriteError("target is not a regular file")

        # --- כתיבה לקובץ זמני והבטחת עמידות ---
        file_fd, temp_name = _create_temp_file(directory_fd, target.name)
        try:
            write_all(file_fd, payload)
            # fsync לקובץ מבטיח שהתוכן נכתב למדיה לפני rename.
            os.fsync(file_fd)
        finally:
            os.close(file_fd)

        # --- החלפה אטומית בשם הקובץ ---
        # rename/replace אטומי: הקורא יראה או את הישן או את החדש, לא מצב ביניים.
        os.replace(
            temp_name,
            target.name,
            src_dir_fd=directory_fd,
            dst_dir_fd=directory_fd,
        )
        replaced = True
        temp_name = None  # הקובץ הזמני הוחלף; אין צורך בניקוי ב-finally.

        # fsync לתיקייה מבטיח שהמטא-דאטה של ה-rename עמידה.
        # כשל כאן = הקובץ החדש גלוי אך durability לא ודאית.
        os.fsync(directory_fd)
    except AtomicWriteError:
        raise
    except OSError as error:
        state = (
            "target was replaced but durability is uncertain"
            if replaced
            else "target was not replaced"
        )
        raise AtomicWriteError(
            f"{state}: {error.strerror or error}",
            replaced=replaced,
        ) from error
    finally:
        try:
            if temp_name is not None:
                # ניקוי קובץ זמני אם לא הגענו ל-replace מוצלח.
                os.unlink(temp_name, dir_fd=directory_fd)
        except FileNotFoundError:
            pass
        finally:
            os.close(directory_fd)


def _parse_args(arguments: list[str]) -> argparse.Namespace:
    """פרסור ארגומנטים לכלי ה-CLI.

    ארגומנטים:
    - --file: נתיב קובץ היעד (חובה).
    - --data: מסמך JSON לכתיבה (חובה במצב כתיבה).
    - --validate-only: אימות קובץ קיים בלבד, ללא שינוי תוכן.
    """
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--file", required=True, help="target file path")
    parser.add_argument("--data", help="JSON document to write")
    parser.add_argument(
        "--validate-only",
        action="store_true",
        help="validate the existing file without modifying it",
    )
    return parser.parse_args(arguments)


def main(arguments: list[str] | None = None) -> int:
    """נקודת כניסה ל-CLI: כתיבה אטומית או ולידציה בלבד (--validate-only).

    קודי יציאה:
    - 0: הצלחה (כתיבה הושלמה או הוולידציה עברה).
    - 1: כשל בזמן ריצה/ולידציה/כתיבה (קובץ לא זמין, JSON לא תקין וכו').
    - 2: שימוש שגוי בארגומנטים (שילוב לא חוקי או חוסר --data במצב כתיבה).
    """
    # אם לא הועברו ארגומנטים במפורש (קריאה פנימית), נשתמש ב-argv של התהליך.
    options = _parse_args(sys.argv[1:] if arguments is None else arguments)

    # --- מצב validate-only: אימות קובץ קיים ללא שינוי ---
    if options.validate_only:
        # במצב זה אסור להעביר --data: אין כתיבה, ורצוי למנוע דו-משמעות.
        if options.data is not None:
            print(
                "atomic-write: ERROR: --data cannot be used with --validate-only",
                file=sys.stderr,
            )
            return 2
        try:
            # פתיחה לקריאה בלבד עם O_NOFOLLOW כדי לא לקרוא דרך symlink.
            file_fd = os.open(
                options.file,
                os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
            )
        except OSError as error:
            # כשל פתיחה (לא קיים/אין הרשאות/נתיב בעייתי וכו').
            print(f"atomic-write: ERROR: {error}", file=sys.stderr)
            return 1
        try:
            # אימות שסוג היעד הוא קובץ רגיל (לא תיקייה/התקן/symlink וכו').
            file_stat = os.fstat(file_fd)
            if not stat.S_ISREG(file_stat.st_mode):
                print("atomic-write: ERROR: target is not a regular file", file=sys.stderr)
                return 1

            # קוראים עד MAX_JSON_SIZE+1 כדי לזהות חריגה מגודל מותר בלי לטעון קובץ ענק.
            raw = os.read(file_fd, MAX_JSON_SIZE + 1)
            if len(raw) > MAX_JSON_SIZE:
                print("atomic-write: ERROR: input exceeds maximum JSON size", file=sys.stderr)
                return 1

            # פענוח UTF-8 לפני ולידציית JSON (אותה שגיאת קידוד שמזוהה גם בכתיבה).
            try:
                document = raw.decode("utf-8")
            except UnicodeDecodeError as error:
                print(f"atomic-write: ERROR: {error}", file=sys.stderr)
                return 1

            # ולידציה לוגית/תחבירית של תוכן ה-JSON לפי הכללים המחמירים של המודול.
            validate_json_document(document)
        except (OSError, AtomicWriteError) as error:
            # שגיאות קריאה/פענוח/ולידציה מדווחות ככשל כללי של הכלי.
            print(f"atomic-write: ERROR: {error}", file=sys.stderr)
            return 1
        finally:
            # סגירת ה-FD בכל מקרה למניעת דליפת משאבים.
            os.close(file_fd)
        # הגעת לכאן משמעה שהקובץ תקין לפי בדיקות validate-only.
        return 0

    # --- מצב כתיבה רגיל ---
    # במצב כתיבה חובה לספק את תוכן ה-JSON דרך --data.
    if options.data is None:
        print("atomic-write: ERROR: --data is required unless using --validate-only", file=sys.stderr)
        return 2
    try:
        # ביצוע הכתיבה האטומית (כולל ולידציה פנימית ו-fsync לקובץ/תיקייה).
        atomic_write_json(options.file, options.data)
    except AtomicWriteError as error:
        # כל כשל כתיבה/ולידציה/עמידות מוחזר כקוד 1 עם פירוט השגיאה.
        # אם replace בוצע אך durability לא ודאית, ההודעה תכיל זאת (replaced=True).
        print(f"atomic-write: ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    # הרצה ישירה: ממירים את קוד ההחזרה של main לקוד יציאה של התהליך.
    raise SystemExit(main())