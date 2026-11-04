# פרומפט 23 — ממשק גרפי (TUI Implementation)

## מטרה
איך לבנות ממשק אינטראקטיבי בלי לשכפל לוגיקה עסקית. יישום TUI באמצעות whiptail שמפנה לשכבת השירות.

## קבצים צפויים
`scripts/usb-approve.sh` (הוספת חלק TUI), `tests/unit/test_tui.sh`

## קריטריון אימות
הרץ את הממשק (דורש התקנת whiptail) ובדוק שניתן לנווט ולבטל.

## מה לומדים
איך לבנות ממשק אינטראקטיבי בלי לשכפל לוגיקה עסקית.

---

```text
PROMPT 23 — TUI Implementation

Implement TUI using whiptail:

1. Display list of blocked devices (multi-select).
2. Ask for approval type (permanent/temporary).
3. Ask for TTL if temporary.
4. Show summary before executing.
5. Re-read device state before commit (SRS 4.0).
6. Display result based on actual outcome.

Constraints:
- TUI calls service layer, does not contain business logic.
- Handle Cancel/Escape gracefully.
- Do not hold lock while user is selecting.
- Do not display sensitive data.

Create tests for navigation and cancellation.
Run tests and report results.
```

## משימות מפורטות
ממש ממשק אינטראקטיבי בלי לעקוף את הלוגיקה העסקית.

1. ה-TUI קורא לשכבת השירות הקיימת; אין לשכפל בו לוגיקה עסקית.
2. הצג רק פעולות שהמשתמש מורשה לבצע.
3. טפל ב-Cancel, Escape, קלט ריק וקלט לא תקין.
4. לפני אישור פעולה שמשנה מדיניות, הצג סיכום ברור של הפעולה.
5. לפני ביצוע הפעולה, קרא מחדש את מצב הנתונים כדי למנוע פעולה על מידע שהתיישן.
6. הצג הצלחה וכישלון לפי תוצאת הפעולה האמיתית.
7. אל תציג פעולה שהצליחה כאשר Audit או עדכון מצב נכשלו באופן שמשפיע על התוצאה.
8. ודא שהממשק אינו חושף מידע רגיש למשתמש לא מורשה.
9. אל תציג שההתקן נחסם אם רק הוסר כלל זמני.

## בדיקות

- ניווט.
- ביטול.
- קלט לא תקין.
- מצב שהשתנה בזמן התפריט.
- כישלון פעולה.
- תצוגת תוצאה נכונה.

## איסורים

- אין לשכפל לוגיקה עסקית בתוך ה-TUI.
