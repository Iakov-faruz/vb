# פרומפט 01 — בדיקת המאגר וה-SRS (Repository and SRS Audit)

## מטרה
להבין את המצב הקיים לפני כל שינוי. בשלב זה **לא משנים קוד ולא יוצרים קבצים**.

## קבצים צפויים
אין קבצי קוד חדשים. רק קריאה בלבד של הקיים.

## קריטריון אימות
`git status --short` צריך להיות ריק (או להציג רק שינויים שלך).

## מה לומדים
איך למפות פרויקט קיים לפני שמשנים משהו, ואיך לבנות טבלת מעקב (traceability) בין דרישות סף (SRS) למימוש הקיים.

---

```text
PROMPT 01 — Repository and SRS Audit

READ-ONLY TASK. Do not modify files.

1. Run `git status --short` and report existing changes.
2. List the complete directory tree of the repository.
3. Locate and read the SRS v4.4 Final Frozen document.
4. Identify all existing scripts, tests, and configuration files.
5. Build a traceability table: for each SRS requirement ID (FR-XX, SEC-XX, OPS-XX),
   report whether it is implemented, partially implemented, or missing.
6. Identify which components from the SRS project tree already exist:
   - scripts/lib/*.sh files
   - scripts/*.sh entry points
   - systemd units
   - tests/

Do not implement anything. Return the table and stop.
```

## משימות מפורטות
1. בדוק מבנה מאגר, ענף נוכחי, מצב Git והיסטוריית commits רלוונטית.
2. אתר את כל מסמכי הדרישות, התכנון, הבדיקות והפריסה.
3. בדוק אם קיים כבר קוד, גם אם חלקי.
4. זהה שפת מימוש, גרסאות כלים ובדיקות קיימות.
5. הפק מיפוי של דרישות SRS לרכיבים ולבדיקות.
6. הצג אילו דרישות ממומשות, חלקיות וחסרות.
7. אתר סתירות בין מסמכים — אל תפתור אותן בשקט.
8. רשום את כל מזהי הבדיקות ב-SRS ואת מצב המימוש שלהן.
9. ציין אילו בדיקות מחייבות USBGuard אמיתי ואילו יכולות לרוץ בבידוד.

## ערך החזרה (לא Commit)
- סיכום המצב הקיים.
- עץ תיקיות.
- טבלת דרישה / מימוש / בדיקה.
- סיכונים וחסמים.
- סדר מימוש מוצע.

## איסורים
- אין commit בשלב זה (אין שינוי קוד).
- לא לשנות קוד, לא ליצור קבצים.