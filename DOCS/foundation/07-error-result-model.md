# פרומפט 07 — מודל שגיאות ותוצאות (Error Result Model)

## מטרה
למנוע מצב שבו פעולה נכשלה אך המערכת מדווחת הצלחה. הגדרת מודל תוצאה עם הבחנה ברורה בין סוגי כישלון שונים.

## קבצים צפויים
אין קבצי קוד חדשים. רק מסמך הגדרת מודל השגיאות.

## קריטריון אימות
הסוכן צריך להחזיר הגדרת מודל תוצאה עם כל מצבי הכשל ורשימת קודי היציאה.

## מה לומדים
איך להגדיר מודל שגיאות ותוצאות שמאפשר זיהוי מדויק של מצבי כשל.

---

```text
PROMPT 07 — Error Result Model

Implement an error/result model layer:

1. Define result states:
   - Operation succeeded
   - Operation failed before policy change
   - Policy change failed
   - Policy change succeeded but Audit write failed (`POLICY_APPLIED_AUDIT_FAILED`)
   - State where it is impossible to know what changed
   - State requiring recovery

2. Map each state to exact exit codes per SRS section 21:
   - EXIT_OK = 0
   - EXIT_VALIDATION = 7
   - EXIT_INCONSISTENT = 9
   - EXIT_PARTIAL = 13
   - EXIT_AUDIT = 14
   - EXIT_CANCELLED = 130

3. Define return structure for CLI and library functions.

Do not implement business logic. Return the model definition and stop.
```

## משימה
ממש שכבת שגיאות ותוצאות בלבד. הגדר מודל תוצאה המאפשר להבחין בין:

- פעולה שהצליחה.
- פעולה שנכשלה לפני שינוי מדיניות.
- שינוי מדיניות שנכשל.
- שינוי מדיניות שהצליח אך כתיבת Audit נכשלה (`POLICY_APPLIED_AUDIT_FAILED`).
- מצב שבו אי אפשר לדעת בוודאות מה השתנה.
- מצב המחייב התאוששות.

אם ה-SRS מגדיר שמות וקודי יציאה מסוימים — שמור עליהם.

## איסורים
- אל תשתמש בתוצאה כללית כגון `false` כאשר יש צורך להבחין בין מצבים בעלי משמעות אבטחתית שונה.
- בדיקות השגיאה אינן מפעילות USBGuard אמיתי.

## בדיקות
- לכל מצב יש תוצאה צפויה.
- תוצאות אינן מתפרשות בטעות כהצלחה.
- כשל Audit לאחר שינוי מוצלח אינו מדווח כאילו המדיניות לא השתנתה.

## ערך החזרה
- הסבר באמצעות דוגמאות קצרות כיצד רכיבים עתידיים ישתמשו במודל התוצאה.