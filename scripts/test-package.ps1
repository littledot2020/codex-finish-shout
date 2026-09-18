# Test the actual VSIX in an isolated directory, never the user's Codex home.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$manifest = [IO.File]::ReadAllText((Join-Path $repoRoot 'codex-finish-shout-controls\package.json')) | ConvertFrom-Json
$package = Join-Path $repoRoot ('dist\' + $manifest.name + '-' + $manifest.version + '-win32-x64.vsix')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-package-' + [Guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($testRoot)
$extracted = Join-Path $testRoot 'extracted'
$target = Join-Path $testRoot 'user profile with spaces'
function Assert-Package([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
    Write-Output ('[PASS] ' + $Message)
}
try {
    [IO.Compression.ZipFile]::ExtractToDirectory($package, $extracted)
    $extension = Join-Path $extracted 'extension'
    $bridge = Join-Path $extension 'backend\scripts\extension-manage.ps1'
    foreach ($relative in @('backend\scripts\CodexFinishShout.psm1', 'backend\scripts\play-audio.ps1', 'backend\config\default-settings.json', 'assets\icon.png')) {
        Assert-Package ([IO.File]::Exists((Join-Path $extension $relative))) ('Packaged resource: ' + $relative)
    }
    $readme = [IO.File]::ReadAllText((Join-Path $extension 'README.md'))
    Assert-Package ($readme.Contains('## English') -and $readme.Contains('www.toolai.io') -and $readme.Contains([string][char]0x4E2D)) 'Marketplace README has English, Chinese and ToolAI'
    $installedText = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $bridge -Action Install -TargetRoot $target
    Assert-Package ($LASTEXITCODE -eq 0) 'Extracted package initializes without source repository'
    $installed = $installedText | ConvertFrom-Json
    Assert-Package $installed.Installed 'Initialization returns installed status'
    $status = (& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $bridge -Action Status -TargetRoot $target) | ConvertFrom-Json
    Assert-Package ($status.ConfigurationReady -and $status.AudioExists -and $status.AuthorizationPending) 'Configuration and bundled audio ready; trust is still required'
    $preferencesPath = Join-Path $target 'codex-finish-shout.json'
    $preferences = [IO.File]::ReadAllText($preferencesPath) | ConvertFrom-Json
    Assert-Package (-not $preferences.hardware.enabled) 'Hardware is opt-in'
    $preferences.volume = 37
    $preferences.audioFile = 'C:\Personal Music\my-song.mp3'
    [IO.File]::WriteAllText($preferencesPath, ($preferences | ConvertTo-Json -Depth 20))
    $before = [IO.File]::ReadAllBytes($preferencesPath)
    $null = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $bridge -Action Install -TargetRoot $target
    Assert-Package ($LASTEXITCODE -eq 0) 'Reinstall succeeds'
    Assert-Package ([Convert]::ToBase64String($before) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($preferencesPath))) 'Upgrade preserves personal music and preferences byte-for-byte'
    $tracks = [IO.File]::ReadAllText((Join-Path $extension 'backend\assets\music\catalog.json')) | ConvertFrom-Json
    foreach ($track in $tracks) {
        $audio = Join-Path $target ('codex-finish-shout\assets\music\' + $track.mp3)
        Assert-Package ([IO.File]::Exists($audio) -and ([IO.FileInfo]$audio).Length -gt 20000) ('Installed music: ' + $track.id)
    }
    $null = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $bridge -Action Uninstall -TargetRoot $target
    Assert-Package ($LASTEXITCODE -eq 0 -and [IO.File]::Exists($preferencesPath) -and -not [IO.File]::Exists($installed.RuntimeScript)) 'Uninstall removes runtime and retains preferences'

    # Validate transactional runtime restoration after a failure late in install.
    Import-Module (Join-Path $extension 'backend\scripts\CodexFinishShout.Setup.psm1') -Force
    $rollbackRoot = Join-Path $testRoot 'rollback'
    $source = Join-Path $extension 'backend\scripts'
    $first = Install-CodexFinishShout -TargetRoot $rollbackRoot -SourceDirectory $source
    $runtimeBytes = [IO.File]::ReadAllBytes($first.RuntimeScript)
    $configBytes = [IO.File]::ReadAllBytes($first.ConfigFile)
    [IO.File]::AppendAllText((Join-Path $source 'codex-finish-shout.ps1'), "`n# Test update`n")
    $statePath = Join-Path $rollbackRoot 'codex-finish-shout\install-state.json'
    $lock = [IO.File]::Open($statePath, 'Open', 'Read', 'Read')
    $failed = $false
    try { $null = Install-CodexFinishShout -TargetRoot $rollbackRoot -SourceDirectory $source }
    catch { $failed = $true }
    finally { $lock.Dispose() }
    Assert-Package $failed 'Injected installation failure is reported'
    Assert-Package ([Convert]::ToBase64String($runtimeBytes) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($first.RuntimeScript))) 'Failed upgrade restores previous runtime bytes'
    Assert-Package ([Convert]::ToBase64String($configBytes) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($first.ConfigFile))) 'Failed upgrade retains original configuration'
}
finally {
    # Only remove this test's independently generated temporary directory.
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved).StartsWith('codex-package-')) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
