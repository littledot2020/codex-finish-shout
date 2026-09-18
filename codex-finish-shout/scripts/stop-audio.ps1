# Codex Finish Shout audio stop signal.

[CmdletBinding()]
param(
    [string] $StateDirectory,
    [string] $SessionId,
    [string] $ProjectPath
)

$ErrorActionPreference = 'SilentlyContinue'
$utf8WithoutBom = New-Object Text.UTF8Encoding($false)

try {
    if ([string]::IsNullOrWhiteSpace($StateDirectory)) {
        $userProfilePath = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
        $StateDirectory = Join-Path $userProfilePath '.codex\codex-finish-shout-state'
    }

    $resolvedState = [IO.Path]::GetFullPath($StateDirectory)
    if (-not [IO.Directory]::Exists($resolvedState)) {
        return
    }

    $stateFiles = New-Object Collections.Generic.List[string]
    $legacyStateFile = Join-Path $resolvedState 'audio-player.json'
    if ([IO.File]::Exists($legacyStateFile)) {
        $stateFiles.Add($legacyStateFile)
    }
    foreach ($candidate in [IO.Directory]::EnumerateFiles($resolvedState, 'audio-player-*.json')) {
        $stateFiles.Add($candidate)
    }

    foreach ($stateFile in $stateFiles) {
        try {
            $state = [IO.File]::ReadAllText($stateFile) | ConvertFrom-Json -ErrorAction Stop
            $currentSessionId = [string]$state.sessionId
            if ([string]::IsNullOrWhiteSpace($currentSessionId)) {
                continue
            }
            if ($currentSessionId -notmatch '^[A-Za-z0-9_-]{1,128}$') {
                continue
            }
            if (
                -not [string]::IsNullOrWhiteSpace($SessionId) -and
                $currentSessionId -cne $SessionId
            ) {
                continue
            }
            if (-not [string]::IsNullOrWhiteSpace($ProjectPath)) {
                $currentProjectPath = [string]$state.projectPath
                if (
                    [string]::IsNullOrWhiteSpace($currentProjectPath) -or
                    -not $currentProjectPath.Equals($ProjectPath, [StringComparison]::OrdinalIgnoreCase)
                ) {
                    continue
                }
            }

            $signalPath = Join-Path $resolvedState ('audio-stop-' + $currentSessionId + '.signal')
            $signal = [ordered] @{
                sessionId     = $currentSessionId
                requestedUtc  = [DateTime]::UtcNow.ToString('o')
                requestedBy   = 'Codex Finish Shout Controls'
            }
            [IO.File]::WriteAllText(
                $signalPath,
                (($signal | ConvertTo-Json -Depth 3) + [Environment]::NewLine),
                $utf8WithoutBom
            )
        }
        catch {
            # A partially written or stale state file must not block other sessions.
        }
    }
}
catch {
    # Stop requests are best effort and must never surface an error in VS Code.
}
