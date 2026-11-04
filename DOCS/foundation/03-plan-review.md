# פרומפט 03 — ביקורת התוכנית (Plan Review)

## מטרה
לבדוק את תוכנית המימוש מפרומפט 02 מול ה-SRS לפני שמתחילים לכתוב קוד. שלב סקירה בלבד — לא מבצעים שינויים בקוד.

## קבצים צפויים
אין קבצי קוד. רק דוח סקירה.

## קריטריון אימות
הסוכן צריך להצביע על משימה ראשונה ספציפית ובטוחה להתחיל ממנה.

## מה לומדים
איך לבדוק תוכנית לפני שמתחילים לבצע אותה, ואיך לזהות פערים וסיכונים מוקדם.

---

```text
PROMPT 03 — Plan Review

READ-ONLY REVIEW. Do not modify files.

Review the implementation plan from PROMPT 02 against the SRS.

Check:
1. Every SRS requirement is covered or marked as blocked.
2. No requirement was invented or reinterpreted.
3. Security-critical tasks are not deferred.
4. Dependencies are correct (no task depends on something not yet built).
5. Acceptance criteria are measurable.

Return: list of gaps, corrections needed, and the safest first task.
Stop for approval.
```

## משימות מפורטות
בדוק את תוכנית המימוש מפרומפט 02 מול ה-SRS (USB.md):

1. האם כל דרישת SRS מכוסה או מסומנת כמחוסמת?
2. האם לא הומצאה או פורשה מחדש דרישה שלא קיימת במפרט?
3. האם משימות אבטחה קריטיות לא נדחו לשלב מאוחר?
4. האם התלויות נכונות (שום משימה לא תלויה במשהו שעדיין לא נבנה)?
5. האם קריטריוני הקבלה ניתנים למדידה?

## ערך החזרה
- רשימת פערים שנמצאו.
- תיקונים נדרשים.
- המשימה הראשונה והבטוחה ביותר להתחיל ממנה.

## איסורים
- לא משנים קוד במהלך הביקורת.
- לא מתקנים את התוכנית בעצמך — מציגים את הממצאים לאישור.