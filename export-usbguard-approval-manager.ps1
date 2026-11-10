param(
    [string]$ProjectPath = (Join-Path $PSScriptRoot 'usbguard-approval-manager'),
    [string]$MainOutput = (Join-Path $PSScriptRoot 'usbguard-approval-manager-all.txt'),
    [string]$TestsOutput = (Join-Path $PSScriptRoot 'usbguard-approval-manager-tests.txt')
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ProjectPath)) {
    throw "Project path not found: $ProjectPath"
}

$ProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path
foreach ($p in @($MainOutput, $TestsOutput)) {
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
}

$excludeDirs = @('.git', '__pycache__', '.pytest_cache', '.ruff_cache', '.venv', 'node_modules')
$binaryExt = @('.pyc','.pyo','.exe','.dll','.so','.bin','.png','.jpg','.jpeg','.gif','.ico','.zip','.gz','.7z','.pdf')

$files = Get-ChildItem -LiteralPath $ProjectPath -Recurse -File | Where-Object {
    $rel = $_.FullName.Substring($ProjectPath.Length).TrimStart('\','/')
    $parts = $rel -split '[\\/]'
    foreach ($p in $parts) { if ($excludeDirs -contains $p) { return $false } }
    return $true
} | Sort-Object FullName

function Get-Rel([string]$full, [string]$root) { $full.Substring($root.Length).TrimStart('\','/') }

$main = New-Object System.Text.StringBuilder
$tests = New-Object System.Text.StringBuilder
$null = $main.AppendLine("EXPORT: $ProjectPath")
$null = $main.AppendLine("Generated: $(Get-Date -Format o)")
$null = $main.AppendLine("Type: project (excluding tests/)")
$null = $main.AppendLine('')
$null = $tests.AppendLine("EXPORT: $ProjectPath")
$null = $tests.AppendLine("Generated: $(Get-Date -Format o)")
$null = $tests.AppendLine("Type: tests only")
$null = $tests.AppendLine('')

$mainCount = 0; $testCount = 0
foreach ($f in $files) {
    $rel = Get-Rel $f.FullName $ProjectPath
    $isTest = $rel -match '^(tests[\\/])'
    $ext = [System.IO.Path]::GetExtension($f.Name).ToLowerInvariant()

    $sb = if ($isTest) { $tests } else { $main }
    $null = $sb.AppendLine(("=" * 80))
    $null = $sb.AppendLine("FILE: $rel")
    $null = $sb.AppendLine("Source: $($f.FullName)")
    $null = $sb.AppendLine("Size: $($f.Length) bytes")
    $null = $sb.AppendLine("Modified: $($f.LastWriteTime.ToString('o'))")
    $null = $sb.AppendLine(("-" * 80))

    if ($binaryExt -contains $ext) {
        $null = $sb.AppendLine("[Skipped binary file: $ext]")
    } else {
        try {
            $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
            $isBinary = $false
            $sampleLen = [Math]::Min(1024, $bytes.Length)
            for ($i = 0; $i -lt $sampleLen; $i++) { if ($bytes[$i] -eq 0) { $isBinary = $true; break } }
            if ($isBinary) {
                $null = $sb.AppendLine("[Skipped binary content]")
            } else {
                $text = [System.IO.File]::ReadAllText($f.FullName)
                $null = $sb.AppendLine($text)
            }
        } catch {
            $null = $sb.AppendLine("[Error reading file: $($_.Exception.Message)]")
        }
    }
    $null = $sb.AppendLine()

    if ($isTest) { $testCount++ } else { $mainCount++ }
}

[System.IO.File]::WriteAllText($MainOutput, $main.ToString(), [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText($TestsOutput, $tests.ToString(), [System.Text.Encoding]::UTF8)
Write-Output "Main: $MainOutput ($mainCount files)"
Write-Output "Tests: $TestsOutput ($testCount files)"
