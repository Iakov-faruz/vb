# פרומפט 24 — פעולות מרובות (Batch Operations)

## מטרה
איך לטפל במספר פריטים בלי להסתיר כשלים חלקיים. יישום עיבוד באצ'ים עם דיווח על הצלחה חלקית.

## קבצים צפויים
`scripts/lib/stages.sh` (הוספת חלק), `tests/unit/test_batch.sh`

## קריטריון אימות
הרץ את הבדיקות וודא שהצלחה חלקית מדווחת נכון.

## מה לומדים
איך לטפל במספר פריטים בלי להסתיר כשלים חלקיים.

---

```text
PROMPT 24 — Batch Operations

Implement batch processing:

1. Validate each item individually before processing.
2. Process each item independently.
3. Record result for each item.
4. Distinguish: full success, full failure, partial success.
5. Do NOT report overall success if any item failed.
6. Prevent duplicate processing of same item.
7. Handle device disappearance mid-batch.
8. Use appropriate exit code for partial success (EXIT_PARTIAL=13).

Constraints:
- Do NOT rollback all items because one failed (unless SRS requires).
- Use locking and audit as defined.

Create tests for all scenarios. Run and report results.
```

## משימות מפורטות
לאפשר פעולות על מספר התקנים בלי להסתיר הצלחות חלקיות.

1. אמת כל פריט בנפרד לפני הפעולה המתאימה.
2. תעד תוצאה לכל פריט.
3. הבחן בין הצלחה מלאה, כישלון מלא והצלחה חלקית.
4. אל תציג הצלחה כוללת אם חלק מהפריטים נכשלו.
5. מנע טיפול כפול בפריטים זהים.
6. הגדר התנהגות ברורה כאשר התקן נעלם או שהמדיניות השתנתה במהלך הפעולה.
7. השתמש בנעילה ובמנגנון Audit כפי שהוגדרו.
8. אל תבצע rollback אוטומטי לכל הפעולות רק משום שפריט אחד נכשל, אלא אם ה-SRS דורש זאת ומגדיר דרך בטוחה.
9. שמור על קוד יציאה שמייצג תוצאה חלקית, אם נדרש ב-SRS (`EXIT_PARTIAL`).

## בדיקות

- כל הפריטים מצליחים.
- כל הפריטים נכשלים.
- חלק מצליחים וחלק נכשלים.
- כפילויות.
- התקן שנעלם.
- כשל Audit לפריט בודד.

## איסורים

- אין rollback גורף ללא דרישה מפורשת ומנגנון בטוח.
