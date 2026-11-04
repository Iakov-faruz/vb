# פרומפט 06 — קריאת הגדרות (Config Parser)

## מטרה
איך לקרוא קובץ הגדרות בבטחה בלי להריץ קוד מתוכו. יישום פונקציית load_config עם ולידציה נוקשה נגד הזרקת פקודות.

## קבצים צפויים
`scripts/lib/config-reader.sh`, `tests/unit/test_config_reader.sh`

## קריטריון אימות
הרץ `bash tests/unit/test_config_reader.sh` — כל הבדיקות צריכות לעבור.

## מה לומדים
איך לקרוא קובץ הגדרות בבטחה בלי להריץ קוד מתוכו.

---

```text
PROMPT 06 — Config Parser

Implement scripts/lib/config-reader.sh:

1. Function load_config(file_path) that reads KEY=VALUE pairs.

2. Validation rules (SRS SEC-01, SEC-02):
   - Keys must match ^[A-Z][A-Z0-9_]*$
   - Reject duplicate keys
   - Reject lines containing $(...), backticks, or shell expansion
   - Validate integer ranges for known keys

3. Return non-zero exit code on validation failure with clear error.

Constraints:
- Do NOT use `source` or `eval`.
- Use grep/awk for parsing.

Create tests/unit/test_config_reader.sh that tests:
- Valid config file
- Config with duplicate key (should fail)
- Config with $(rm -rf /) injection (should fail)
- Config with invalid key name (should fail)

Run tests and report results.
```

## משימות מפורטות
1. רכז את נתיבי הקבצים, הספריות, קובצי המצב, ה-Audit, הגיבויים והנעילה.
2. רכז ערכי ברירת מחדל וקבועים נדרשים.
3. הגדר קודי יציאה באופן מרכזי, לרבות `EXIT_AUDIT=14` כהגדרתו ב-SRS (סעיף 21 ב-USB.md).
4. שמור על הבחנה בין הצלחת פעולה, כישלון מדיניות, כישלון Audit ומצב לא עקבי.
5. אל תפזר כתובות IP, נתיבים או allowlists קשיחים ללא דרישה מפורשת.
6. אל תאפשר לקלט משתמש לשנות נתיבי מערכת רגישים ללא אימות.
7. ודא שערכים חסרים או לא תקינים מזוהים מוקדם.

## בדיקות
- כל קבוע נדרש מוגדר פעם אחת בלבד.
- כל קוד יציאה מתועד ונבדק.
- קלט הגדרות לא תקין נכשל בצורה ברורה.
- אין שינוי מדיניות USBGuard בשלב זה.

## איסורים
- אין פעולת USBGuard בשלב זה.
