# תוכנית `rebuild` — בניית היסטוריה לוגית מדורגת (Orphan)

**סטטוס:** מוכן לביצוע רק לאחר אישור מפורש של צ’קליסט ההחלטות (סעיף 10).  
**כלל עצירה:** לא ייווצר worktree/ענף `rebuild`, לא יבוצעו קומיטים, ולא יתבצע `push`/`merge`/`rebase`/מחיקת ענפים עד לאישור מפורש פר-סעיף.

---

## 1. מטרה

ליצור ענף Git חדש וריק בשם `rebuild` (orphan) ב-worktree מבודד, ולהעביר אליו קבצים מהריפו בקומיטים מסודרים לפי שכבות ארכיטקטוניות. ההיסטוריה תשקף התפתחות לוגית של גרסאות קבצים סופיות/מאושרות (לא שחזור כרונולוגי).

## 2. תמונת מצב נוכחית

| פריט | ערך |
|---|---|
| ריפו עבודה מתוכנן | `C:\Users\5722y\Downloads\USB` (`origin`: `https://github.com/Iakov-faruz/vb.git`) |
| `main` מקומי / `origin/main` | `0964b04` — `fix: harden installer and validation tooling before rebuild` (נדחף, fast-forward) |
| בסיס קודם | `56fded1` (`backup/origin-main`, `backup/main-before-rewrite`, `backup/main-original-messages-20261110`) |
| `docs/hebrew-comments` | `802517f` — `docs(usb-approve): add detailed Hebrew inline documentation` (ללא שינוי; מכיל גם `9e71b12`) |
| ענף תיקוני קדם-rebuild | `fix/pre-rebuild` @ `0964b04` |
| גיבוי נוסף | `backup/docs-hebrew-comments-before-cleanup` @ `eea113f` |
| worktree קיים | `C:\Users\5722y\Downloads\main-fix` → `fix/pre-rebuild` |

**הערת הקשר:** `C:\Users\5722y\Desktop\vb` (`5722yz-ops/USB5722.git`, `08e1b09`) ו-`C:\Users\5722y\Desktop\USB` (לא ריפו Git) אינם בסיס לתוכנית זו, אלא אם יאושר מיזוג/העתקה מפורש.

## 3. עקרונות וכללי בטיחות

- **הגנה על מצב קיים:** לא לשנות/לדרוס/למחוק `main`, `origin/main`, `docs/hebrew-comments`, או כל `backup/*`. `docs/hebrew-comments` לא ימוזג ל-`rebuild` ולא יימחק.
- **בידוד:** עבודה רק ב-worktree מבודד (למשל `..\rebuild-wt`). אסור `git switch --orphan` או `git rm -rf .` בעץ הראשי; מותר `git rm -rf --cached .` רק בתוך ה-worktree החדש.
- **היסטוריה לוגית:** קומיטים מוקדמים עשויים לא להיות ניתנים להרצה/בדיקה עקב תלויות בין-שלביות — מוצהר ומכוון.
- **החרגות קבועות:** `.venv/`, `__pycache__/`, `*.pyc`, `.benchmarks/`, `.pytest_cache/`, `.ruff_cache/`, `*.log`, מטמון/לוגים מקומיים, סודות וקונפיגורציה מקומית.
- **שלמות:** לא להמציא נתיבים/קבצים; לא לכלול ארטיפקטים; לא לערבב שלבים בקומיט.
- **היקף:** שחזור/ארגון היסטוריה בלבד — ללא תיקון באגים בקוד הקיים אלא אם אושר במפורש כחריג. באגים/אי-עקביויות קיימים מתועדים ומועתקים כפי שהם.
- **איסורים ללא אישור מפורש:** `push`, `merge`, `rebase`, מחיקת ענפים, יצירת קבצים שאינם במקור (חריג מאושר אם יוחלט: `.gitignore` שורש לאתחול orphan, ו-`INSTALL-FROM-SCRATCH.md` ב-C8C אם יאושר).
- **ארטיפקט tracked:** `__pycache__/vm_client.cpython-313.pyc` הוסר ממעקב ב-`main` (`0964b04`); יוחרג גם מ-`rebuild`.

