# פרומפט 27 — יחידות מערכת (systemd Units)

## מטרה
איך להגדיר שירות שרץ אוטומטית במערכת. יצירת קובצי יחידת systemd עבור שירות הניקוי וטיימר מחזורי.

## קבצים צפויים
`systemd/usbguard-approval-ttl.service`, `systemd/usbguard-approval-ttl.timer`

## קריטריון אימות
הרץ את פקודת האימות וודא שאין שגיאות תחביר.

## מה לומדים
איך להגדיר שירות שרץ אוטומטית במערכת.

---

```text
PROMPT 27 — systemd Units

Create systemd unit files:

1. usbguard-approval-ttl.service:
   - Type=oneshot
   - ExecStart=/usr/libexec/usbguard-approval-manager/cleanup-expired.sh
   - After=usbguard.service
   - Hardening: ProtectSystem=strict, PrivateTmp=true, NoNewPrivileges=true
   - ReadWritePaths: state dir, backup dir, log dir, lock path

2. usbguard-approval-ttl.timer:
   - OnBootSec=1min
   - OnUnitActiveSec=5min

Constraints:
- Do NOT add CAP_DAC_OVERRIDE by default.
- Include lock path in ReadWritePaths.
- Use exact paths from SRS.

Verify syntax with: systemd-analyze verify <unit-file>
Report results.
```

## משימות מפורטות
ממש את קובצי הפריסה ואת יחידות systemd לפי ה-SRS.

1. השתמש במשתמש ובקבוצות שהוגדרו בתכנון (`usbadmins`).
2. הגדר בעלות והרשאות מדויקות לקבצים ולספריות (על פי סעיף 10 ב-USB.md).
3. אל תפעיל את השירות כ-root אם אין בכך צורך מפורש.
4. הגדר `ReadWritePaths` לכל הנתיבים שהשירות חייב לכתוב אליהם, לרבות נתיב הנעילה וקובצי המצב, לפי התכנון המאושר.
5. השתמש בהגבלות systemd המתאימות ליכולות השירות.
6. אל תחסום גישה הנדרשת ל-USBGuard IPC.
7. הגדר התנהגות בעת restart וכשל.
8. ודא שהתקנת גרסה חדשה אינה מוחקת TTL, Audit או גיבויים קיימים.
9. הוסף מנגנון rollback של פריסה בהתאם ל-SRS.
10. אל תפעיל את השירות באופן אוטומטי על מחשב העבודה כחלק מהבדיקה.
11. בצע בדיקות התקנה והסרה בסביבת מעבדה.
12. אין להפעיל `systemctl enable` או שירות בעל השפעה על policy מחוץ לסביבת המעבדה המאושרת.

## בדיקות

- בדיקת תחביר יחידות systemd.
- הרשאות קבצים.
- גישה נדרשת ל-IPC.
- נתיבי כתיבה.
- restart.
- שימור נתונים.
- rollback.
- הפעלה תחת המשתמש המוגדר.
