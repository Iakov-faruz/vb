# פרומפט 11 — ולידציה של נתונים (Data Validators)

## מטרה
איך לוודא שנתונים שנכנסים למערכת הם תקינים. יישום ולידציה של JSON ורקורדי TTL עם jq.

## קבצים צפויים
`scripts/lib/validators.sh`, `tests/unit/test_validators.sh`

## קריטריון אימות
הרץ את הבדיקות וודא שכל המקרים נבדקים.

## מה לומדים
איך לוודא שנתונים שנכנסים למערכת הם תקינים.

---

```text
PROMPT 11 — Data Validators

Implement scripts/lib/validators.sh:

1. Function validate_json_schema(file_path):
   - Check schema_version == 1
   - Check required fields exist
   - Check types are correct
   - Use jq for parsing (do not parse JSON with grep)

2. Function validate_ttl_record(record_json):
   - managed_id must be UUID v4 format
   - expires_at must be positive integer
   - status must be one of: pending, active, inconsistent, recovery_required
   - rule must be non-empty string

3. Return specific error messages for each validation failure.

Create tests/unit/test_validators.sh that tests:
- Valid TTL record passes
- Record with missing managed_id fails
- Record with invalid status fails
- Record with negative expires_at fails

Run tests and report results.
```

## משימות מפורטות
1. השתמש בפורמט המדויק שנקבע ב-SRS.
2. אמת שדות חובה, סוגים, טווחים, ערכים מותרים וגרסת schema.
3. דחה שדות קריטיים שחסרים או נתונים שסותרים זה את זה.
4. התייחס לקובץ ריק, קטוע, פגום או גדול מהצפוי.
5. אל תבצע פקודות מערכת מתוך נתונים שנקראו מקובץ.
6. אל תשתמש ב-`eval` או בפרשנות קוד של קלט.
7. אם מדובר ב-JSON, השתמש ב-parser תקין ואל תבנה JSON באמצעות שרשור מחרוזות.
8. אל תשכתב נתונים מקוריים בעת קריאה בלבד.
9. שמור על תאימות לפורמט הקיים שה-SRS מגדיר.

## בדיקות
- קלט תקין מתקבל.
- קלט פגום נדחה.
- שדות לא צפויים מטופלים לפי המדיניות שנקבעה.
- נתונים פגומים אינם גורמים לשינוי מדיניות.

## ערך הנדרש
הסבר את ההבדל בין parsing לבין validation.