## 4. בסיס קוד אחרי תיקוני קדם-rebuild (main @ `0964b04`)

שינויים שכבר בוצעו, נבדקו תחבירית (`bash -n`, `py_compile`) ונדחפו ל-`origin/main`:

| תחום | תוצאה |
|---|---|
| `install-usbguard-approval-manager.sh` | הוחקש: ללא `enable --now` לטיימרים, ללא שינוי הרשאות `/run/lock`, יצירת lock/`ttl.json`/`audit.jsonl`, הרשאות libexec/log/state מותאמות, הוספת `usbguard-status.sh`, config מ-`conf/` + example ל-`config/`, חבילות מותאמות, lib files `0640` |
| `usbguard-approval-manager/deploy.sh`, `Makefile` | קריאות `validate_all.sh` מוּפנות ל-`$PROJECT_ROOT/scripts/validate_all.sh`; הוסרה כפילות ב-`Makefile` |
| `usbguard-approval-manager/scripts/lib/lifecycle.py` | נוסף `validate-backup` (parser+dispatch, `read_backup`) |
| שורש הריפו | נוסף `.gitignore`; `__pycache__/vm_client.cpython-313.pyc` הוסר ממעקב |
| תכנון/מסמכים | `DOCS/root-docs/REBUILD_PLAN.md` עודכן בענף `docs/hebrew-comments` (לא ב-`main`) |

**עדיין ידוע/לא מתוקן בכוונה:** אי-עקביות היסטורית של מיקום `validate_all.sh` מול ציפיות שונות בקוד (מתועד), `validate-backup`/זרימת בדיקות גיבוי בסביבות מסוימות ותלויות runtime (בעיה 4.4 במסמך קודם — לאמת מול קוד בסיס ה-rebuild), פערי installer מול SRS אם ייכלל ב-C8B כמות שהוא (מתועד), E2E/VM — `UNVERIFIED`.

## 5. ממצאי מיפוי ותלויות

### 5.1 תלויות מאושרות (עיקריות)
- `usbguard-policy.sh` (C4) → `lock.sh` (C3)
- `stages.sh` (C5) → `config-reader.sh`/`validators.sh` (C3), `usbguard-policy.sh` (C4), `time-guards.sh` (C5)
- `time-guards.sh` → `clock_state.py` (C2)
- `usb-approve.sh`/`usb-revoke.sh` (C6) → `stages.sh` (C5)
- `backup.sh`/`restore.sh` (C7) → `journal.sh` (C5), `usbguard-policy.sh` (C4)
- `deploy.sh` (C8) → `usbguard-policy.sh` (C4) ו-`validate_all.sh` (לכן `C9a` לפני `C8`)
- `deploy.sh` מתקין `conf/approval-manager.conf.example` כקונפיג ומעתיק `config/usbguard-approval-manager.conf.example` כדוגמה — שניהם ב-C8A.

### 5.2 נתיבים חסרים/לא ליצירה אוטומטית
| נתיב מוצע | סטטוס | החלטה מוצעת |
|---|---|---|
| `.gitignore` (שורש) | חסר בבסיס מקור לפני `0964b04`; קיים ב-`main` המעודכן | לקבוע האם לכלול בקומיט אתחול orphan (ראו N4/D13) |
| `README.md` (שורש) | חסר | לא ליצור ללא אישור |
| `usbguard-approval-manager/.gitkeep`, `config/.gitkeep`, `conf/.gitkeep` | חסרים; תיקיות לא ריקות | לא ליצור |

### 5.3 כפילויות/וריאציות (tracked, תוכן שונה) — דורשות קנוניות
| קבוצה | נתיבים | הערה |
|---|---|---|
| config-reader | `scripts/lib/config-reader.sh` ↔ `usbguard-approval-manager/scripts/lib/config-reader.sh` | חבילה ב-C3; שורש רק ב-Cx אם יאושר |
| config examples | `etc/.../approval-manager.conf.example`, `usbguard-approval-manager/conf/...example`, `usbguard-approval-manager/config/...example` | עותקים שונים; לאמת שימוש בפועל |
| logrotate/sudoers/systemd | root `logrotate|sudoers|systemd/*` ↔ `usbguard-approval-manager/{logrotate,sudoers,systemd}/*` | שונים; לאמת נתיבי deploy/install לפני C8 |

