# פרומפט 13 — ממשק קריאה בלבד (USBGuard Read-Only Adapter)

## מטרה
איך לקרוא מידע מ-USBGuard בלי לשנות כלום. יישום פונקציות קריאה בלבד עם בדיקות באמצעות פקודות מדומות.

## קבצים צפויים
`scripts/lib/usbguard-policy.sh` (חלק קריאה בלבד), `tests/unit/test_policy_read.sh`

## קריטריון אימות
הרץ את הבדיקות עם פקודות מדומות (לא באמת מול המערכת).

## מה לומדים
איך לקרוא מידע מ-USBGuard בלי לשנות כלום.

---

```text
PROMPT 13 — USBGuard Read-Only Adapter

Implement read-only functions in scripts/lib/usbguard-policy.sh:

1. Function get_usbguard_version(): run `usbguard --version` and return output.

2. Function list_blocked_devices(): 
   - Run `usbguard list-devices --blocked` (or parse list-devices)
   - Return structured output
   - Handle empty result gracefully

3. Function list_active_rules():
   - Run `usbguard list-rules`
   - Return output

4. Function check_daemon_status():
   - Check if usbguard-daemon is running
   - Check IPC connectivity
   - Return status code

Constraints:
- Do NOT implement any write operations yet.
- Do NOT parse with complex regex if simple parsing suffices.
- Use timeout for all external commands.

Create tests/unit/test_policy_read.sh with mocked usbguard commands.
Run tests and report results.
```

## משימות מפורטות
1. בדוק את גרסת USBGuard ואת ממשקי ה-CLI הזמינים בסביבת היעד.
2. רכז את הגישה ל-USBGuard ברכיב אחד.
3. הפרד בין פקודות קריאה לבין פקודות שמשנות policy.
4. טפל בקוד יציאה, stdout, stderr, timeout והיעדר IPC.
5. אל תשתמש בשרשור קלט משתמש לתוך פקודת shell.
6. אל תשמור Rule ID כזיהוי קבוע.
7. הגדר מודל תוצאות ברור עבור הצלחה, כשל ומידע חלקי.
8. ספק fake/mock לבדיקות יחידה.
9. אל תבצע `allow-device`, `append-rule`, `remove-rule` או `block-device` בשלב זה.
10. אל תדווח שהתקן חסום או מאושר אם המידע שנקרא אינו מוכיח זאת.

## בדיקות
- פלט תקין.
- פלט לא צפוי.
- פקודה שנכשלה.
- timeout.
- daemon או IPC לא זמינים.
- נתונים חסרים.
- בדיקות ללא USBGuard אמיתי.

## ערך הנדרש
הסבר כיצד שכבת Adapter מונעת פיזור של פקודות מערכת בכל הפרויקט.

## איסורים
- לא משנה policy אמיתי. בדיקות היחידה משתמשות ב-mock או ב-fake.