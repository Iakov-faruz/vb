# פרומפט 26 — ייבוא וייצוא (Import and Export)

## מטרה
איך להעביר נתונים בין מערכות בלי לאפשר חדירה. ייצוא כללי קבוע ורשומות TTL פעילות, וייבוא עם ולידציה קשוחה ודחיית קבצים פגומים.

## קבצים צפויים
`scripts/export-rules.sh`, `scripts/import-rules.sh`, `tests/unit/test_import_export.sh`

## קריטריון אימות
הרץ את הבדיקות וודא שייבוא פגום נדחה.

## מה לומדים
איך להעביר נתונים בין מערכות בלי לאפשר חדירה.

---

```text
PROMPT 26 — Import and Export

Implement import/export:

1. export-rules.sh:
   - Export permanent rules and active TTL records.
   - Exclude system rules.
   - Do not include secrets.

2. import-rules.sh:
   - Validate schema before importing.
   - Reject unsupported schema versions.
   - Reject missing required fields.
   - Show diff before applying.
   - Do NOT execute system commands from imported data.
   - Separate data import from policy change.

Constraints:
- Imported file must not bypass authorization.
- Clear error messages without exposing sensitive info.

Create tests for valid/invalid JSON, round-trip, and rejection cases.
Run tests and report results.
```

## משימות מפורטות
לאפשר העברת נתונים בלי לאפשר לקובץ חיצוני לשנות מדיניות באופן בלתי מבוקר.

1. השתמש ב-schema מפורש.
2. אמת את כל הנתונים לפני החלתם.
3. הגדר התנהגות לגרסת פורמט לא נתמכת.
4. דחה ערכים אסורים, שדות חובה חסרים ונתונים סותרים.
5. אל תפעיל פקודות מערכת מתוך קובץ מיובא.
6. הפרד בין ייבוא נתונים לבין ביצוע שינוי מדיניות.
7. אל תאפשר לקובץ מיובא לעקוף הרשאות או מנגנוני אישור.
8. הפק שגיאות ברורות בלי לחשוף מידע רגיש.
9. ודא שהייצוא אינו כולל סודות או נתונים שאינם נחוצים.
10. TTL שפג תוקפו יוצג כ-`SKIPPED - expired`.

## בדיקות

- JSON תקין.
- JSON פגום.
- גרסה לא נתמכת.
- ערכים לא תקינים.
- נתונים כפולים.
- ייבוא שלא משנה מדיניות לפני אישור הפעולה.
- round-trip של נתונים תקינים.

## איסורים

- קובץ מיובא אינו רשאי לעקוף הרשאות או מנגנוני אישור.