**בדיקה חובה לפני C8:** `grep` ב-`deploy.sh`, `deploy-lib.sh`, `install-usbguard-approval-manager.sh` לנתיבי `etc/`, `systemd/`, `sudoers/`, `logrotate/` והצגת ממצאים לאישור C8A/C8B/Cx.

### 5.4 tracked לא במיפוי המקורי
| נתיב | שיוך מוצע |
|---|---|
| `__pycache__/vm_client.cpython-313.pyc` | **החרגה** מ-rebuild (כבר הוסר מ-`main`) |
| `scripts/lib/.gitkeep`, `scripts/lib/config-reader.sh` | Cx או החרגה |
| root `etc/.../approval-manager.conf.example`, `logrotate/*`, `sudoers/*`, `systemd/*` | C8B או החרגה (לפי grep) |
| `usbguard-approval-manager/.gitignore`, `README.md`, `Makefile` | C0 |
| `usbguard-approval-manager/conf/...example`, `config/...example` | C8A |
| `usbguard-approval-manager/logrotate|sudoers|systemd/*` | C8A |
| `usbguard-approval-manager/scripts/backup-rules.sh`, `restore-rules.sh`, `restore.sh` | C7 |
| `usbguard-approval-manager/tests/integration/run_integration_tests.sh`, `test_T01..T28` | C9b |
| `usbguard-approval-manager/tests/integration/test_g01_adapter.sh`, `collect_g01_readonly_preflight.sh` | **C4 בלבד** (שיוך חד-פעמי) |

### 5.5 לא tracked (החרגה)
`.pytest_cache/**`, `.ruff_cache/**`, `.venv/**`, `**/__pycache__/**`, `**/*.pyc`, `.benchmarks/**`.

## 6. מקור תוכן לקבצים מתועדים בעברית

- **מומלץ:** מצב `docs/hebrew-comments` tip (`802517f`, כולל `9e71b12`): `usbguard-approval-manager/scripts/usb-approve.sh`, `usbguard-approval-manager/scripts/lib/atomic-write.py`, `usbguard-approval-manager/scripts/lib/audit_write.py`, `usbguard-approval-manager/scripts/lib/clock_state.py`.
- **אימות חובה לפני C2/C6:** הצגת `git diff 56fded1..802517f -- <4 paths>` (או שקול מול בסיס מאושר) ואישור שהתוכן המועתק הוא המתועד בלבד.

## 7. תוכנית קומיטים (סדר מתוקן)

> לפני כל קומיט: הצגת רשימת קבצים מדויקת וקבלת אישור. אחרי כל קומיט: `git status`, `git log --oneline --name-status -n 1`, ו-`py_compile`/`bash -n` לקבצים שנוספו (best-effort).

