# פרומפט 17 — התאמה לקריאה בלבד (Read-Only Reconciliation)

## מטרה
איך לגלות פערים בין מה שכתוב בקובץ לבין מה שבאמת קורה במערכת. יישום השוואה קריאה בלבד בין רקורדי TTL לכללי USBGuard הפעילים.

## קבצים צפויים
`scripts/lib/reconcile.sh` (חלק קריאה), `tests/unit/test_reconcile.sh`

## קריטריון אימות
הרץ את הבדיקות וודא שהדוח מובנה.

## מה לומדים
איך לגלות פערים בין מה שכתוב בקובץ לבין מה שבאמת קורה במערכת.

---

```text
PROMPT 17 — Read-Only Reconciliation

Implement read-only reconciliation in scripts/lib/reconcile.sh:

1. Compare TTL records with active USBGuard rules.
2. Identify:
   - TTL records without matching active rule (orphaned records)
   - Active temporary rules without TTL record (orphaned rules)
   - Duplicates (multiple rules matching same record)
   - Ambiguous matches (cannot determine which rule matches)

3. Return structured report:
   - consistent: everything matches
   - inconsistent: problems found (list them)
   - unknown: cannot determine (e.g., IPC unavailable)

Constraints:
- Do NOT add or remove rules.
- Do NOT modify TTL file.
- Do NOT assume missing rule means device is blocked.

Create tests/unit/test_reconcile.sh with mock data.
Run tests and report results.
```

## משימות מפורטות
ממש רכיב שמשווה בין מצב TTL המקומי לבין מצב USBGuard, בלי לשנות policy.

## השווה בין

- רשומות TTL.
- הכללים הפעילים.
- קובץ המדיניות הקבוע, כאשר נדרש ב-SRS.
- מצב ההתקנים הרלוונטי.

## זהה

1. רשומת TTL ללא כלל תואם.
2. כלל זמני ללא רשומת TTL תואמת.
3. כפילויות.
4. התאמה עמומה.
5. כלל קבוע שחופף לכלל זמני.
6. חוסר אפשרות לקרוא את מצב USBGuard.
7. מצב שבו השעון אינו מהימן.

## דרישות

- אל תוסיף או תסיר כללים.
- אל תחסום התקנים.
- אל תציג התקן כחסום רק משום שאין כלל זמני.
- אל תסיק שהמצב תקין כאשר חסרים נתונים.
- הפק תוצאה מובנית שמבדילה בין תקין, לא עקבי ולא ניתן לקביעה.
- מצב עמום חייב להוביל להמלצה או למצב התאוששות, לא לתיקון אוטומטי.

## בדיקות

- מצב עקבי.
- רשומת TTL יתומה.
- כלל יתום.
- כלל קבוע חופף.
- כפילויות.
- התאמה עמומה.
- USBGuard לא זמין.

## איסורים

- אין שינוי policy בשלב זה.
