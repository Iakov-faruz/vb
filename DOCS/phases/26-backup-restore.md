# פרומפט 25 — גיבוי ושחזור (Backup and Restore)

## מטרה
איך להגן על נתונים ולשחזר אותם בבטחה. יישום סקריפטי גיבוי ושחזור עם מניפסט ושמירת הרשאות.

## קבצים צפויים
`scripts/backup-rules.sh`, `scripts/restore-rules.sh`, `tests/unit/test_backup_restore.sh`

## קריטריון אימות
הרץ את הבדיקות וודא שגיבוי ושחזור עובדים.

## מה לומדים
איך להגן על נתונים ולשחזר אותם בבטחה.

---

```text
PROMPT 25 — Backup and Restore

Implement backup and restore:

1. backup-rules.sh:
   - Backup only defined files (policy, TTL, config).
   - Create manifest with hashes.
   - Rotate backups according to BACKUP_KEEP.
   - Preserve permissions.

2. restore-rules.sh:
   - List available backups.
   - Verify manifest before restore.
   - Show what will change before applying.
   - Do NOT restore Rule IDs as valid after reboot.
   - If clock unreliable, do not auto-expire after restore.

Constraints:
- Do NOT overwrite existing state without checks.
- Do NOT delete existing backups during restore.

Create tests for backup, restore, and failure scenarios.
Run tests and report results.
```

## משימות מפורטות
להגן על נתונים קיימים ולמנוע שחזור לא בטוח.

1. גבה את הקבצים הנדרשים בלבד.
2. שמור על הרשאות ו-ownership מתאימים.
3. אמת שלמות, schema וגרסת פורמט לפני שחזור.
4. אל תדרוס מצב קיים בלי בדיקות מקדימות.
5. הצג את הפעולות שהשחזור צפוי לבצע לפני החלתן.
6. הגדר rollback אם השחזור נכשל באמצע.
7. אל תשחזר Rule IDs של USBGuard כאילו הם תקפים לאחר הפעלה מחדש.
8. בדוק התאמה בין TTL לבין המדיניות הפעילה.
9. אם השעון אינו מהימן, אל תבצע תפוגה אוטומטית המבוססת על זמן לא אמין.
10. אם לא ניתן לקבוע שהשחזור בטוח, העבר את המערכת למצב התאוששות.
11. אל תמחק Audit או גיבויים קיימים שלא הוגדרו כמועמדים למחיקה.

## בדיקות

- גיבוי תקין.
- שחזור תקין.
- קובץ גיבוי פגום.
- schema לא נתמך.
- נתונים קיימים.
- כשל באמצע השחזור.
- rollback.
- Audit.

## איסורים

- אין לשחזר Rule IDs כמזהים תקפים לאחר הפעלה מחדש.
