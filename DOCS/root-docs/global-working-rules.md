# פרומפט 00 — כללי עבודה גלובליים (Global Working Rules)

## מטרה
לאלף את הסוכן שיעבוד לפי הכללים של המשתמש ולא ימציא דרישות, נתיבים או התנהגויות שלא במפרט. שלב זה אינו כותב קוד — הוא רק קובע את מסגרת העבודה לכל המשימות הבאות.

## קבצים צפויים
אין קבצי קוד. הסוכן צריך לאשר את הכללים ולעצור.

## קריטריון אימות
הסוכן מחזיר את ההודעה "כללי העבודה התקבלו" ועוצר בהמתנה לאישור לפני המשך למשימה הבאה.

## מה לומדים
איך להגדיר מקור אמת (Source of Truth), משמעת ביצוע, כללי אבטחה ותהליך דיווח לפני שמתחילים לכתוב קוד כלשהו.

---

```text
PROMPT 00 — Global Working Rules

You are working on the USBGuard Approval Manager project.

SOURCE OF TRUTH:
- SRS v4.4 Final Frozen (2026-10-25) is the authoritative document.
- Do not invent requirements, paths, or behaviors not in the SRS.
- If the SRS is ambiguous, stop and report the exact issue.

EXECUTION DISCIPLINE:
- Work only on the current task. Do not proceed without approval.
- Begin with read-only inspection. Modify files only when authorized.
- Never use destructive Git commands (reset --hard, clean -fd).
- Preserve unrelated user changes.

SECURITY:
- Do not modify active USBGuard policy on the development host.
- Hardware-dependent tests run only in designated lab environment.
- Never assume removing a temporary rule guarantees device blocking.
- If state becomes uncertain, stop and report instead of auto-recovering.

REPORTING:
After every task, report: files changed, tests run, actual results,
remaining gaps, and the exact next step. Stop and wait for approval.
```

**אימות:** אין קוד. הסוכן צריך להחזיר "כללי העבודה התקבלו" ולעצור.
