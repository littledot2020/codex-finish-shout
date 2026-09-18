[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$sourcePath = Join-Path $projectRoot 'main\main.c'
$readmePath = Join-Path $projectRoot 'README.md'
$source = [IO.File]::ReadAllText($sourcePath)
$readme = [IO.File]::ReadAllText($readmePath)

function Assert-Match {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Text,
        [Parameter(Mandatory = $true)]
        [string] $Pattern,
        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    if (-not [regex]::IsMatch($Text, $Pattern, [Text.RegularExpressions.RegexOptions]::Singleline)) {
        throw $Message
    }
}

function Get-SourceSection {
    param(
        [Parameter(Mandatory = $true)]
        [string] $StartMarker,
        [Parameter(Mandatory = $true)]
        [string] $EndMarker
    )

    $start = $source.IndexOf($StartMarker, [StringComparison]::Ordinal)
    $end = $source.IndexOf($EndMarker, $start + $StartMarker.Length, [StringComparison]::Ordinal)
    if ($start -lt 0 -or $end -le $start) {
        throw "Could not locate source section: $StartMarker"
    }
    return $source.Substring($start, $end - $start)
}

Assert-Match $source '#define\s+PROJECT_SNAPSHOT_TIMEOUT_SECONDS\s+90\b' `
    'Snapshot watchdog timeout must remain 90 seconds.'
Assert-Match $source '#include\s+"esp_timer\.h"' `
    'Snapshot watchdog must use the ESP monotonic timer.'

$expirySection = Get-SourceSection `
    -StartMarker 'static void expire_stale_project_snapshot(void)' `
    -EndMarker 'static const uint8_t kDigits'
Assert-Match $expirySection 'memset\(&s_projects,\s*0,\s*sizeof\(s_projects\)\)' `
    'Expiry must clear the old project rows.'
Assert-Match $expirySection 's_host_offline\s*=\s*true' `
    'Expiry must enter the explicit host-offline state.'
if ($expirySection -match 's_audio_event|play_tone|audio_task') {
    throw 'Snapshot expiry must not trigger audio.'
}

$snapshotSection = Get-SourceSection `
    -StartMarker 'static void set_project_snapshot(' `
    -EndMarker 'static bool handle_project_snapshot('
Assert-Match $snapshotSection 's_last_project_snapshot_us\s*=\s*received_us' `
    'A valid snapshot must refresh the watchdog timestamp.'
Assert-Match $snapshotSection 's_host_offline\s*=\s*false' `
    'A valid snapshot must recover from host-offline state.'
if ($snapshotSection -match 's_audio_event|play_tone|audio_task') {
    throw 'Receiving a project snapshot must not trigger audio.'
}

$handlerSection = Get-SourceSection `
    -StartMarker 'static bool handle_project_snapshot(' `
    -EndMarker 'static void handle_message('
Assert-Match $handlerSection 'supplied_count\s*>\s*PROJECT_ROW_COUNT' `
    'Snapshot validation must reject oversized project arrays.'
Assert-Match $handlerSection '!cJSON_IsObject\(item\)\)\s*return false' `
    'Malformed project entries must invalidate the whole snapshot.'
Assert-Match $handlerSection 'set_project_snapshot\(projects,\s*count,\s*total\);\s*return true' `
    'The watchdog timestamp must only update after all snapshot validation succeeds.'

$timestampWrites = [regex]::Matches($source, 's_last_project_snapshot_us\s*=').Count
if ($timestampWrites -ne 1) {
    throw "Expected exactly one watchdog timestamp write, found $timestampWrites."
}

Assert-Match $readme '90' 'README must document the 90-second offline timeout.'
Assert-Match $readme 'HOST OFFLINE' 'README must document the board offline display.'

Write-Host 'Snapshot watchdog static checks passed.'