| קומיט | הודעה | נתיבים | הערות/תלויות |
|---:|---|---|---|
| Init (אם מאושר) | `chore: initialize empty orphan branch` | `.gitignore` שורש (תוכן מאושר) | לאחר `git switch --orphan rebuild` + `git rm -rf --cached .` |
| C0 | `chore: initialize project skeleton and directory structure` | `usbguard-approval-manager/.gitignore`, `usbguard-approval-manager/README.md`, `usbguard-approval-manager/Makefile` | `Makefile` לא מלא-פונקציונלי עד שלבים מאוחרים |
| C1 | `docs: add SRS, roadmap, and phase specifications` | `DOCS/**` (52) — נספח א׳ | ללא תלות קוד |
| C2 | `feat(lib): add atomic write, audit logger, and clock state primitives` | `scripts/lib/atomic-write.py` `[*]`, `audit_write.py` `[*]`, `clock_state.py` `[*]`, `tests/unit/__init__.py`, `test_atomic_write.py`, `test_audit_write.py` | תלויות import/run-time עתידיות ל-C3 אפשריות |
| C3 | `feat(lib): implement config parser, locking, result model, logging, and validators` | `scripts/lib/config-reader.sh`, `lock.sh`, `result.sh`, `logger.sh`, `validators.sh`, `tests/unit/test_config_reader.sh`, `test_lock.sh`, `test_result.sh`, `test_logger.sh`, `test_validators.sh` | `source` פנימי נכלל בקומיט |
| C4 | `feat(policy): implement USBGuard adapter and G-01 validation` | `scripts/lib/usbguard-policy.sh`, `tests/unit/test_policy_read.sh`, `test_policy_write.sh`, `test_g01_preflight_readonly.sh`, `tests/integration/test_g01_adapter.sh`, `tests/integration/collect_g01_readonly_preflight.sh`, `tests/quick/g01_status_check.sh`, `tests/quick/run_g01_integration.sh` | תלוי ב-C3; G-01 integration כאן פעם אחת בלבד |
| C5 | `feat(engine): add state management, TTL tracking, and expired rules reaper` | `scripts/lib/stages.sh`, `lifecycle.sh`, `lifecycle.py`, `journal.sh`, `time-guards.sh`, `scripts/cleanup-expired.sh`, `tests/unit/test_lifecycle.py`, `test_stages.sh`, `test_time_guards.sh`, `test_cleanup.sh`, `tests/quick/clock_time_check.sh` | תלוי ב-C2-C4 (צפוי) |
| C6 | `feat(cli): implement device approval, revocation, listing, and TUI interfaces` | `scripts/usb-approve.sh` `[*]`, `usb-revoke.sh`, `usb-revoke-interactive.sh`, `usb-list.sh`, `usbguard-status.sh`, `scripts/lib/tui.sh`, `tests/unit/test_usb_approve.sh`, `test_usb_revoke.sh`, `test_usbguard_status.sh`, `tests/quick/usb_device_check.sh` | תלוי ב-C5 |
| C7 | `feat(ops): implement backup, restore, import, and export` | `scripts/backup.sh`, `backup-rules.sh`, `restore.sh`, `restore-rules.sh`, `export-rules.sh`, `import-rules.sh` | תלוי ב-C4/C5 |
| **C9a** | `chore(qa): add validation tooling required by deployment` | `usbguard-approval-manager/scripts/validate_all.sh` | **לפני C8**; תלוי ב-C3. לתעד אי-עקביויות/מגבלות ידועות רלוונטיות לקוד שנכלל |
| C8A | `chore(deploy): add idempotent deployment, systemd units, and hardening` | `deploy.sh`, `deploy-lib.sh`, `deploy-uninstall.sh`, `conf/approval-manager.conf.example`, `config/usbguard-approval-manager.conf.example`, `logrotate/usbguard-approval-manager`, `sudoers/usbguard-approval-manager`, `systemd/usbguard-approval-manager-reaper.service`, `systemd/usbguard-approval-manager-reaper.timer`, `systemd/usbguard-approval-ttl.service`, `systemd/usbguard-approval-ttl.timer` | תלוי ב-C4/C9a; לכלול `conf/` ו-`config/` examples |
| C8B (אם מאושר) | `chore(deploy): add root install and system deployment assets` | `install-usbguard-approval-manager.sh`, `etc/usbguard-approval-manager/approval-manager.conf.example`, root `logrotate/sudoers/systemd/*` לפי החלטה | רק אם נדרש לפי grep/שימוש; אם נכלל installer כמות שהוא — לתעד פערים מול SRS ב-C8C/הערת קומיט מאושרת |
| **C8C (אם מאושר)** | `docs: add from-scratch installation guide` | `usbguard-approval-manager/INSTALL-FROM-SCRATCH.md` | קובץ חדש — דורש אישור מפורש; אחרי C8A/C8B ולפני C9b |
| **C9b** | `test(qa): add integration suite` | `tests/integration/run_integration_tests.sh`, `test_T01.sh`–`test_T28.sh` (28, כולל `test_T03_revoke_and_cleanup.sh`) | G-01 integration לא נכלל אם שויך ל-C4 |
| C10 (אם מאושר) | `chore: add local development and testing helper scripts` | `ssh_connect.py`, `vm_client.py` (ללא `audit_write_original.py` — מומלץ להחרגה; ללא `__pycache__`) | כלי עזר מקומיים |
| Cx (אם מאושר) | `chore: add root compatibility layout` | `scripts/lib/.gitkeep`, `scripts/lib/config-reader.sh` | רק אם נדרש תאימות נתיבים |

