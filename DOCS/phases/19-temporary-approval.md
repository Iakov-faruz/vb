# פרומפט 18 — אישור זמני (Temporary Approval Flow)

## מטרה
איך לבצע פעולה מורכבת עם הרבה שלבים בצורה בטוחה. יישום זרימת אישור זמני עם פיצוי במצבי כשל.

## קבצים צפויים
`scripts/lib/stages.sh` (חלק אישור זמני), `tests/unit/test_temporary_approval.sh`

## קריטריון אימות
הרץ את הבדיקות וודא שמקרי כשל נבדקים.

## מה לומדים
איך לבצע פעולה מורכבת עם הרבה שלבים בצורה בטוחה.

---

```text
PROMPT 18 — Temporary Approval Flow

Implement temporary approval in scripts/lib/stages.sh:

Workflow (SRS section 12.2):
1. Validate request and device info.
2. Read current USBGuard state.
3. Acquire lock.
4. Check for existing duplicate rule.
5. Create TTL record with status=pending.
6. Add temporary rule via adapter.
7. Verify rule was added and device state changed.
8. Update TTL record to status=active.
9. Write audit entry.
10. Release lock.

Error handling:
- If step 6 fails after step 5: compensate (remove partial rule),
  mark record as inconsistent.
- If step 8 fails after step 7: mark record as inconsistent,
  do NOT claim success.

Constraints:
- Do NOT use permanent rule for temporary approval.
- Do NOT assume rule addition changes connected device state.

Create tests with mock adapter. Run and report results.
```

## משימות מפורטות
ממש את זרימת האישור הזמני לפי ה-SRS ובכפוף לתוצאות G-01.

השתמש ב-fake USBGuard לבדיקות יחידה. בדיקות אינטגרציה משנות policy ירוצו רק במעבדה המאושרת.

## זרימת העבודה

1. אמת את הבקשה ואת פרטי ההתקן.
2. רענן את מצב USBGuard.
3. רכוש נעילה.
4. בדוק אם כבר קיים כלל תואם או אישור פעיל.
5. מנע יצירת כלל כפול.
6. שמור מצב ביניים לפי הפרוטוקול שנקבע.
7. בצע את פעולת USBGuard שאומתה ב-G-01.
8. אמת את התוצאה.
9. עדכן את TTL באופן אטומי.
10. כתוב Audit.
11. אם התהליך נכשל באמצע, סמן מצב מתאים ואל תעמיד פנים שהפעולה הצליחה במלואה.

## איסורים קריטיים

- אסור להשתמש ב-`allow-device --permanent` לצורך אישור זמני.
- אל תניח שכל כשל מחייב rollback אוטומטי. אם מצב policy אינו ודאי, השתמש במנגנון התאוששות.
- לא ליצור כלל נוסף כאשר קיים כלל שמכסה את אותה פעולה.
- לא להחזיר הצלחה אם מצב המדיניות והמצב המקומי אינם תואמים.

## בדיקות

- אישור חדש.
- אישור כפול.
- כשל לפני שינוי policy.
- כשל אחרי שינוי policy.
- כשל בכתיבת TTL.
- כשל Audit.
- timeout.
- שתי בקשות במקביל.
- מצב לא ודאי.
