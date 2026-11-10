# פרומפט 05 — מבנה תיקיות וקובץ הגדרות לדוגמה (Project Skeleton)

## מטרה
איך לבנות שלד של פרויקט בצורה מסודרת. יצירת מבנה תיקיות מינימלי לפי SRS סעיף 9, קובץ הגדרות לדוגמה ו-.gitignore — ללא לוגיקה עסקית.

## קבצים צפויים
`README.md`, `conf/approval-manager.conf.example`, `.gitignore`

## קריטריון אימות
`find . -type f | sort` צריך להציג את הקבצים שנוצרו.

## מה לומדים
איך לבנות שלד של פרויקט בצורה מסודרת.

---

```text
PROMPT 05 — Project Skeleton

Create the minimal project skeleton:

1. Create directory structure per SRS section 9:
   scripts/lib/, conf/, systemd/, tests/unit/, tests/integration/, docs/

2. Create README.md with:
   - Project name and purpose
   - Reference to SRS v4.4 Final Frozen
   - Note that this is a development skeleton

3. Create conf/approval-manager.conf.example with these keys:
   BACKUP_KEEP=5
   TEMP_TTL_SECONDS=3600
   CLEANUP_INTERVAL_MINUTES=5
   IPC_TIMEOUT_SECONDS=5
   MIN_REASONABLE_EPOCH=1577836800
   MAX_CLOCK_JUMP_SECONDS=3600
   CHECK_DUPLICATES=true
   NOTIFY_DESKTOP=false
   LOG_LEVEL=INFO

4. Create .gitignore for bash/python project.

Do not implement any logic. Verify structure with `find . -type f | sort`.
```

## משימות מפורטות
1. צור את התיקיות והקבצים המינימליים הנדרשים (על פי סעיף 9 ב-USB.md).
2. הוסף README בסיסי המתאר את מטרת הפרויקט, סביבת הפיתוח והבדיקות.
3. הוסף תשתית בדיקות מתאימה לשפה ולכלים הקיימים.
4. הוסף `.gitignore` מתאים.
5. אל תוסף לוגיקת אישור USBGuard, TTL, Reaper או ממשק משתמש.
6. אל תוסף תלויות שאינן נחוצות לשלד.
7. ודא שהפרויקט ניתן לבדיקה גם ללא גישה לאינטרנט, ככל שהכלים מאפשרים.

## בדיקות קבלה
- מבנה הפרויקט תואם לתכנון.
- בדיקת smoke בסיסית עוברת.
- פקודות הבדיקה מתועדות.
- אין קבצים מיותרים.

## ערך החזרה
- הסבר לכל קובץ שנוצר ולמה הוא נדרש.
- רשימת הקבצים והתיקיות שנוצרו.

## איסורים
- אין commit עד לאישור בדיקות הקבלה (מתבצע לאחר הרצתן בפועל).