# פרומפט 29 — בדיקת בריאות כוללת (Health Validation)

## מטרה
איך לבדוק שהכל עובד יחד לפני שחרור. יישום סקריפט בדיקת בריאות קריאה בלבד עם PASS/FAIL לכל בדיקה.

## קבצים צפויים
`validate_all.sh`

## קריטריון אימות
הרץ את הסקריפט וודא שכל הבדיקות מדווחות.

## מה לומדים
איך לבדוק שהכל עובד יחד לפני שחרור.

---

```text
PROMPT 29 — Health Validation

Implement validate_all.sh:

Check:
1. Configuration syntax and values.
2. File permissions and ownership.
3. Service status (timer active, last run successful).
4. IPC connectivity.
5. Backup availability and rotation.
6. Log files exist and are writable.
7. TTL file validity.
8. Lock file accessibility.

Output:
- PASS/FAIL for each check.
- Summary with overall status.
- Exit code 0 if all pass, non-zero otherwise.

Constraints:
- Read-only checks only.
- Do not modify state.

Run the validation and report results.
```

## משימות מפורטות
ממש סקריפט בדיקת בריאות כולל.

בדוק:
1. תחביר וערכי תצורה.
2. הרשאות ובעלות קבצים.
3. סטטוס שירות (טיימר פעיל, הרצה אחרונה הצליחה).
4. קישוריות IPC.
5. זמינות גיבוי ורוטציה.
6. קובצי לוג קיימים וניתנים לכתיבה.
7. תקינות קובץ TTL.
8. נגישות קובץ נעילה.

פלט:
- PASS/FAIL לכל בדיקה.
- סיכום עם סטטוס כללי.
- קוד יציאה 0 אם הכל עבר, לא אפס אחרת.

## איסורים

- בדיקות קריאה בלבד.
- אל תשנה מצב.