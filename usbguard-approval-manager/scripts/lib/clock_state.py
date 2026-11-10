#!/usr/bin/env python3
"""Validate clock-state.json and apply the SRS v4.5 clock-trust rules.

סקירה כללית — מה הקובץ עושה?
מודול/כלי זה מיישם את כללי אמינות השעון עבור TTL:
- קורא ומאמת clock_state.json (אם קיים) מול סכמת מפתחות וערכים מחמירה.
- מעריך את אמינות השעון הנוכחי לפי epoch, boottime, boot_id, ספק וסנכרון.
- מונע rollback/manipulation שעלולים להאריך TTL שלא כדין.
- כותב baseline/state חדש בצורה אטומית (דרך atomic-write.py) כשמתאים.

תוצאות אפשריות (stdout) וקודי יציאה:
- trusted_same_boot / trusted_after_reboot / baseline_initialized  -> exit 0
- untrusted_clock / recovery_required                              -> exit 9

רעיון מרכזי:
boottime (מונוטוני מאז boot) משמש עוגן נוסף ל-epoch. באותו boot בודקים שההפרש
בין דלתת epoch לדלתת boottime אינו חורג מהסף המותר (זיהוי "קפיצות שעון").
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import NoReturn, TypedDict

# גרסת סכמת מצב השעון הנתמכת.
SCHEMA_VERSION = 1
# קבוצת המפתחות החוקית בדיוק — מונע שדות חסרים/עודפים.
STATE_KEYS = {
    "schema_version",
    "last_trusted_epoch",
    "sync_provider",
    "sync_status",
    "boot_id",
    "last_trusted_boottime_seconds",
}
# שם ספק סנכרון מותר (תווים מוגבלים ואורך מרבי).
PROVIDER_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
# boot_id בפורמט UUID קנוני.
BOOT_ID_PATTERN = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)


class ClockStateError(Exception):
    """חריגה המייצגת בעיית קלט/גישה/כתיבה הקשורה למצב השעון."""


class ClockState(TypedDict):
    """מבנה לוגי של clock state תקין לאחר ולידציה."""

    schema_version: int
    last_trusted_epoch: int
    sync_provider: str
    sync_status: str
    boot_id: str
    last_trusted_boottime_seconds: int


def _reject_json_constant(value: str) -> NoReturn:
    """דחיית קבועי JSON לא תקניים (NaN/Infinity)."""
    raise ValueError(f"invalid JSON constant: {value}")


def _reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    """דחיית JSON עם מפתחות כפולים לשמירה על חד-משמעות."""
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _read_state(path: Path) -> ClockState | None:
    """קריאה וולידציה של קובץ המצב.

    מחזיר:
    - ClockState תקין
    - None אם אין קובץ או שהתוכן לא תקין/לא תואם סכימה (baseline יכול להידרש)
    זורק ClockStateError רק על בעיות גישה אמיתיות (I/O).
    """
    try:
        raw = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return None
    except OSError as error:
        raise ClockStateError("clock state is unavailable") from error

    try:
        state = json.loads(
            raw,
            parse_constant=_reject_json_constant,
            object_pairs_hook=_reject_duplicate_keys,
        )
    except (json.JSONDecodeError, UnicodeDecodeError, ValueError):
        # תוכן פגום/לא קריא — מתייחסים כאין state תקין.
        return None

    if not isinstance(state, dict) or set(state) != STATE_KEYS:
        return None

    schema_version = state["schema_version"]
    epoch = state["last_trusted_epoch"]
    boottime = state["last_trusted_boottime_seconds"]
    provider = state["sync_provider"]
    sync_status = state["sync_status"]
    boot_id = state["boot_id"]

    # type(...) is int — דוחה bool במכוון (bool הוא תת-מחלקה של int בפייתון).
    if type(schema_version) is not int or schema_version != SCHEMA_VERSION:
        return None
    if type(epoch) is not int or epoch <= 0:
        return None
    if type(boottime) is not int or boottime < 0:
        return None
    if not isinstance(provider, str) or not PROVIDER_PATTERN.fullmatch(provider):
        return None
    # נדרש סנכרון מפורש כדי לסמוך על השעון.
    if sync_status != "synchronized":
        return None
    if not isinstance(boot_id, str) or not BOOT_ID_PATTERN.fullmatch(boot_id):
        return None

    return {
        "schema_version": schema_version,
        "last_trusted_epoch": epoch,
        "sync_provider": provider,
        "sync_status": sync_status,
        "boot_id": boot_id,
        "last_trusted_boottime_seconds": boottime,
    }


def _make_state(
    epoch: int,
    provider: str,
    boot_id: str,
    boottime_seconds: int,
) -> ClockState:
    """בניית מבנה state תקני לעדכון/אתחול baseline."""
    return {
        "schema_version": SCHEMA_VERSION,
        "last_trusted_epoch": epoch,
        "sync_provider": provider,
        "sync_status": "synchronized",
        "boot_id": boot_id,
        "last_trusted_boottime_seconds": boottime_seconds,
    }


def _atomic_write(path: Path, state: dict[str, object]) -> None:
    """כתיבת state דרך atomic-write.py כדי לשמור על כתיבה אטומית ועמידה."""
    writer_path = Path(__file__).with_name("atomic-write.py")
    try:
        result = subprocess.run(
            [
                sys.executable,
                str(writer_path),
                "--file",
                str(path),
                "--data",
                json.dumps(state, separators=(",", ":"), allow_nan=False),
            ],
            check=False,
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
    except OSError as error:
        raise ClockStateError("atomic clock-state writer could not be started") from error
    if result.returncode != 0:
        raise ClockStateError("atomic clock-state write failed")


def evaluate_clock(
    path: Path,
    *,
    epoch: int,
    provider: str,
    sync_status: str,
    boot_id: str,
    boottime_seconds: int,
    min_reasonable_epoch: int,
    max_clock_jump_seconds: int,
    has_non_expired_records: bool,
) -> str:
    """הערכת אמינות השעון והחלת כללי SRS v4.5.

    מחזיר אחת מהתוצאות: trusted_same_boot, trusted_after_reboot,
    baseline_initialized, untrusted_clock, recovery_required.
    """
    # --- שלב 1: ולידציה של ראיות השעון הנוכחיות ---
    if type(epoch) is not int or epoch <= min_reasonable_epoch:
        return "untrusted_clock"
    if type(boottime_seconds) is not int or boottime_seconds < 0:
        return "untrusted_clock"
    if not PROVIDER_PATTERN.fullmatch(provider):
        return "untrusted_clock"
    if sync_status != "synchronized":
        return "untrusted_clock"
    if not BOOT_ID_PATTERN.fullmatch(boot_id):
        return "untrusted_clock"
    if type(min_reasonable_epoch) is not int or min_reasonable_epoch < 0:
        return "untrusted_clock"
    if type(max_clock_jump_seconds) is not int or max_clock_jump_seconds < 1:
        return "untrusted_clock"

    # --- שלב 2: קריאת baseline קודם ---
    previous = _read_state(path)
    if previous is None:
        # אין baseline תקין: אם יש רשומות TTL פעילות — אסור לאתחל בשקט (דורש שחזור).
        if has_non_expired_records:
            return "recovery_required"
        _atomic_write(path, _make_state(epoch, provider, boot_id, boottime_seconds))
        return "baseline_initialized"

    # --- שלב 3: השוואה למצב קודם ---
    # שינוי ספק סנכרון מחייב חוסר אמון עד לביסוס ראיות מתאימות.
    if previous["sync_provider"] != provider:
        return "untrusted_clock"

    previous_epoch = previous["last_trusted_epoch"]
    previous_boottime = previous["last_trusted_boottime_seconds"]
    # מניעת החזרת שעון אחורה (סיכון להארכת TTL).
    if epoch < previous_epoch:
        return "untrusted_clock"

    if previous["boot_id"] == boot_id:
        # אותו boot: boottime חייב להיות מונוטוני.
        if boottime_seconds < previous_boottime:
            return "untrusted_clock"
        epoch_delta = epoch - previous_epoch
        boottime_delta = boottime_seconds - previous_boottime
        # סטייה גדולה בין התקדמות השעון להתקדמות boottime => חשד לקפיצת שעון.
        if abs(epoch_delta - boottime_delta) > max_clock_jump_seconds:
            return "untrusted_clock"
        outcome = "trusted_same_boot"
    else:
        # boot שונה (reboot): boottime מתאפס, אך epoch עדיין חייב להיות עקבי.
        outcome = "trusted_after_reboot"

    # --- שלב 4: עדכון baseline לשעון המהימן הנוכחי ---
    _atomic_write(path, _make_state(epoch, provider, boot_id, boottime_seconds))
    return outcome


def _parse_args(arguments: list[str]) -> argparse.Namespace:
    """פרסור ארגומנטים ל-CLI של בדיקת אמינות שעון.

    הקלט כולל גם ראיות שזמן/מערכת מספקות (epoch, boottime, boot_id, sync)
    וגם פרמטרי מדיניות (min_reasonable_epoch, max_clock_jump_seconds).
    """
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state", required=True, type=Path)
    parser.add_argument("--epoch", required=True, type=int)
    parser.add_argument("--provider", required=True)
    parser.add_argument("--sync-status", required=True)
    parser.add_argument("--boot-id", required=True)
    parser.add_argument("--boottime-seconds", required=True, type=int)
    parser.add_argument("--min-reasonable-epoch", required=True, type=int)
    parser.add_argument("--max-clock-jump-seconds", required=True, type=int)
    parser.add_argument(
        "--has-non-expired-records", choices=("yes", "no"), required=True
    )
    return parser.parse_args(arguments)


def main(arguments: list[str] | None = None) -> int:
    """נקודת כניסה ל-CLI: מחזירה תוצאה ומקודדת אמון/חוסר אמון בקוד יציאה.

    קודי יציאה:
    - 0: trusted_same_boot / trusted_after_reboot / baseline_initialized
    - 9: untrusted_clock / recovery_required
    - 1: שגיאת הרצה/גישה/כתיבה (ClockStateError) — מפורט ב-stderr
    """
    # שימוש בארגומנטים שהועברו פנימית או ב-argv של התהליך.
    options = _parse_args(sys.argv[1:] if arguments is None else arguments)
    try:
        # הערכת אמינות השעון ועדכון baseline במידת הצורך (דרך evaluate_clock).
        outcome = evaluate_clock(
            options.state,
            epoch=options.epoch,
            provider=options.provider,
            sync_status=options.sync_status,
            boot_id=options.boot_id,
            boottime_seconds=options.boottime_seconds,
            min_reasonable_epoch=options.min_reasonable_epoch,
            max_clock_jump_seconds=options.max_clock_jump_seconds,
            has_non_expired_records=options.has_non_expired_records == "yes",
        )
    except ClockStateError as error:
        # שגיאה טכנית/תפעולית (לא תוצאת "untrusted" לוגית) — מדווחת בנפרד.
        print(f"clock-state: ERROR: {error}", file=sys.stderr)
        return 1

    # התוצאה המילולית מודפסת ל-stdout כדי שקוראים (Bash/stages) יפרשו אותה.
    print(outcome)
    # trusted_* ו-baseline_initialized נחשבים מצבים שמאפשרים המשך לפי המדיניות.
    return 0 if outcome.startswith("trusted_") or outcome == "baseline_initialized" else 9


if __name__ == "__main__":
    # המרת קוד ההחזרה של main לקוד יציאה של התהליך.
    raise SystemExit(main())