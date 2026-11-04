# פרומפט 13 — הכנת סביבת מעבדה (Lab Environment Preparation)

## מטרה
איך לבדוק התנהגות אמיתית של מערכת לפני שמבססים עליה קוד. הגדרת מה נחשב ל"סביבת מעבדה" ויצירת רשימת בדיקה (checklist) לתפעול בטוח.

## קבצים צפויים
`docs/lab-checklist.md`

## קריטריון אימות
בדוק שהקובץ `docs/lab-checklist.md` נוצר.

## מה לומדים
איך לבדוק התנהגות אמיתית של מערכת לפני שמבססים עליה קוד.

---

```text
PROMPT 13 — Lab Environment Preparation

READ-ONLY PLANNING. Do not modify any system.

1. Define what constitutes a "lab environment" for this project:
   - Separate VM or container
   - No production USB devices connected
   - USBGuard installed but with test-only rules

2. Create a checklist document (docs/lab-checklist.md) with:
   - How to verify you are in lab environment
   - What commands are safe to run
   - What commands are FORBIDDEN outside lab
   - How to recover if something goes wrong

3. Do NOT run any USBGuard commands in this step.

Return the checklist and stop.
```

## משימות מפורטות
1. הגדר מה נחשב ל"סביבת מעבדה" בפרויקט זה:
   - VM נפרד או מכולה (container)
   - אין התקני USB יצרניים מחוברים
   - USBGuard מותקן עם כללי בדיקה בלבד

2. צור מסמך רשימת בדיקה (`docs/lab-checklist.md`) עם:
   - כיצד לאמת שאתה בסביבת מעבדה
   - אילו פקודות בטוחות להרצה
   - אילו פקודות אסורות מחוץ למעבדה
   - כיצד להשתקם אם משתבש משהו

3. אל תריץ שום פקודת USBGuard בשלב זה.

החזר את רשימת הבדיקה ועצור.

## איסורים

- אל תריץ פקודות USBGuard בשלב זה.
- לא משנה שום מערכת.