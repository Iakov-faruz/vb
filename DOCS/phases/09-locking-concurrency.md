# פרומפט 09 — מנגנון נעילה (File Locking)

## מטרה
למנוע משני תהליכים לשנות את אותו קובץ בו-זמנית. בניית מנגנון נעילה עם flock ונעילה מרכזית.

## קבצים צפויים
`scripts/lib/lock.sh`, `tests/unit/test_lock.sh`

## קריטריון אימות
הרץ את הבדיקות וודא שאין "נעילה תקועה".

## מה לומדים
איך למנוע משני תהליכים לשנות את אותו קובץ בו-זמנית.

---

```text
PROMPT 09 — File Locking

Implement scripts/lib/lock.sh:

1. Use flock on a central lock file path.
2. Function acquire_lock(timeout_seconds):
   - Try to acquire lock
   - If timeout reached, return error code
   - If lock acquired, store file descriptor
3. Function release_lock():
   - Close file descriptor (releases lock)
   - Handle case where lock was not held
4. Trap EXIT to ensure lock is released on script termination.

Constraints (SRS SEC-03):
- Do NOT implement --force flag.
- Do NOT delete lock file to "fix" stuck locks.

Create tests/unit/test_lock.sh that tests:
- Lock acquisition succeeds when free
- Second acquisition fails/waits when held
- Lock released after function completes
- Lock released after simulated error

Run tests and report results.
```

## משימות מפורטות
1. השתמש במנגנון הנעילה שאושר בתכנון, כגון `flock`.
2. הגדר את נתיב קובץ הנעילה במקום מרכזי (על פי סעיף 10 ב-USB.md: `/run/lock/usbguard-approval-manager.lock`).
3. ודא שכל פעולה שמשנה מצב משותף משתמשת באותה מדיניות נעילה.
4. הגדר timeout או התנהגות מוגדרת במקרה שהנעילה תפוסה.
5. שחרר נעילה גם כאשר פעולה נכשלת.
6. אל תמחק קובץ נעילה באופן עיוור כדי "לפתור" נעילה תקועה.
7. מנע deadlock כתוצאה מקריאה חוזרת של רכיב שמנסה להשיג את אותה נעילה.
8. תעד את גבולות הנעילה כדי שלא ייווצרו מצבי ביניים לא מוגנים.

## בדיקות
- שתי פעולות מקבילות אינן משנות מצב בו-זמנית.
- timeout מטופל.
- כשל פנימי משחרר את הנעילה.
- אין גישה ל-USBGuard אמיתי.

## איסורים
- אל תבצע פעולות USBGuard בזמן בדיקות הנעילה.

## הסבר הנדרש
מדוע קובץ נעילה לבדו אינו מבטיח תקינות אם חלק מהפעולות אינן משתמשות באותו מנגנון.