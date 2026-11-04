# פרומפט 21 — התאוששות ממצבים לא עקביים (Recovery Mechanism)

## מטרה
איך לטפל במצבים שבהם "משהו השתבש" בלי לעשות נזק נוסף. יישום מנגנון התאוששות עם זיהוי מצבים וקבלת החלטות.

## קבצים צפויים
`scripts/lib/recovery.sh`, `tests/unit/test_recovery.sh`

## קריטריון אימות
הרץ את הבדיקות וודא שכל המצבים נבדקים.

## מה לומדים
איך לטפל במצבים שבהם "משהו השתבש" בלי לעשות נזק נוסף.

---

```text
PROMPT 21 — Recovery Mechanism

Implement scripts/lib/recovery.sh:

Handle these inconsistent states:
1. Policy changed but TTL not updated.
2. TTL updated but policy not changed.
3. TTL file corrupt.
4. Clock unreliable.
5. USBGuard unavailable.
6. Ambiguous rule match.
7. Audit failed after successful policy change.

For each state:
- Define detection criteria.
- Define whether automatic repair is safe.
- Define when human intervention is required.
- Preserve evidence for investigation.

Constraints:
- Do NOT modify policy when state is ambiguous.
- Do NOT delete records to "fix" inconsistency.
- Maintain idempotency: running recovery twice should not cause
  additional changes.

Create tests for each state. Run and report results.
```

## משימות מפורטות
ממש מנגנון התאוששות לפי ה-SRS.

## מצבים שיש לטפל בהם לפחות בהם

- policy השתנתה אך TTL לא עודכן.
- TTL עודכן אך policy לא השתנתה.
- מצב TTL פגום.
- השעון אינו מהימן.
- USBGuard אינו זמין.
- התאמה לכלל אינה חד-משמעית.
- Audit נכשל לאחר שינוי מוצלח.
- התקן עדיין מאושר אחרי הסרת כלל זמני.

## דרישות

1. הגדר אילו מצבים ניתן לזהות באופן אמין.
2. הגדר אילו תיקונים בטוחים ואילו דורשים התערבות.
3. שמור מידע הדרוש לחקירת הכשל.
4. אל תשנה policy כאשר המצב עמום.
5. שמור Audit של ניסיונות התאוששות.
6. ודא שהרצה חוזרת אינה גורמת לשינויים בלתי צפויים (idempotency).
7. אל תסיר או תיצור כללים רק כדי לגרום ל-TTL להיראות עקבי.
8. הצג תוצאה ברורה למפעיל.

## בדיקות

- כל מצב לא עקבי.
- התאוששות מוצלחת.
- התאוששות שנכשלה.
- הפעלה חוזרת.
- Audit שנכשל.
- מצב שדורש התערבות אנושית.

## איסורים

- אין שינוי policy כאשר המצב עמום.
