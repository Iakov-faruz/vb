# פרומפט 10 — כתיבה אטומית (Atomic Write Helper)

## מטרה
איך לכתוב קובץ כך שאם המחשב קורס באמצע, הקובץ לא נשאר חצי כתוב. יישום כתיבה אטומית עם Python helper.

## קבצים צפויים
`scripts/lib/atomic-write.py`, `tests/unit/test_atomic_write.sh`

## קריטריון אימות
בדוק שאין קבצים זמניים שנשארו בתיקייה.

## מה לומדים
איך לכתוב קובץ כך שאם המחשב קורס באמצע, הקובץ לא נשאר חצי כתוב.

---

```text
PROMPT 10 — Atomic Write Helper

Implement scripts/lib/atomic-write.py:

1. Accept arguments: --file <path> --data <json_string>
2. Write process (SRS SEC-04):
   a. Create temporary file in SAME directory as target
   b. Write data to temp file
   c. Set permissions to 600
   d. fsync the file
   e. os.replace(temp, target) — atomic rename
   f. fsync the parent directory
3. On failure: clean up temp file, do NOT corrupt existing target.

Create tests/unit/test_atomic_write.sh that tests:
- Successful write creates valid file with correct permissions
- Failed write (simulate by read-only directory) preserves original
- No orphan temp files after success

Run tests and report results.
```

## משימות מפורטות
1. כתוב לקובץ זמני באותה מערכת קבצים שבה נמצא הקובץ הסופי.
2. הגדר הרשאות מתאימות לקובץ הזמני לפני חשיפת הנתונים.
3. בדוק שכתיבת התוכן הצליחה.
4. בצע החלפה אטומית של הקובץ, המתאימה למערכת הקבצים ולשימוש.
5. התייחס לשגיאות flush/sync לפי דרישות העמידות של הפרויקט.
6. נקה קובצי ביניים לאחר כשל בלי למחוק את הקובץ התקין הקודם.
7. אל תשתמש בכתיבה אטומית כתחליף לנעילה.
8. אל תבצע שינויי הרשאות רחבים על ספריות קיימות.

## בדיקות
- הצלחה מחליפה את הקובץ באופן תקין.
- כשל לפני ההחלפה משאיר את הקובץ הקודם תקין.
- הרשאות הקובץ הסופי תקינות.
- קובץ זמני לא נשאר במצב הצלחה.
- בדוק התנהגות תחת כשל כתיבה מדומה.

## איסורים
- אל תוסיף בשלב זה פעולות שמשנות policy של USBGuard.