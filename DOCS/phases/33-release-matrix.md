# פרומפט 32 — בדיקת שחרור סופית (Final Release Audit)

## קבצים צפויים
אין קבצי קוד חדשים. רק דוח שחרור.

## קריטריון אימות
בדוק שהדוח כולל החלטה מנומקת.

## מה לומדים
איך להחליט אם מוצר מוכן לשימוש.

---

```text
PROMPT 32 — Final Release Audit

READ-ONLY FINAL AUDIT. Do not modify files.

1. Rebuild requirements traceability matrix.
2. Verify each acceptance criterion against evidence.
3. Run safe validation commands.
4. Review full Git diff for unrelated changes.
5. Check for secrets, debug files, or sensitive data.
6. Review test results and identify gaps.
7. Verify documentation matches implementation.
8. Identify requirements needing hardware/lab validation.
9. Do NOT claim production readiness if evidence is missing.

Produce:
- Executive summary.
- Requirement-by-requirement status.
- Security findings by severity.
- Outstanding blockers.
- Decision: READY FOR LAB VALIDATION / NOT READY / READY FOR RELEASE REVIEW.

Explain the evidence supporting the decision. Stop.
```

## משימות מפורטות
בצע סקירת שחרור מלאה מול SRS v4.4 Final Frozen (`USB.md`).

אל תוסיף תכונות ואל תבצע refactor רחב. תקן רק ליקויים שאושרו.

## משימות

1. בדוק את כל מזהי הבדיקות שמוגדרים ב-SRS.
2. ודא שכל מזהה בדיקה ממופה למימוש, לפקודת הרצה ולתוצאה.
3. הרץ בדיקות יחידה.
4. הרץ בדיקות אינטגרציה בסביבה המתאימה.
5. ודא ש-G-01 הושלם עם ראיות, או סמן במפורש שהוא עדיין לא מאומת.
6. בדוק מקרי כשל: USBGuard לא זמין, שעון לא מהימן, Audit נכשל, קובץ TTL פגום, נעילה תפוסה ושחזור שנכשל.
7. בדוק שכל קודי היציאה תואמים לתוצאה האמיתית.
8. בדוק שאין שימוש שגוי ב-`allow-device`, `append-rule` או `remove-rule`.
9. ודא שהסרת כלל זמני אינה מדווחת בטעות כחסימת התקן.
10. בדוק הרשאות, בעלות, קובצי systemd ונתיבי כתיבה.
11. הרץ בדיקות סטתיות וכלי lint זמינים.
12. בדוק שאין סודות, נתיבי בדיקה רגישים או קובצי debug מיותרים ב-repository.
13. עדכן README, מדריך התקנה, מדריך הפעלה, מדריך התאוששות ותיעוד הבדיקות.
14. הצג את כל הפערים שעדיין פתוחים.

## דוח שחרור

הפק דוח שחרור עם:
- PASS / FAIL / BLOCKED לכל בדיקה.
- פקודות מדויקות ותוצאות.
- ראיות עבור G-01.
- דרישות שלא הוכחו.
- סיכונים שנותרו.
- רשימת commits.
- המלצה מנומקת אם ניתן לשחרר את הגרסה.

## איסורים

- אין להכריז על `READY FOR PRODUCTION` כאשר G-01 או דרישת אבטחה חובה אחרת עדיין לא אומתה.
- לא מוסיפים תכונות חדשות בשלב זה.
