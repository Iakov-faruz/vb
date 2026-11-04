# פרומפט 12 — בדיקות זמן ושעון (Time Guards)

## מטרה
איך לטפל בזמן בצורה בטוחה (לא לסמוך על השעון בעיוורון). יישום פונקציות קריאת Epoch, בדיקת אמינות שעון וזיהוי קפיצות שעון.

## קבצים צפויים
`scripts/lib/time-guards.sh`, `tests/unit/test_time_guards.sh`

## קריטריון אימות
הרץ את הבדיקות. ודא שאף בדיקה לא משנה את שעון המערכת.

## מה לומדים
איך לטפל בזמן בצורה בטוחה (לא לסמוך על השעון בעיוורון).

---

```text
PROMPT 12 — Time Guards

Implement scripts/lib/time-guards.sh:

1. Function get_current_epoch(): return current Unix timestamp.

2. Function is_clock_reasonable():
   - Check current time > MIN_REASONABLE_EPOCH
   - Check current time < some sane maximum (e.g. year 2100)
   - Return 0 if reasonable, 1 if suspicious

3. Function detect_clock_jump(last_known_time):
   - Compare current time with last known
   - If difference > MAX_CLOCK_JUMP_SECONDS, return warning
   - Do NOT change system clock

4. Note: TTL is calendar-based (Epoch). If clock is unreliable after
   reboot, do NOT auto-restore permissions (SRS time model).

Create tests/unit/test_time_guards.sh that tests:
- Current time is reasonable
- Simulated past timestamp (before 2020) is flagged
- Clock jump detection works

Run tests and report results.
```

## משימות מפורטות
1. השתמש ב-Epoch לציון זמני תפוגה, לפי ה-SRS.
2. הפרד בין זמן נוכחי, זמן יצירה וזמן תפוגה.
3. ודא שערכים שליליים, חסרים או לא תקינים נדחים.
4. בדוק overflow וטווחים בלתי סבירים.
5. אל תסיק שהשעון אמין רק משום שהוא מחזיר timestamp.
6. יישם רק קריטריוני clock trust שאושרו ב-SRS וב-G-01.
7. אם אין דרך להוכיח שהשעון אמין לאחר reboot, החזר מצב מפורש שמונע תפוגה או הארכה אוטומטית מסוכנת.
8. אל תשנה את שעון המערכת כחלק מהבדיקה.
9. אל תמציא סף סטייה או כלל זמן חדש בלי לתעד את ההחלטה ולקבל אישור.
10. אל תוסיף עדיין Reaper שמבצע שינויי policy.

## בדיקות
- זמן תקין.
- זמן לא תקין.
- תפוגה שכבר חלפה.
- שעון שאינו מהימן.
- התנהגות לאחר reboot מדומה.
- ערכי קצה.

## ערך הנדרש
הצג מה הבדיקות מוכיחות ומה מחייב בדיקה במערכת אמיתית.

## איסורים
- אין Reaper מבצע שינויי policy בשלב זה.