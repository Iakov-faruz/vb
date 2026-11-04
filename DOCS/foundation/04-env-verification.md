# פרומפט 04 — בדיקת סביבה ותלויות (Environment Verification)

## מטרה
לוודא שהסביבה מוכנה לפני שמתחילים לכתוב קוד. שלב קריאה בלבד — לא מתקינים כלום ולא משנים תצורת מערכת.

## קבצים צפויים
אין קבצי קוד. רק דוח סביבה.

## קריטריון אימות
הסוכן צריך להחזיר רשימה של כלים זמינים וחסרים.

## מה לומדים
איך לוודא שהסביבה מוכנה לפני שמתחילים לכתוב קוד.

---

```text
PROMPT 04 — Environment Verification

READ-ONLY. Do not modify files.

1. Check which tools are available: bash --version, python3 --version,
   jq --version, usbguard --version (if installed), systemctl --version.
2. Check if the current user can run tests without sudo.
3. Identify the test framework (if any exists in the repository).
4. Report which tools are missing and need to be installed.
5. Do not install anything. Do not modify system configuration.

Return: environment report and list of missing dependencies.
```

## משימות מפורטות
1. בדוק אילו כלים זמינים: bash --version, python3 --version, jq --version, usbguard --version (אם מותקן), systemctl --version.
2. בדוק אם המשתמש הנוכחי יכול להריץ בדיקות ללא sudo.
3. זהה את framework הבדיקות (אם קיים במאגר).
4. דווח אילו כלים חסרים ודורשים התקנה.
5. אל תתקין כלום. אל תשנה תצורת מערכת.

## ערך החזרה
- דוח סביבה (כלים זמינים וגרסאות).
- רשימת תלויות חסרות.

## איסורים
- אל תתקין תוכנה.
- אל תשנה תצורת מערכת.