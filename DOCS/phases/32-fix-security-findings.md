# פרומפט 31 — תיקון ממצאים (Fix Approved Security Findings)

## מטרה
איך לתקן בעיות אבטחה בצורה ממוקדת ומבוקרת. יישום תיקונים רק לממצאים שאושרו על ידי המשתמש.

## קבצים צפויים
תלויים בממצאים המאושרים.

## קריטריון אימות
הרץ את הבדיקות וודא שכל תיקון מוכח.

## מה לומדים
איך לתקן בעיות אבטחה בצורה ממוקדת ומבוקרת.

---

```text
PROMPT 31 — Fix Approved Security Findings

Implement fixes ONLY for findings approved by the user.

For each approved finding:
1. Make minimal, focused change.
2. Add test that fails before fix and passes after.
3. Run relevant tests.
4. Verify fix does not break other requirements.
5. Show separate diff for each fix.

Constraints:
- Do NOT fix unapproved findings.
- Do NOT close a finding without evidence.
- Do NOT commit if tests fail.

Return mapping: finding → fix → test → result.
```

## משימות מפורטות
תקן רק את ממצאי האבטחה שאושרו מתוך הסקירה.

## לכל ממצא שאושר

1. בצע שינוי מינימלי וממוקד.
2. הוסף בדיקה שנכשלת לפני התיקון ועוברת אחריו, ככל שניתן להדגים זאת.
3. הרץ את הבדיקות הרלוונטיות.
4. ודא שהשינוי לא שובר דרישות אחרות ב-SRS.
5. הצג diff נפרד לכל קבוצת תיקונים.
6. אל תסגור ממצא בלי ראיה.
7. אל תבצע commit אם בדיקות נדרשות נכשלו.

## ערך החזרה

מיפוי בין ממצאים שאושרו, תיקונים, בדיקות ותוצאות.
