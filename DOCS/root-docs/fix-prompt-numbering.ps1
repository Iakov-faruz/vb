<#
.SYNOPSIS
    מתקן את מספור הפרומפטים כך ששם הקובץ יתאים למספר ה-PROMPT הפנימי.
    מוחק כפולים בשלב ג` ומיישר את שמות הקבצים לכל השלבים.
#>

$ErrorActionPreference = "Stop"
$root = "C:\Users\5722y\Downloads\USB\prompts"

Write-Host "=== מתחיל תיקון מספור הפרומפטים ===" -ForegroundColor Cyan

# 1. מוחק קבצים כפולים בשלב ג`
$duplicates = @(
    "$root\phase-c-usbguard-g01\11-time-ttl-clock.md",
    "$root\phase-c-usbguard-g01\12-usbguard-adapter-readonly.md"
)
foreach ($dup in $duplicates) {
    if (Test-Path $dup) {
        Remove-Item $dup -Force
        Write-Host "נמחק כפול: $dup" -ForegroundColor Yellow
    }
}

# 2. מפתח שמות קבצים ישנים לחדשים לפי שלב
$renames = @{
    # שלב א`
    "$root\phase-a-foundation\00-repo-srs-inspection.md" = "$root\phase-a-foundation\01-repo-srs-inspection.md"
    "$root\phase-a-foundation\01-implementation-plan.md" = "$root\phase-a-foundation\02-implementation-plan.md"
    "$root\phase-a-foundation\02-plan-review.md" = "$root\phase-a-foundation\03-plan-review.md"
    "$root\phase-a-foundation\03-env-verification.md" = "$root\phase-a-foundation\04-env-verification.md"
    "$root\phase-a-foundation\02-project-skeleton.md" = "$root\phase-a-foundation\05-project-skeleton.md"
    "$root\phase-a-foundation\03-config-paths-exit-codes.md" = "$root\phase-a-foundation\06-config-paths-exit-codes.md"
    "$root\phase-a-foundation\04-error-result-model.md" = "$root\phase-a-foundation\07-error-result-model.md"
    # שלב ב`
    "$root\phase-b-safe-infrastructure\05-logging-audit.md" = "$root\phase-b-safe-infrastructure\08-logging-audit.md"
    "$root\phase-b-safe-infrastructure\06-locking-concurrency.md" = "$root\phase-b-safe-infrastructure\09-locking-concurrency.md"
    "$root\phase-b-safe-infrastructure\07-atomic-write.md" = "$root\phase-b-safe-infrastructure\10-atomic-write.md"
    "$root\phase-b-safe-infrastructure\08-parsing-validation.md" = "$root\phase-b-safe-infrastructure\11-parsing-validation.md"
    "$root\phase-b-safe-infrastructure\09-time-ttl-clock.md" = "$root\phase-b-safe-infrastructure\12-time-ttl-clock.md"
    "$root\phase-b-safe-infrastructure\10-usbguard-adapter-readonly.md" = "$root\phase-b-safe-infrastructure\13-usbguard-adapter-readonly.md"
    # שלב ג`
    "$root\phase-c-usbguard-g01\12-lab-preparation.md" = "$root\phase-c-usbguard-g01\14-lab-preparation.md"
    "$root\phase-c-usbguard-g01\13-g01-verification.md" = "$root\phase-c-usbguard-g01\15-g01-part1.md"
    "$root\phase-c-usbguard-g01\14-g01-part2.md" = "$root\phase-c-usbguard-g01\16-g01-part2.md"
    # שלב ד`
    "$root\phase-d-approvals\14-ttl-data-model.md" = "$root\phase-d-approvals\17-ttl-data-model.md"
    "$root\phase-d-approvals\15-reconciliation-readonly.md" = "$root\phase-d-approvals\18-reconciliation-readonly.md"
    "$root\phase-d-approvals\16-temporary-approval.md" = "$root\phase-d-approvals\19-temporary-approval.md"
    "$root\phase-d-approvals\17-permanent-approval.md" = "$root\phase-d-approvals\20-permanent-approval.md"
    "$root\phase-d-approvals\18-reaper-expiry.md" = "$root\phase-d-approvals\21-reaper-expiry.md"
    "$root\phase-d-approvals\19-recovery.md" = "$root\phase-d-approvals\22-recovery.md"
    # שלב ה`
    "$root\phase-e-data-deploy\20-cli.md" = "$root\phase-e-data-deploy\23-cli.md"
    "$root\phase-e-data-deploy\21-tui-whiptail.md" = "$root\phase-e-data-deploy\24-tui-whiptail.md"
    "$root\phase-e-data-deploy\22-batch-operations.md" = "$root\phase-e-data-deploy\25-batch-operations.md"
    "$root\phase-e-data-deploy\23-backup-restore.md" = "$root\phase-e-data-deploy\26-backup-restore.md"
    "$root\phase-e-data-deploy\24-json-import-export.md" = "$root\phase-e-data-deploy\27-json-import-export.md"
    # שלב ו`
    "$root\phase-f-release\25-systemd-deployment.md" = "$root\phase-f-release\28-systemd-deployment.md"
    "$root\phase-f-release\26-deployment-scripts.md" = "$root\phase-f-release\29-deployment-scripts.md"
    "$root\phase-f-release\27-health-validation.md" = "$root\phase-f-release\30-health-validation.md"
    "$root\phase-f-release\26-security-review.md" = "$root\phase-f-release\31-security-review.md"
    "$root\phase-f-release\27-fix-security-findings.md" = "$root\phase-f-release\32-fix-security-findings.md"
    "$root\phase-f-release\28-release-matrix.md" = "$root\phase-f-release\33-release-matrix.md"
}

# 3. מבצע את שינוי השמות
foreach ($old in $renames.Keys) {
    $new = $renames[$old]
    if (Test-Path $old) {
        Move-Item -Path $old -Destination $new -Force
        Write-Host "שונה שם: $old -> $new" -ForegroundColor Green
    } else {
        Write-Warning "לא נמצא: $old"
    }
}

Write-Host "=== סיום תיקון מספור ===" -ForegroundColor Cyan