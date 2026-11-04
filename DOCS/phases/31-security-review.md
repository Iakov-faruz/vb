# פרומפט 30 — סקירת אבטחה (Security Review)

## מטרה
איך לבדוק קוד שכתבת מנקודת מבט של תוקף. סקירת אבטחה מלאה ללא שינויים בקוד.

## קבצים צפויים
אין קבצי קוד חדשים. רק דוח ממצאים.

## קריטריון אימות
בדוק שהרשימה כוללת חומרה ומיקום לכל ממצא.

## מה לומדים
איך לבדוק קוד שכתבת מנקודת מבט של תוקף.

---

```text
PROMPT 30 — Security Review

REVIEW ONLY. Do not modify files.

Review the entire implementation for security issues:

1. Input validation and injection risks.
2. File permissions and symlink attacks.
3. Race conditions and locking gaps.
4. Error handling and information leakage.
5. Command injection in subprocess calls.
6. Sensitive data in logs.
7. Authorization bypass possibilities.
8. Rule ID handling (stale IDs).
9. Assumption that rule removal equals device blocking.
10. Recovery behavior in uncertain states.

For each finding:
- Severity (critical/high/medium/low)
- File and line
- Attack scenario
- Recommended fix

Do NOT fix anything. Return findings list and stop.
```

## משימות מפורטות
בצע סקירת אבטחה של המימוש הקיים. אל תוסיף תכונות חדשות ואל תבצע refactor רחב.

## בדוק

1. הרשאות וקבצים שניתנים לכתיבה על ידי משתמש לא מורשה.
2. שימוש ב-shell וחשיפה להזרקת פקודות.
3. parsing של קלט חיצוני.
4. log injection וחשיפת סודות.
5. race conditions ונעילות.
6. כתיבה לא אטומית ואובדן נתונים.
7. כשל Audit לאחר שינוי policy.
8. TTL ו-clock trust.
9. שימוש לא תקין ב-Rule ID.
10. הסרת כלל זמני כאשר כלל קבוע חופף.
11. reconciliation אוטומטי במצב לא ודאי.
12. restore של קבצים פגומים או מגרסה אחרת.
13. הרשאות systemd ו-IPC.
14. פעולות batch חלקיות.
15. האם הודעות הצלחה תואמות לתוצאה בפועל.

## פורמט החזרה לכל ממצא

- חומרה (קריטי / גבוה / בינוני / נמוך).
- קובץ ושורה.
- תרחיש ניצול או כשל.
- השפעה.
- תיקון מינימלי מוצע.
- בדיקה שתוכיח את התיקון.

## איסורים

- אל תתקן ממצאים בשלב הסקירה. המתן לאישור לפני שינוי.