`[*]` מקור מ-`docs/hebrew-comments` tip לאחר אימות diff.

### מדיניות כשלי תחביר/בדיקה
- הרצה: `python -m py_compile` על `.py` שנוספו, `bash -n` על `.sh` שנוספו (best-effort).
- **תלות בין-שלבית צפויה:** מותר לסווג כך רק עם ציטוט שורת `source`/`import` והקובץ החסר והסבר לשלב; המשך רק באישור נקודתי.
- **שגיאה אמיתית:** עצירה ודיווח.

## 8. הליך ביצוע (לאחר אישור)

1. **שלב A (קריאה בלבד):** `git status` נקי; תיעוד refs/גיבויים; diff של 4 הקבצים המתועדים; `grep` פריסה לפני C8.
2. **שלב B:** `git worktree add --detach ..\rebuild-wt <base>` → `git switch --orphan rebuild` → `git rm -rf --cached .` → קומיט init (אם מאושר) ודיווח.
3. **שלב C:** ביצוע קומיטים לפי הטבלה, עם עצירה ואישור לפני כל קומיט.
4. **אימות סיום:** `git log --oneline --graph`; סריקת קבצים אסורים בהיסטוריה; בדיקות זמינות/מאושרות; דוח סיכום; `rebuild` נשאר נפרד ללא merge/push.

## 9. מפרט C8C — `INSTALL-FROM-SCRATCH.md` (אם יאושר)

- **נתיב:** `usbguard-approval-manager/INSTALL-FROM-SCRATCH.md`
- **שיוך:** קומיט `docs: add from-scratch installation guide` אחרי C8A/C8B ולפני C9b
- **מסלול מרכזי (A1):** `deploy.sh` + הכנה ידנית (חבילות/`usbadmins`) + אזהרות על `install-usbguard-approval-manager.sh`
- **אזהרות installer (אם קיים/מתועד):** הפעלת timers אוטומטית בניגוד למדיניות G-01, סיכוני הרשאות/אתחול (`/run/lock`, `ttl.json`, `audit.jsonl`, `clock_state.json`), קנוניות config, שלמות scripts (למשל `usbguard-status.sh`), חבילות חסרות/מיותרות, היעדר preflight/rollback
- **מבנה מוצע (10 סעיפים):** דרישות מערכת; חבילות (Debian/Ubuntu, RHEL/Fedora); `usbadmins`/משתמשים; קבלת קוד; התקנה (`deploy.sh` staging/live + אזהרת installer); אימות (`validate_all.sh` לפי נתיב/החלטה, מגבלות ידועות); G-01 marker (לאמת נתיב/פורמט בקוד לפני ניסוח סופי); הפעלת timers רק לאחר שערים; בדיקה ראשונית read-only; הסרה (`deploy-uninstall.sh`) ותקלות נפוצות
- **לפני ניסוח סופי:** לאמת נתיב/פורמט G-01 marker בקוד, שלמות scripts במסלולי ההתקנה, ויישור עם החלטות N2/C/A1.

## 10. צ’קליסט החלטות לאישור (חובה לפני שלב A)

