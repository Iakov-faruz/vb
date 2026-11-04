<# 
.SYNOPSIS
    מאחד את כל קובצי הפרומפטים מתיקיית prompts לקובץ טקסט אחד לגיבוי או להעתקה.

.DESCRIPTION
    הסקריפט עובר רקורסיבית על תיקיית prompts וקורא את כל קובצי ה-markdown,
    ומכניס אותם לקובץ טקסט אחד עם הפרדה ברורה בין הקבצים.
    שימושי לגיבוי מהיר או להעברת כל הפרומפטים לסוכן בקובץ אחד.

.PARAMETER SourceDir
    נתיב לתיקיית המקור שמכילה את הפרומפטים (ברירת מחדל: ./prompts)

.PARAMETER OutputFile
    נתיב לקובץ הפלט שיווצר (ברירת מחדל: ./prompts-backup.txt)

.EXAMPLE
    .\backup-prompts.ps1
    # יוצר קובץ prompts-backup.txt עם כל תוכן תיקיית prompts

.EXAMPLE
    .\backup-prompts.ps1 -SourceDir "C:\path\to\prompts" -OutputFile "all-prompts.txt"

.NOTES
    רץ על PowerShell (Windows). תומך בקידוד UTF-8.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$SourceDir = "$PSScriptRoot\prompts",

    [Parameter(Mandatory = $false)]
    [string]$OutputFile = "$PSScriptRoot\prompts-backup.txt"
)

# בדיקה שתיקיית המקור קיימת
if (-not (Test-Path -Path $SourceDir)) {
    Write-Error "תיקיית המקור לא נמצאה: $SourceDir"
    exit 1
}

# איסוף כל קובצי ה-markdown בתיקייה (רקורסיבי), מסודר לפי נתיב
$files = Get-ChildItem -Path $SourceDir -Recurse -Filter "*.md" | 
    Sort-Object -Property FullName

if ($files.Count -eq 0) {
    Write-Warning "לא נמצאו קובצי markdown בתיקייה: $SourceDir"
    exit 0
}

# יצירת תוכן הקובץ
$header = @"
================================================================================
  גיבוי פרומפטים - USBGuard Approval Manager
  תאריך: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
  תיקיית מקור: $SourceDir
  מספר קבצים: $($files.Count)
================================================================================

"@

$content = New-Object System.Text.StringBuilder
$content.AppendLine($header) | Out-Null

foreach ($file in $files) {
    $relativePath = $file.FullName.Substring($SourceDir.Length).TrimStart("\")
    
    $content.AppendLine("") | Out-Null
    $content.AppendLine("================================================================================") | Out-Null
    $content.AppendLine(" קובץ: $relativePath") | Out-Null
    $content.AppendLine(" גודל: $($file.Length) בתים") | Out-Null
    $content.AppendLine("--------------------------------------------------------------------------------") | Out-Null
    
    try {
        $fileContent = Get-Content -Path $file.FullName -Raw -ErrorAction Stop
        $content.AppendLine($fileContent) | Out-Null
    } catch {
        $content.AppendLine("[שגיאה בקריאת הקובץ: $($_.Exception.Message)]") | Out-Null
    }
    
    $content.AppendLine("") | Out-Null
    $content.AppendLine("================================================================================") | Out-Null
    $content.AppendLine(" סוף קובץ: $relativePath") | Out-Null
    $content.AppendLine("================================================================================") | Out-Null
}

$content.AppendLine("") | Out-Null
$content.AppendLine("================================================================================") | Out-Null
$content.AppendLine(" סיום גיבוי - $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")") | Out-Null
$content.AppendLine("================================================================================") | Out-Null

# כתיבה לקובץ הפלט עם קידוד UTF-8
try {
    $content.ToString() | Out-File -FilePath $OutputFile -Encoding utf8 -ErrorAction Stop
    Write-Host "התקבל בהצלחה: $OutputFile" -ForegroundColor Green
    Write-Host "מספר קבצים שנגבו: $($files.Count)" -ForegroundColor Cyan
} catch {
    Write-Error "שגיאה בכתיבת קובץ הפלט: $($_.Exception.Message)"
    exit 1
}