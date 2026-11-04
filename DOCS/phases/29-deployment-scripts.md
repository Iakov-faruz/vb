# פרומפט 28 — הרשאות ופריסה (Deployment Scripts)

## מטרה
איך להתקין תוכנה בצורה מאובטחת ואידמפוטנטית. יישום סקריפטי פריסה, הסרה וקובץ sudoers מצומצם.

## קבצים צפויים
`deploy.sh`, `deploy-lib.sh`, `deploy-uninstall.sh`, `sudoers/usbguard-approval`

## קריטריון אימות
הרץ את הסקריפט בסביבת מעבדה וודא שהוא אידמפוטנטי.

## מה לומדים
איך להתקין תוכנה בצורה מאובטחת ואידמפוטנטית.

---

```text
PROMPT 28 — Deployment Scripts

Implement deployment:

1. deploy.sh:
   - Pre-flight checks (dependencies, disk space, IPC).
   - Read USBGuard configuration (do not assume paths).
   - Show diff of existing policy, require approval.
   - Create directories with correct permissions.
   - Install files.
   - Initialize TTL file if missing.
   - Install systemd units and sudoers.
   - Run validate_all.sh at the end.

2. deploy-uninstall.sh:
   - Stop services.
   - Remove installed files.
   - Preserve backups and logs by default.

3. sudoers/usbguard-approval:
   - Allow usbadmins to run specific commands only.
   - Do NOT allow shell or general commands.

Constraints:
- Script must be idempotent.
- Do NOT overwrite existing USBGuard rules.
- Do NOT enable services on development host automatically.

Test in lab environment only. Report results.
```

## משימות מפורטות
ממש את סקריפטי הפריסה לפי ה-SRS.

1. בדיקות מקדימות (תלויות, שטח דיסק, IPC).
2. קרא את תצורת USBGuard (אל תניח נתיבים).
3. הצג diff של המדיניות הקיימת, דרוש אישור.
4. צור ספריות עם הרשאות נכונות.
5. התקן קבצים.
6. אתחל קובץ TTL אם חסר.
7. התקן יחידות systemd ו-sudoers.
8. הרץ validate_all.sh בסוף.

## סקריפט הסרה (deploy-uninstall.sh)

1. עצור שירותים.
2. הסר קבצים מותקנים.
3. שמור גיבויים ולוגים כברירת מחדל.

## קובץ sudoers

1. אפשר למשתמשי usbadmins להריץ פקודות ספציפיות בלבד.
2. אל תאפשר shell או פקודות כלליות.

## איסורים

- הסקריפט חייב להיות אידמפוטנטי.
- אל תדרוס כללי USBGuard קיימים.
- אל תפעיל שירותים באופן אוטומטי במחשב הפיתוח.
- בדיקות בסביבת מעבדה בלבד.