| # | החלטה | ברירת מחדל מוצעת | אישור |
|---|---|---|---|
| N1 | סדר C9 | `C9a` לפני `C8`, `C9b` בסוף | ⏳ |
| N2 | מיקום `validate_all.sh` | לשמר `usbguard-approval-manager/scripts/validate_all.sh` + לתעד אי-עקביות (`deploy.sh`/`Makefile`/מסלולים) | ⏳ |
| N3 | מגבלות ולידציית גיבוי/`validate-backup` | לא לתקן ב-rebuild; לתעד לפי מצב הקוד בבסיס המאושר | ⏳ |
| N4 | קומיט אתחול orphan + `.gitignore` שורש | לכלול `.venv/`, `__pycache__/`, `*.pyc`, `.pytest_cache/`, `.ruff_cache/`, `.benchmarks/`, `*.log` (ולהתאים אם הבסיס כבר כולל `.gitignore`) | ⏳ |
| D1 | כפילויות קנוניות | C8A ברירת מחדל; C8B/Cx רק אם נדרש לאחר `grep` פריסה | ⏳ |
| D2 | מקור 4 קבצים מתועדים | `docs/hebrew-comments` tip + diff מול `56fded1` לפני C2/C6 | ⏳ |
| D3 | C0 | `usbguard-approval-manager/.gitignore`, `README.md`, `Makefile` בלבד | ⏳ |
| D4 | שיוך G-01 | `test_g01_adapter.sh`, `collect_g01_readonly_preflight.sh` ב-C4 בלבד | ⏳ |
| D5 | C8 | C8A כולל `conf/`+`config/`; C8B לפי ממצאים | ⏳ |
| D6 | C10 | לכלול `ssh_connect.py`, `vm_client.py`; להחריג `audit_write_original.py` | ⏳ |
| D7 | Cx | לכלול/להחריג לפי צורך תאימות | ⏳ |
| D8 | חריגי תחביר בין-שלביים | תלות מותרת רק עם ציטוט `source/import`+קובץ חסר ואישור נקודתי | ⏳ |
| D9 | גורל `rebuild` | ענף נפרד/ארכיון, ללא merge/push עד אישור נפרד | ⏳ |
| D10 | גורל `docs/hebrew-comments` | ללא שינוי/merge/מחיקה | ⏳ |
| D11 | `__pycache__`/ארטיפקטים | החרגה מלאה מ-rebuild | ⏳ |
| A1 | מסלול התקנה בתיעוד | `deploy.sh` מרכזי; installer מתועד כאזהרה/לא מומלץ במצבו הנוכחי | ⏳ |
| B | תיקון installer ב-rebuild | לא לתקן (אלא אם חריג מאושר); לתעד פערים | ⏳ |
| C | עקביות `validate_all.sh` | לשמר מיקום `scripts/` ולתעד פערי קריאה/שימוש | ⏳ |
| D12 | `INSTALL-FROM-SCRATCH.md` / C8C | ליצור קובץ חדש ב-`usbguard-approval-manager/INSTALL-FROM-SCRATCH.md` כ-C8C (אישור מפורש) | ⏳ |

---

## נספח א׳ — `DOCS/` ל-C1 (52 קבצים)

`DOCS/foundation/01-repo-srs-inspection.md`, `DOCS/foundation/02-implementation-plan.md`, `DOCS/foundation/03-plan-review.md`, `DOCS/foundation/04-env-verification.md`, `DOCS/foundation/05-project-skeleton.md`, `DOCS/foundation/06-config-parser.md`, `DOCS/foundation/07-error-result-model.md`, `DOCS/phases/08-logging-audit.md`, `DOCS/phases/09-locking-concurrency.md`, `DOCS/phases/10-atomic-write.md`, `DOCS/phases/11-parsing-validation.md`, `DOCS/phases/12-time-ttl-clock.md`, `DOCS/phases/13-usbguard-adapter-readonly.md`, `DOCS/phases/14-lab-preparation.md`, `DOCS/phases/15-g01-part1.md`, `DOCS/phases/16-g01-part2.md`, `DOCS/phases/17-ttl-data-model.md`, `DOCS/phases/18-reconciliation-readonly.md`, `DOCS/phases/19-temporary-approval.md`, `DOCS/phases/20-permanent-approval.md`, `DOCS/phases/21-reaper-expiry.md`, `DOCS/phases/22-recovery.md`, `DOCS/phases/23-cli.md`, `DOCS/phases/24-tui-whiptail.md`, `DOCS/phases/25-batch-operations.md`, `DOCS/phases/26-backup-restore.md`, `DOCS/phases/27-json-import-export.md`, `DOCS/phases/28-systemd-deployment.md`, `DOCS/phases/29-deployment-scripts.md`, `DOCS/phases/30-health-validation.md`, `DOCS/phases/31-security-review.md`, `DOCS/phases/32-fix-security-findings.md`, `DOCS/phases/33-release-matrix.md`, `DOCS/root-docs/backup-prompts.ps1`, `DOCS/root-docs/data.md`, `DOCS/root-docs/fix-prompt-numbering.ps1`, `DOCS/root-docs/global-working-rules.md`, `DOCS/root-docs/IMPLEMENTATION_ROADMAP.md`, `DOCS/root-docs/learning-prompt.md`, `DOCS/root-docs/README.md`, `DOCS/root-docs/review-prompt.md`, `DOCS/root-docs/stop-conditions.md`, `DOCS/root-docs/TEST_REPORT_PRODUCTION_READINESS.md`, `DOCS/root-docs/USB.md`, `DOCS/usbguard-approval-manager/AGENT-WORKFLOW.md`, `DOCS/usbguard-approval-manager/DEPLOYMENT.md`, `DOCS/usbguard-approval-manager/DOD_REPORT.md`, `DOCS/usbguard-approval-manager/FLOW.md`, `DOCS/usbguard-approval-manager/g01-preflight-report.md`, `DOCS/usbguard-approval-manager/lab-checklist.md`, `DOCS/usbguard-approval-manager/SECURITY_REVIEW.md`, `DOCS/usbguard-approval-manager/TEST-RESULTS.md`.

