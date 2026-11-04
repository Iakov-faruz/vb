# פרומפט 14 — בדיקות התנהגות G-01 חלק א` (Gate G-01 Tests Part 1)

## מטולה
שער אימות חובה חלק א`. בדיקות התנהגות בסיסיות של USBGuard בסביבת מעבדה בלבד. לא לדלג עליו וללא סימון PASS ללא ראיות.

## קבצים צפויים
`docs/g01-report-part1.md` (דוח בדיקות)

## קריטריון אימות
בדוק שהדוח כולל את כל 5 הבדיקות עם פקודה, פלט, קוד יציאה ומסקנה לכל אחת.

## מה לומדים
איך לבדוק שהפקודות של USBGuard מתנהגות כמו שאתה מצפה.

---

```text
PROMPT 14 — Gate G-01 Tests Part 1

LAB ENVIRONMENT ONLY. Do not run on development host.

Execute the following tests and document results:

1. Check usbguard version and available CLI commands.
2. Check daemon configuration: RuleFile vs RuleFolder.
3. Test: Add temporary rule, verify it appears, remove it, verify gone.
4. Test: Add permanent rule, verify where it was saved.
5. Test: Check if adding a rule affects already-connected devices.

For each test, record:
- Exact command
- Output
- Exit code
- Conclusion

Do NOT proceed to Part 2 until these are verified.
Return test report.
```

## משימות מפורטות

### לפני בדיקות שמשנות policy
- אמת את זהות סביבת המעבדה.
- הצג את גרסת USBGuard ואת תצורת ה-daemon.
- בדוק את מצב ההתקנים והכללים לפני כל ניסוי.
- ודא שהבדיקה לא תנתק התקן חיוני או תשנה את מחשב העבודה.
- ודא שיש מסלול התאוששות.
- אם אחד התנאים אינו מתקיים, עצור.

### בדוק את הנושאים הבאים (חלק א`)
1. בדוק usbguard version ואת פקודות ה-CLI הזמינות.
2. בדוק תצורת דמון: RuleFile לעומת RuleFolder.
3. בדיקה: הוסף כלל זמני, אמת שהוא מופיע, הסר אותו, אמת שנעלם.
4. בדיקה: הוסף כלל קבוע, אמת היכן נשמר.
5. בדיקה: בדוק אם הוספת כלל משפיעה על התקנים שכבר מחוברים.

עבור כל בדיקה, רשום:
- פקודה מדויקת
- פלט
- קוד יציאה
- מסקנה

אל תעבור לחלק ב` עד שהבדיקות אומתו.
החזר דוח בדיקות.

## תיקון קריטי (חובה)

- אל תניח ש-`allow-device --permanent` ו-`append-rule` הן פעולות בלתי תלויות שאפשר תמיד לבצע ברצף. הפעולה הראשונה עשויה גם לאשר את ההתקן וגם להוסיף כלל קבוע.
- אל תניח ש-`remove-rule` מקבל hash במקום Rule ID.
- אל תניח שהסרת כלל זמני חוסמת את ההתקן.

## ערך החזרה

דוח G-01 חלק א` שניתן לעקוב אחריו. אין להציג מסקנות שלא נבדקו בפועל.

## איסורים

- אם אין סביבת מעבדה זמינה או שהראיות אינן חד-משמעיות, סמן `G-01 = UNVERIFIED` ועצור לפני מימוש פעולות מסוכנות שתלויות בתוצאות.
- אין להצהיר על G-01 כ-PASS אם חסר ניסוי חובה.
