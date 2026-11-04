# פרומפט 16 — מודל נתוני רישום זמני (TTL Data Model)

## מטרה
איך לתכנן מבנה נתונים שמייצג מחזור חיים שלם. יישום מודל TTL עם Schema, מצבים וכתיבה אטומית.

## קבצים צפויים
`scripts/lib/ttl-model.sh`, `tests/unit/test_ttl_model.sh`

## קריטריון אימות
הרץ את הבדיקות וודא שכל המעברים נבדקים.

## מה לומדים
איך לתכנן מבנה נתונים שמייצג מחזור חיים שלם.

---

```text
PROMPT 16 — TTL Data Model

Implement scripts/lib/ttl-model.sh:

1. Define the TTL record structure (SRS section 13):
   - managed_id: UUID v4
   - rule: canonical rule string
   - rule_sha256: hash of rule
   - created_at: Epoch
   - expires_at: Epoch
   - created_by: actor identity
   - scope: device-specific or vidpid-wide
   - status: pending | active | inconsistent | recovery_required
   - correlation_id: UUID v4

2. Function create_ttl_record(): create new record with pending status.
3. Function get_ttl_record(managed_id): retrieve record by ID.
4. Function update_ttl_status(managed_id, new_status): atomic update.
5. Function list_ttl_records(filter): list records, optionally filtered.

Constraints:
- Use atomic-write.py for all writes.
- Do NOT store Rule ID as permanent identifier.

Create tests/unit/test_ttl_model.sh that tests:
- Create and retrieve record
- Status transition pending -> active
- Invalid status transition rejected
- Corrupt file handling

Run tests and report results.
```

## משימות מפורטות
ממש את מודל הנתונים של TTL לפי ה-SRS. אין עדיין לבצע פעולות שמשנות policy.

קובץ המצב הוא `ttl.json` בנתיב שהוגדר ב-SRS (סעיף 10 ב-USB.md: `/var/lib/usbguard-approval-manager/ttl.json`).

1. השתמש ב-schema ובגרסת פורמט מפורשים (`schema_version`).
2. כלול רק שדות הנדרשים לזיהוי, תזמון והתאוששות.
3. אל תשמור Rule ID כזיהוי יציב.
4. הגדר כיצד מזהים כלל זמני באופן חד-משמעי.
5. דחה רשומות עמומות או פגומות.
6. השתמש בכתיבה אטומית ובנעילה.
7. הגדר טיפול בקובץ חסר ובגרסת schema לא נתמכת.
8. אל תמחק רשומות לא עקביות אוטומטית.
9. ודא שניתן להבחין בין מצב מתוכנן, מצב פעיל ומצב הדורש התאוששות.

## מצבי TTL הנתמכים (רק אלה)

- `pending`
- `active`
- `inconsistent`
- `recovery_required`

אין להוסיף שמות מצבים חדשים בלי צורך ואישור.

## בדיקות

- קריאת מצב תקין.
- כתיבת מצב.
- schema לא תקין.
- קובץ פגום.
- רשומה חסרה.
- מצב `recovery_required`.
- round-trip של נתונים.

## איסורים

- אין פעולות שמשנות policy בשלב זה.