## נספח ב׳ — אינטגרציה ל-C9b

`usbguard-approval-manager/tests/integration/run_integration_tests.sh`, `usbguard-approval-manager/tests/integration/test_T01.sh`, `usbguard-approval-manager/tests/integration/test_T02.sh`, `usbguard-approval-manager/tests/integration/test_T03_revoke_and_cleanup.sh`, `usbguard-approval-manager/tests/integration/test_T04_backup_restore.sh`, `usbguard-approval-manager/tests/integration/test_T05_clock_and_reboot.sh`, `usbguard-approval-manager/tests/integration/test_T06_phase6.sh`, `usbguard-approval-manager/tests/integration/test_T07_persistence.sh`, `usbguard-approval-manager/tests/integration/test_T08.sh`, `usbguard-approval-manager/tests/integration/test_T09.sh`, `usbguard-approval-manager/tests/integration/test_T10.sh`, `usbguard-approval-manager/tests/integration/test_T11.sh`, `usbguard-approval-manager/tests/integration/test_T12.sh`, `usbguard-approval-manager/tests/integration/test_T13.sh`, `usbguard-approval-manager/tests/integration/test_T14.sh`, `usbguard-approval-manager/tests/integration/test_T15.sh`, `usbguard-approval-manager/tests/integration/test_T16.sh`, `usbguard-approval-manager/tests/integration/test_T17.sh`, `usbguard-approval-manager/tests/integration/test_T18.sh`, `usbguard-approval-manager/tests/integration/test_T19.sh`, `usbguard-approval-manager/tests/integration/test_T20.sh`, `usbguard-approval-manager/tests/integration/test_T21.sh`, `usbguard-approval-manager/tests/integration/test_T22.sh`, `usbguard-approval-manager/tests/integration/test_T23.sh`, `usbguard-approval-manager/tests/integration/test_T24.sh`, `usbguard-approval-manager/tests/integration/test_T25.sh`, `usbguard-approval-manager/tests/integration/test_T26.sh`, `usbguard-approval-manager/tests/integration/test_T27.sh`, `usbguard-approval-manager/tests/integration/test_T28.sh`.

**לא ב-C9b (שיוך ל-C4):** `usbguard-approval-manager/tests/integration/test_g01_adapter.sh`, `usbguard-approval-manager/tests/integration/collect_g01_readonly_preflight.sh`.

## נספח ג׳ — החרגות

- `.venv/`, `.pytest_cache/`, `.ruff_cache/`, `.benchmarks/`
- `**/__pycache__/`, `**/*.pyc` (כולל `__pycache__/vm_client.cpython-313.pyc`)
- `*.log`, סודות, קונפיגורציה מקומית, מטמון
- מומלץ להחרגה מ-C10: `audit_write_original.py`
