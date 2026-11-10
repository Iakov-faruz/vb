# פרומפט 02 — תוכנית מימוש בלבד (Implementation Plan Only)

## מטרה
להפוך את ה-SRS לתוכנית עבודה מדורגת שניתן לעקוב אחריה, על בסיס ממצאי פרומפט 01 וה-SRS בלבד. שלב תכנון בלבד — לא כותבים קוד מימוש.

## קבצים צפויים
אין קבצי קוד. רק מסמך תוכנית.

## קריטריון אימות
הסוכן צריך להחזיר רשימה ממוספרת של משימות עם תלויות.

## מה לומדים
איך לתכנן פרויקט בצורה הדרגתית ולא "הכל בבת אחת".

---

```text
PROMPT 02 — Implementation Plan Only

PLANNING ONLY. Do not modify files.

Based on the SRS and the repository state from PROMPT 01, create a
staged implementation plan that:

1. Covers every applicable SRS requirement.
2. Prioritizes security-critical components first.
3. Orders tasks by dependency (what must exist before what).
4. Separates: foundation libraries, USBGuard adapter, TTL engine,
   user interfaces, backup/restore, deployment.
5. For each task, specify:
   - Task ID
   - Exact SRS requirement IDs
   - Files to create/modify
   - Dependencies on previous tasks
   - Acceptance criteria

Do not implement. Return the plan and stop.
```

## משימות מפורטות
הגדר את תחומי האחריות של הרכיבים הבאים, **בלי לכתוב עדיין את המימוש**:

- הגדרות ונתיבים.
- קודי יציאה.
- Logging ו-Audit.
- נעילות.
- כתיבה אטומית.
- Parsing ואימות קלט.
- זמן ואמינות השעון.
- USBGuard adapter.
- בדיקות G-01.
- מודל TTL ומצב.
- אישורים זמניים וקבועים.
- Reaper והתאוששות.
- CLI ו-TUI.
- פעולות מרובות.
- גיבוי ושחזור.
- ייבוא וייצוא.
- systemd ופריסה.
- תיעוד ובדיקות שחרור.

לכל רכיב ציין:
1. אחריות.
2. קלט ופלט.
3. תלות ברכיבים אחרים.
4. גבולות אבטחה.
5. בדיקות קבלה.
6. דרישות SRS רלוונטיות (מזהים אמיתיים מ-USB.md בלבד, לא ממציאים).

## איסורים
- אל תיצור שכבות או ממשקים ללא צורך ברור.
- אל תמציא מספרי דרישות.
- לא כותבים קוד מימוש בשלב זה.

## ערך החזרה
- תוכנית מימוש מדורגת עם responsible per component.
- רשימת החלטות הדורשות אישור לפני כתיבת קוד.