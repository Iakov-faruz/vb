# פרומפט 08 — לוגים וביקורת (Logging and Audit)

## מטרה
לתעד פעולות ותוצאות באופן אמין, לפי ה-SRS. בנייה של שתי זרמי לוג נפרדים (תפעולי וביקורת) עם פורמט מובנה וסניטיזציה של קלט.

## קבצים צפויים
`scripts/lib/logger.sh`, `tests/unit/test_logger.sh`

## קריטריון אימות
בדוק שקובץ הלוג נוצר בפורמט הנכון.

## מה לומדים
איך לתעד פעולות בצורה שאי אפשר לזייף.

---

```text
PROMPT 08 — Logging and Audit

Implement scripts/lib/logger.sh:

1. Two separate log streams (SRS SEC-09):
   - log_info/log_error → standard log
   - log_audit → separate audit log

2. Audit format (SRS 17.2):
   [UTC_TIMESTAMP] [AUDIT] [ACTOR] [ACTION] [RESULT] [CORRELATION_ID] DETAILS

3. Actor detection:
   - If SUDO_UID is set, use it
   - Otherwise use current UID
   - If unknown, use "unknown"

4. Sanitize function: remove newlines and control characters from input.

5. Handle write failures gracefully (do not crash, report error).

Create tests/unit/test_logger.sh that tests:
- Normal audit entry format
- Input with embedded newline (should be sanitized)
- Write failure simulation

Run tests and report results.
```

## משימות מפורטות
1. הפרד בין הודעות תפעוליות לבין אירועי Audit.
2. כלול את השדות הנדרשים ב-SRS: זמן, פעולה, תוצאה, זהות רלוונטית ומידע נוסף שנדרש.
3. אל תשמור סודות, נתוני אימות או מידע רגיש מיותר.
4. אמת ערכים לפני כתיבה כדי למנוע זיוף רשומות באמצעות newline או תווים מיוחדים.
5. הגדר הרשאות מתאימות לקובץ ולספריית Audit.
6. התנהג נכון כאשר הקובץ אינו ניתן לכתיבה, מלא או אינו זמין.
7. שמור על ההבחנה בין `POLICY_APPLIED` לבין `POLICY_APPLIED_AUDIT_FAILED`.
8. אל תאפשר לכשל Audit להסתיר שינוי מדיניות שכבר בוצע.

## בדיקות
- אירוע תקין נכתב בפורמט הצפוי.
- קלט זדוני אינו יוצר רשומת Audit מזויפת.
- כשל כתיבה נבדק.
- התוצאה המוחזרת תואמת למצב האמיתי.
- לא בוצעה פעולת USBGuard.

## איסורים
- לא בוצעה פעולת USBGuard בשלב זה.