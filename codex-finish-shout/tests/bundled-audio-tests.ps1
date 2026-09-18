# Codex Finish Shout bundled audio tests. Installs only into a temporary root;
# no notify command, speech engine, media player, or sound output is invoked.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$pluginRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-bundled-audio-tests-' + [Guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($testRoot)

function Assert-Audio {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
    Write-Host ('[PASS] ' + $Message)
}

try {
    Import-Module (Join-Path $pluginRoot 'scripts\CodexFinishShout.psm1') -Force
    Import-Module (Join-Path $pluginRoot 'scripts\CodexFinishShout.Setup.psm1') -Force
    $defaults = Get-CodexFinishDefaultSettings
    Assert-Audio ($defaults.audioFile -ceq 'builtin:soft-chime') 'New settings select a bundled default.'
    foreach ($track in @('soft-chime', 'bright-finish', 'gentle-rise')) {
        $resolved = Resolve-CodexFinishAudioFile -AudioFile ('builtin:' + $track)
        Assert-Audio (Test-CodexFinishAudioFileSupported -AudioFile $resolved) ('Source plugin resolves ' + $track + '.')
        $midi = [IO.File]::ReadAllBytes([IO.Path]::ChangeExtension($resolved, '.mid'))
        Assert-Audio ([Text.Encoding]::ASCII.GetString($midi, 0, 4) -ceq 'MThd') ('MIDI source exists for ' + $track + '.')
    }
    Assert-Audio ($null -eq (Resolve-CodexFinishAudioFile -AudioFile 'builtin:../../escape')) 'Invalid builtin identifiers are rejected.'
    $customPath = Join-Path $testRoot 'custom.mp3'
    Assert-Audio ((Resolve-CodexFinishAudioFile -AudioFile $customPath) -ceq $customPath) 'Missing custom paths remain selected for the existing fallback.'
    Assert-Audio ((Resolve-CodexFinishAudioFile -AudioFile 'custom.mp3' -ConfigPath (Join-Path $testRoot 'settings.json')) -ceq $customPath) 'Relative custom audio remains relative to the configuration.'

    $installRoot = Join-Path $testRoot 'isolated-install'
    $first = Install-CodexFinishShout -TargetRoot $installRoot -SourceDirectory (Join-Path $pluginRoot 'scripts')
    $second = Install-CodexFinishShout -TargetRoot $installRoot -SourceDirectory (Join-Path $pluginRoot 'scripts')
    Assert-Audio ($first.Installed -and $second.Installed) 'Installation with binary assets is idempotent.'
    $runtime = [IO.Path]::GetDirectoryName($first.RuntimeScript)
    foreach ($track in @('soft-chime', 'bright-finish', 'gentle-rise')) {
        foreach ($extension in @('.mid', '.mp3')) {
            $relative = 'assets\music\' + $track + $extension
            Assert-Audio (
                (Get-FileHash -LiteralPath (Join-Path $pluginRoot $relative)).Hash -ceq
                (Get-FileHash -LiteralPath (Join-Path $runtime $relative)).Hash
            ) ('Installed bytes match for ' + $track + $extension + '.')
        }
    }
    Import-Module (Join-Path $runtime 'CodexFinishShout.psm1') -Force
    $installedSound = Resolve-CodexFinishAudioFile -AudioFile 'builtin:soft-chime'
    Assert-Audio ($installedSound.StartsWith($runtime + '\', [StringComparison]::OrdinalIgnoreCase)) 'Installed resolver uses assets from its own runtime.'
    Assert-Audio (Test-CodexFinishAudioFileSupported -AudioFile $installedSound) 'Installed default is playable without an external song.'

    $configPath = Join-Path $testRoot 'music-settings.json'
    $configuredOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $runtime 'configure.ps1') SetBuiltinAudio -Sound bright-finish -ConfigPath $configPath
    Assert-Audio ($LASTEXITCODE -eq 0) 'CLI preset selection succeeds without playing audio.'
    $configured = ($configuredOutput -join "`n") | ConvertFrom-Json
    Assert-Audio ($configured.Settings.audioFile -ceq 'builtin:bright-finish' -and $configured.AudioExists) 'CLI reports the selected bundled file exists.'
    $unrelated = Join-Path $runtime 'assets\music\personal-song.mp3'
    [IO.File]::WriteAllText($unrelated, 'user-file')
    $removed = Uninstall-CodexFinishShout -TargetRoot $installRoot
    Assert-Audio ($removed.Removed -and -not [IO.File]::Exists($installedSound)) 'Uninstall removes bundled music.'
    Assert-Audio ([IO.File]::Exists($unrelated)) 'Uninstall preserves unrelated user assets.'
}
finally {
    # Resolve and validate the exact temporary target before recursive cleanup.
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $temporaryParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolvedTestRoot.StartsWith($temporaryParent, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolvedTestRoot) -notlike 'codex-bundled-audio-tests-*') {
        throw 'Temporary cleanup target escaped its expected directory.'
    }
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
}
