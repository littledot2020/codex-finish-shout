# Codex Finish Shout installer and configuration management.
# Owns one marked notify block plus six lifecycle handlers. Existing user TOML
# and unrelated Hook groups are preserved, backed up, and restored on failure.

Set-StrictMode -Version 2.0

$script:BeginMarker = '# BEGIN codex-finish-shout (managed by installer)'
$script:EndMarker = '# END codex-finish-shout'
$script:RuntimeDirectoryName = 'codex-finish-shout'
$script:SettingsFileName = 'codex-finish-shout.json'
$script:StateDirectoryName = 'codex-finish-shout-state'
$script:LegacyHookDescription = 'Codex Finish Shout user-level Stop hook'
$script:LifecycleHookDescription = 'Codex Finish Shout lifecycle state guard'
$script:LifecycleHookScriptName = 'codex-finish-shout-hook.ps1'
$script:LifecycleHookDefinitionId = 'lifecycle-v2'
$script:LifecycleHookEvents = @(
    'SessionStart',
    'UserPromptSubmit',
    'SubagentStart',
    'SubagentStop',
    'Stop',
    'SessionEnd'
)
$script:RuntimeFileNames = @(
    'codex-finish-shout.ps1',
    $script:LifecycleHookScriptName,
    'CodexFinishShout.psm1',
    'CodexFinishShout.Setup.psm1',
    'configure.ps1',
    'default-settings.json',
    'install.ps1',
    'manage.ps1',
    'monitor-sync-worker.ps1',
    'play-audio.ps1',
    'show-completion-overlay.ps1',
    'stop-audio.ps1',
    'uninstall.ps1',
    'assets\music\soft-chime.mp3',
    'assets\music\soft-chime.mid',
    'assets\music\bright-finish.mp3',
    'assets\music\bright-finish.mid',
    'assets\music\gentle-rise.mp3',
    'assets\music\gentle-rise.mid',
    'assets\music\catalog.json',
    'assets\music\LICENSE.txt'
)

function Get-CodexFinishProperty {
    param(
        [object] $InputObject,
        [Parameter(Mandatory = $true)]
        [string] $Name,
        [object] $DefaultValue = $null
    )

    if ($null -eq $InputObject) {
        return $DefaultValue
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $DefaultValue
    }

    return $property.Value
}

function Set-CodexFinishProperty {
    param(
        [Parameter(Mandatory = $true)]
        [object] $InputObject,
        [Parameter(Mandatory = $true)]
        [string] $Name,
        [object] $Value
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        Add-Member -InputObject $InputObject -MemberType NoteProperty -Name $Name -Value $Value
    }
    else {
        $property.Value = $Value
    }
}

function Get-CodexFinishTargetRoot {
    param(
        [string] $TargetRoot
    )

    if ([string]::IsNullOrWhiteSpace($TargetRoot)) {
        $userProfilePath = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
        if ([string]::IsNullOrWhiteSpace($userProfilePath)) {
            throw 'Unable to resolve the current user profile.'
        }
        $TargetRoot = Join-Path $userProfilePath '.codex'
    }

    return [IO.Path]::GetFullPath($TargetRoot)
}

function Get-CodexFinishLayout {
    param(
        [string] $TargetRoot
    )

    $root = Get-CodexFinishTargetRoot -TargetRoot $TargetRoot
    $runtimeDirectory = Join-Path $root $script:RuntimeDirectoryName

    return [pscustomobject] [ordered] @{
        Root                = $root
        ConfigFile          = Join-Path $root 'config.toml'
        HooksFile           = Join-Path $root 'hooks.json'
        LegacyRuntimeScript = Join-Path $root 'hooks\codex-shout.ps1'
        RuntimeDirectory    = $runtimeDirectory
        RuntimeScript       = Join-Path $runtimeDirectory 'codex-finish-shout.ps1'
        RuntimeHookScript   = Join-Path $runtimeDirectory $script:LifecycleHookScriptName
        RuntimeModule       = Join-Path $runtimeDirectory 'CodexFinishShout.psm1'
        InstallState        = Join-Path $runtimeDirectory 'install-state.json'
        SettingsFile        = Join-Path $root $script:SettingsFileName
        StateDirectory      = Join-Path $root $script:StateDirectoryName
        HookReadyMarker     = Join-Path (Join-Path $root $script:StateDirectoryName) 'lifecycle-hook-ready.json'
        BackupsDirectory    = Join-Path $root 'backups\codex-finish-shout-notify'
    }
}

function Write-CodexFinishUtf8File {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Content
    )

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $parentPath = [IO.Path]::GetDirectoryName($resolvedPath)
    $null = [IO.Directory]::CreateDirectory($parentPath)
    $temporaryPath = $resolvedPath + '.tmp.' + [Guid]::NewGuid().ToString('N')
    $replacementBackup = $resolvedPath + '.replace.' + [Guid]::NewGuid().ToString('N')
    $utf8WithoutBom = New-Object Text.UTF8Encoding($false)

    try {
        [IO.File]::WriteAllText($temporaryPath, $Content, $utf8WithoutBom)
        if ([IO.File]::Exists($resolvedPath)) {
            [IO.File]::Replace($temporaryPath, $resolvedPath, $replacementBackup, $true)
            if ([IO.File]::Exists($replacementBackup)) {
                [IO.File]::Delete($replacementBackup)
            }
        }
        else {
            [IO.File]::Move($temporaryPath, $resolvedPath)
        }
    }
    finally {
        if ([IO.File]::Exists($temporaryPath)) {
            [IO.File]::Delete($temporaryPath)
        }
        if ([IO.File]::Exists($replacementBackup)) {
            [IO.File]::Delete($replacementBackup)
        }
    }
}

function ConvertTo-CodexFinishTomlString {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Value
    )

    $escaped = $Value.Replace('\', '\\').Replace('"', '\"')
    $escaped = $escaped.Replace("`b", '\b').Replace("`t", '\t')
    $escaped = $escaped.Replace("`n", '\n').Replace("`f", '\f').Replace("`r", '\r')
    return '"' + $escaped + '"'
}

function New-CodexFinishNotifyBlock {
    param(
        [Parameter(Mandatory = $true)]
        [string] $RuntimeScript,
        [string] $StateDirectory
    )

    $arguments = @(
        'powershell.exe',
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        [IO.Path]::GetFullPath($RuntimeScript)
    )
    if (-not [string]::IsNullOrWhiteSpace($StateDirectory)) {
        $arguments += @(
            '-StateDirectory',
            [IO.Path]::GetFullPath($StateDirectory)
        )
    }

    $lines = New-Object Collections.Generic.List[string]
    $lines.Add($script:BeginMarker)
    $lines.Add('notify = [')
    foreach ($argument in $arguments) {
        $lines.Add('  ' + (ConvertTo-CodexFinishTomlString -Value $argument) + ',')
    }
    $lines.Add(']')
    $lines.Add($script:EndMarker)
    return ($lines.ToArray() -join [Environment]::NewLine)
}

function Get-CodexFinishTomlStatementEnd {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Lines,
        [Parameter(Mandatory = $true)]
        [int] $StartIndex
    )

    $depth = 0
    $arraySeen = $false

    for ($lineIndex = $StartIndex; $lineIndex -lt $Lines.Count; $lineIndex++) {
        $line = [string] $Lines[$lineIndex]
        $characterIndex = 0
        if ($lineIndex -eq $StartIndex) {
            $equalsIndex = $line.IndexOf('=')
            if ($equalsIndex -lt 0) {
                throw 'Invalid top-level notify assignment.'
            }
            $characterIndex = $equalsIndex + 1
        }

        $inBasicString = $false
        $inLiteralString = $false
        $escaped = $false
        $valueCharacterSeen = $false

        for (; $characterIndex -lt $line.Length; $characterIndex++) {
            $character = $line[$characterIndex]

            if ($inBasicString) {
                if ($escaped) {
                    $escaped = $false
                    continue
                }
                if ($character -eq '\') {
                    $escaped = $true
                    continue
                }
                if ($character -eq '"') {
                    $inBasicString = $false
                }
                continue
            }

            if ($inLiteralString) {
                if ($character -eq "'") {
                    $inLiteralString = $false
                }
                continue
            }

            if ($character -eq '#') {
                break
            }
            if ($character -eq '"') {
                $inBasicString = $true
                $valueCharacterSeen = $true
                continue
            }
            if ($character -eq "'") {
                $inLiteralString = $true
                $valueCharacterSeen = $true
                continue
            }
            if ($character -eq '[') {
                $arraySeen = $true
                $depth++
                $valueCharacterSeen = $true
                continue
            }
            if ($character -eq ']') {
                $depth--
                $valueCharacterSeen = $true
                if ($arraySeen -and $depth -eq 0) {
                    return $lineIndex
                }
                continue
            }
            if (-not [char]::IsWhiteSpace($character)) {
                $valueCharacterSeen = $true
            }
        }

        if (-not $arraySeen -and $valueCharacterSeen) {
            return $lineIndex
        }
    }

    throw 'The top-level notify assignment is not terminated.'
}

function Get-CodexFinishNotifyRange {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Lines
    )

    $beginIndex = -1
    for ($index = 0; $index -lt $Lines.Count; $index++) {
        if ([string]$Lines[$index] -ceq $script:BeginMarker) {
            if ($beginIndex -ge 0) {
                throw 'Multiple managed Codex Finish Shout notify blocks were found.'
            }
            $beginIndex = $index
        }
    }

    if ($beginIndex -ge 0) {
        for ($index = $beginIndex + 1; $index -lt $Lines.Count; $index++) {
            if ([string]$Lines[$index] -ceq $script:EndMarker) {
                return [pscustomobject] @{
                    Kind  = 'Managed'
                    Start = $beginIndex
                    End   = $index
                }
            }
        }
        throw 'The managed Codex Finish Shout notify block is missing its end marker.'
    }

    $firstTable = $Lines.Count
    for ($index = 0; $index -lt $Lines.Count; $index++) {
        if ([regex]::IsMatch([string]$Lines[$index], '^\s*\[')) {
            $firstTable = $index
            break
        }
    }

    for ($index = 0; $index -lt $firstTable; $index++) {
        if ([regex]::IsMatch(
            [string]$Lines[$index],
            '^\s*(?:notify|"notify"|''notify'')\s*=',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant
        )) {
            return [pscustomobject] @{
                Kind  = 'Unmanaged'
                Start = $index
                End   = Get-CodexFinishTomlStatementEnd -Lines $Lines -StartIndex $index
            }
        }
    }

    return $null
}

function ConvertTo-CodexFinishLineArray {
    param(
        [AllowEmptyString()]
        [string] $Content
    )

    if ([string]::IsNullOrEmpty($Content)) {
        return [string[]] @()
    }
    return [string[]] [regex]::Split($Content, '\r\n|\n')
}

function Merge-CodexFinishTopLevelBlock {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Lines,
        [AllowEmptyString()]
        [string] $Block
    )

    $working = New-Object Collections.Generic.List[string]
    foreach ($line in $Lines) {
        $working.Add([string]$line)
    }
    while ($working.Count -gt 0 -and [string]::IsNullOrWhiteSpace($working[$working.Count - 1])) {
        $working.RemoveAt($working.Count - 1)
    }

    $firstTable = $working.Count
    for ($index = 0; $index -lt $working.Count; $index++) {
        if ([regex]::IsMatch([string]$working[$index], '^\s*\[')) {
            $firstTable = $index
            break
        }
    }

    $before = New-Object Collections.Generic.List[string]
    for ($index = 0; $index -lt $firstTable; $index++) {
        $before.Add($working[$index])
    }
    while ($before.Count -gt 0 -and [string]::IsNullOrWhiteSpace($before[$before.Count - 1])) {
        $before.RemoveAt($before.Count - 1)
    }

    $after = New-Object Collections.Generic.List[string]
    for ($index = $firstTable; $index -lt $working.Count; $index++) {
        $after.Add($working[$index])
    }
    while ($after.Count -gt 0 -and [string]::IsNullOrWhiteSpace($after[0])) {
        $after.RemoveAt(0)
    }

    $result = New-Object Collections.Generic.List[string]
    foreach ($line in $before) {
        $result.Add($line)
    }
    if ($before.Count -gt 0 -and (-not [string]::IsNullOrWhiteSpace($Block) -or $after.Count -gt 0)) {
        $result.Add('')
    }

    if (-not [string]::IsNullOrWhiteSpace($Block)) {
        foreach ($line in (ConvertTo-CodexFinishLineArray -Content $Block)) {
            $result.Add($line)
        }
        if ($after.Count -gt 0) {
            $result.Add('')
        }
    }

    foreach ($line in $after) {
        $result.Add($line)
    }

    if ($result.Count -eq 0) {
        return ''
    }
    return ($result.ToArray() -join [Environment]::NewLine) + [Environment]::NewLine
}

function Set-CodexFinishManagedNotify {
    param(
        [AllowEmptyString()]
        [string] $Content,
        [Parameter(Mandatory = $true)]
        [string] $NotifyBlock,
        [switch] $Force
    )

    $lines = @(ConvertTo-CodexFinishLineArray -Content $Content)
    $range = Get-CodexFinishNotifyRange -Lines $lines
    $previousBlock = $null

    if ($null -ne $range -and $range.Kind -eq 'Unmanaged' -and -not $Force) {
        throw 'A top-level notify setting already exists. Refusing to overwrite it without -Force.'
    }

    $remaining = New-Object Collections.Generic.List[string]
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($null -ne $range -and $index -ge $range.Start -and $index -le $range.End) {
            continue
        }
        $remaining.Add($lines[$index])
    }

    if ($null -ne $range -and $range.Kind -eq 'Unmanaged') {
        $previousLines = New-Object Collections.Generic.List[string]
        for ($index = $range.Start; $index -le $range.End; $index++) {
            $previousLines.Add($lines[$index])
        }
        $previousBlock = $previousLines.ToArray() -join [Environment]::NewLine
    }

    return [pscustomobject] @{
        Content       = Merge-CodexFinishTopLevelBlock -Lines $remaining.ToArray() -Block $NotifyBlock
        PreviousBlock = $previousBlock
        ReplacedKind  = if ($null -eq $range) { 'None' } else { $range.Kind }
    }
}

function Remove-CodexFinishManagedNotify {
    param(
        [AllowEmptyString()]
        [string] $Content,
        [AllowEmptyString()]
        [string] $PreviousBlock,
        [AllowEmptyString()]
        [string] $ExpectedBlock,
        [switch] $Force
    )

    $lines = @(ConvertTo-CodexFinishLineArray -Content $Content)
    $range = Get-CodexFinishNotifyRange -Lines $lines
    if ($null -eq $range -or $range.Kind -ne 'Managed') {
        return [pscustomobject] @{
            Content = $Content
            Changed = $false
        }
    }

    $currentLines = New-Object Collections.Generic.List[string]
    for ($index = $range.Start; $index -le $range.End; $index++) {
        $currentLines.Add($lines[$index])
    }
    $currentBlock = $currentLines.ToArray() -join [Environment]::NewLine
    if (
        -not $Force -and
        -not [string]::IsNullOrWhiteSpace($ExpectedBlock) -and
        $currentBlock.Trim() -cne $ExpectedBlock.Trim()
    ) {
        throw 'The managed notify block was changed after installation. Refusing to overwrite it without -Force.'
    }

    $remaining = New-Object Collections.Generic.List[string]
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($index -ge $range.Start -and $index -le $range.End) {
            continue
        }
        $remaining.Add($lines[$index])
    }

    return [pscustomobject] @{
        Content = Merge-CodexFinishTopLevelBlock -Lines $remaining.ToArray() -Block $PreviousBlock
        Changed = $true
    }
}

function New-CodexFinishBackupDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Layout,
        [string[]] $Paths
    )

    $existing = @($Paths | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and [IO.File]::Exists($_)
    })
    if ($existing.Count -eq 0) {
        return $null
    }

    $name = [DateTime]::Now.ToString('yyyyMMdd-HHmmss-fff') +
        '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $directory = Join-Path $Layout.BackupsDirectory $name
    $null = [IO.Directory]::CreateDirectory($directory)

    foreach ($path in $existing) {
        $fileName = [IO.Path]::GetFileName($path)
        $target = Join-Path $directory $fileName
        if ([IO.File]::Exists($target)) {
            $target = Join-Path $directory (
                [IO.Path]::GetFileNameWithoutExtension($fileName) +
                '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) +
                [IO.Path]::GetExtension($fileName)
            )
        }
        [IO.File]::Copy($path, $target, $false)
    }

    return $directory
}

function Read-CodexFinishInstallState {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if (-not [IO.File]::Exists($Path)) {
        return $null
    }
    try {
        return ([IO.File]::ReadAllText($Path) | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        return $null
    }
}

function Test-CodexFinishOwnedRuntimeFile {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [string] $SourcePath
    )

    if (-not [IO.File]::Exists($Path)) {
        return $true
    }
    if ([IO.Path]::GetFileName($Path) -eq 'default-settings.json') {
        return $true
    }
    if ($Path -match '[\\/]assets[\\/]music[\\/]' -and $SourcePath) {
        # Binary assets have no script ownership header. Only replace an
        # identical bundled asset automatically; modified files need -Force.
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ceq
            (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash
    }

    $reader = $null
    try {
        $reader = New-Object IO.StreamReader($Path)
        $firstLine = $reader.ReadLine()
        return $firstLine -like '# Codex Finish Shout*'
    }
    finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        }
    }
}

function Get-CodexFinishSourceFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string] $SourceDirectory
    )

    $source = [IO.Path]::GetFullPath($SourceDirectory)
    $pluginRoot = [IO.Path]::GetDirectoryName($source)
    $pairs = New-Object Collections.Generic.List[object]

    foreach ($name in $script:RuntimeFileNames) {
        $sourcePath = if ($name -eq 'default-settings.json') {
            Join-Path $pluginRoot 'config\default-settings.json'
        }
        elseif ($name.StartsWith('assets\')) {
            Join-Path $pluginRoot $name
        }
        else {
            Join-Path $source $name
        }
        if (-not [IO.File]::Exists($sourcePath)) {
            throw "Missing runtime source file: $sourcePath"
        }
        $pairs.Add([pscustomobject] @{
            Name   = $name
            Source = [IO.Path]::GetFullPath($sourcePath)
        })
    }

    return $pairs.ToArray()
}

function Get-CodexFinishSourceVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string] $SourceDirectory
    )

    $manifest = Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($SourceDirectory))) '.codex-plugin\plugin.json'
    if (-not [IO.File]::Exists($manifest)) {
        return 'unknown'
    }
    try {
        $document = [IO.File]::ReadAllText($manifest) | ConvertFrom-Json -ErrorAction Stop
        return [string] (Get-CodexFinishProperty -InputObject $document -Name 'version' -DefaultValue 'unknown')
    }
    catch {
        return 'unknown'
    }
}

function Test-CodexFinishOwnedLegacyHandler {
    param(
        [object] $Handler,
        [Parameter(Mandatory = $true)]
        [string] $LegacyRuntimeScript
    )

    if ($null -eq $Handler -or $Handler -isnot [pscustomobject]) {
        return $false
    }

    foreach ($propertyName in @('command', 'commandWindows', 'command_windows')) {
        $command = [string] (Get-CodexFinishProperty -InputObject $Handler -Name $propertyName)
        if (
            -not [string]::IsNullOrWhiteSpace($command) -and
            $command.IndexOf($LegacyRuntimeScript, [StringComparison]::OrdinalIgnoreCase) -ge 0
        ) {
            return $true
        }
    }
    return $false
}

function Remove-CodexFinishLegacyHook {
    param(
        [Parameter(Mandatory = $true)]
        [string] $HooksFile,
        [Parameter(Mandatory = $true)]
        [string] $LegacyRuntimeScript
    )

    if (-not [IO.File]::Exists($HooksFile)) {
        return [pscustomobject] @{
            Changed    = $false
            DeleteFile = $false
            Content    = $null
        }
    }

    $raw = [IO.File]::ReadAllText($HooksFile)
    try {
        $document = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "The existing hooks file is not valid JSON: $HooksFile"
    }
    if ($null -eq $document -or $document -isnot [pscustomobject]) {
        throw "The hooks file root must be a JSON object: $HooksFile"
    }

    $hooks = Get-CodexFinishProperty -InputObject $document -Name 'hooks'
    if ($null -eq $hooks -or $hooks -isnot [pscustomobject]) {
        return [pscustomobject] @{
            Changed    = $false
            DeleteFile = $false
            Content    = $raw
        }
    }

    $stopProperty = $hooks.PSObject.Properties['Stop']
    if ($null -eq $stopProperty) {
        return [pscustomobject] @{
            Changed    = $false
            DeleteFile = $false
            Content    = $raw
        }
    }
    if ($null -eq $stopProperty.Value) {
        throw "The 'hooks.Stop' property must not be null: $HooksFile"
    }

    $changed = $false
    $remainingGroups = New-Object Collections.Generic.List[object]
    foreach ($group in @($stopProperty.Value)) {
        if ($null -eq $group -or $group -isnot [pscustomobject]) {
            throw "Each 'hooks.Stop' entry must be an object: $HooksFile"
        }
        $handlers = Get-CodexFinishProperty -InputObject $group -Name 'hooks'
        if ($null -eq $handlers) {
            throw "Each 'hooks.Stop' entry must contain hooks: $HooksFile"
        }

        $remainingHandlers = New-Object Collections.Generic.List[object]
        foreach ($handler in @($handlers)) {
            if ($null -eq $handler -or $handler -isnot [pscustomobject]) {
                throw "Each Stop hook handler must be an object: $HooksFile"
            }
            if (Test-CodexFinishOwnedLegacyHandler -Handler $handler -LegacyRuntimeScript $LegacyRuntimeScript) {
                $changed = $true
            }
            else {
                $remainingHandlers.Add($handler)
            }
        }
        if ($remainingHandlers.Count -gt 0) {
            Set-CodexFinishProperty -InputObject $group -Name 'hooks' -Value ([object[]]$remainingHandlers.ToArray())
            $remainingGroups.Add($group)
        }
    }

    if (-not $changed) {
        return [pscustomobject] @{
            Changed    = $false
            DeleteFile = $false
            Content    = $raw
        }
    }

    if ($remainingGroups.Count -gt 0) {
        Set-CodexFinishProperty -InputObject $hooks -Name 'Stop' -Value ([object[]]$remainingGroups.ToArray())
    }
    else {
        $hooks.PSObject.Properties.Remove('Stop')
    }

    $deleteFile = @($hooks.PSObject.Properties).Count -eq 0
    foreach ($property in $document.PSObject.Properties) {
        if ($property.Name -eq 'hooks') {
            continue
        }
        if ($property.Name -eq 'description' -and [string]$property.Value -ceq $script:LegacyHookDescription) {
            continue
        }
        $deleteFile = $false
    }

    return [pscustomobject] @{
        Changed    = $true
        DeleteFile = $deleteFile
        Content    = ($document | ConvertTo-Json -Depth 30) + [Environment]::NewLine
    }
}

function ConvertFrom-CodexFinishHooksDocument {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Content,
        [Parameter(Mandatory = $true)]
        [string] $SourceLabel,
        [switch] $CreateIfEmpty
    )

    if ([string]::IsNullOrWhiteSpace($Content)) {
        if (-not $CreateIfEmpty) {
            return $null
        }
        return [pscustomobject] [ordered] @{
            description = $script:LifecycleHookDescription
            hooks       = [pscustomobject] [ordered] @{}
        }
    }

    try {
        $document = $Content | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "The existing hooks file is not valid JSON: $SourceLabel"
    }
    if ($null -eq $document -or $document -isnot [pscustomobject]) {
        throw "The hooks file root must be a JSON object: $SourceLabel"
    }

    return $document
}

function New-CodexFinishLifecycleHookHandler {
    param(
        [Parameter(Mandatory = $true)]
        [string] $RuntimeHookScript,
        [Parameter(Mandatory = $true)]
        [string] $StateDirectory
    )

    $hookScript = [IO.Path]::GetFullPath($RuntimeHookScript)
    $statePath = [IO.Path]::GetFullPath($StateDirectory)
    $command = 'powershell.exe -NoLogo -NoProfile -NonInteractive ' +
        '-ExecutionPolicy Bypass -File "' + $hookScript + '" ' +
        '-StateDirectory "' + $statePath + '" ' +
        '-DefinitionId "' + $script:LifecycleHookDefinitionId + '"'

    # Both fields are intentional. command is required by the Hook schema,
    # while commandWindows makes the Windows command independent of defaults.
    return [pscustomobject] [ordered] @{
        type           = 'command'
        command        = $command
        commandWindows = $command
        timeout        = 3
    }
}

function Test-CodexFinishOwnedLifecycleHandler {
    param(
        [object] $Handler,
        [Parameter(Mandatory = $true)]
        [string] $RuntimeHookScript
    )

    if ($null -eq $Handler -or $Handler -isnot [pscustomobject]) {
        return $false
    }

    $hookScript = [IO.Path]::GetFullPath($RuntimeHookScript)
    foreach ($propertyName in @('command', 'commandWindows', 'command_windows')) {
        $command = [string] (Get-CodexFinishProperty -InputObject $Handler -Name $propertyName)
        if (
            -not [string]::IsNullOrWhiteSpace($command) -and
            $command.IndexOf($hookScript, [StringComparison]::OrdinalIgnoreCase) -ge 0
        ) {
            return $true
        }
    }

    return $false
}

function Remove-CodexFinishOwnedLifecycleEventHandlers {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Hooks,
        [Parameter(Mandatory = $true)]
        [string] $EventName,
        [Parameter(Mandatory = $true)]
        [string] $RuntimeHookScript,
        [Parameter(Mandatory = $true)]
        [string] $SourceLabel
    )

    $eventProperty = $Hooks.PSObject.Properties[$EventName]
    if ($null -eq $eventProperty) {
        return $false
    }
    if ($null -eq $eventProperty.Value) {
        throw "The 'hooks.$EventName' property must not be null: $SourceLabel"
    }

    $changed = $false
    $remainingGroups = New-Object Collections.Generic.List[object]
    foreach ($group in @($eventProperty.Value)) {
        if ($null -eq $group -or $group -isnot [pscustomobject]) {
            throw "Each 'hooks.$EventName' entry must be an object: $SourceLabel"
        }
        $handlers = Get-CodexFinishProperty -InputObject $group -Name 'hooks'
        if ($null -eq $handlers) {
            throw "Each 'hooks.$EventName' entry must contain hooks: $SourceLabel"
        }

        $remainingHandlers = New-Object Collections.Generic.List[object]
        foreach ($handler in @($handlers)) {
            if ($null -eq $handler -or $handler -isnot [pscustomobject]) {
                throw "Each $EventName hook handler must be an object: $SourceLabel"
            }
            if (Test-CodexFinishOwnedLifecycleHandler `
                -Handler $handler `
                -RuntimeHookScript $RuntimeHookScript
            ) {
                $changed = $true
            }
            else {
                $remainingHandlers.Add($handler)
            }
        }

        if ($remainingHandlers.Count -gt 0) {
            Set-CodexFinishProperty `
                -InputObject $group `
                -Name 'hooks' `
                -Value ([object[]]$remainingHandlers.ToArray())
            $remainingGroups.Add($group)
        }
    }

    if ($remainingGroups.Count -gt 0) {
        Set-CodexFinishProperty `
            -InputObject $Hooks `
            -Name $EventName `
            -Value ([object[]]$remainingGroups.ToArray())
    }
    else {
        $Hooks.PSObject.Properties.Remove($EventName)
    }

    return $changed
}

function Set-CodexFinishManagedLifecycleHooks {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Content,
        [Parameter(Mandatory = $true)]
        [string] $RuntimeHookScript,
        [Parameter(Mandatory = $true)]
        [string] $StateDirectory,
        [string] $SourceLabel = 'hooks.json'
    )

    $document = ConvertFrom-CodexFinishHooksDocument `
        -Content $Content `
        -SourceLabel $SourceLabel `
        -CreateIfEmpty
    $hooks = Get-CodexFinishProperty -InputObject $document -Name 'hooks'
    if ($null -eq $hooks) {
        $hooks = [pscustomobject] [ordered] @{}
        Set-CodexFinishProperty -InputObject $document -Name 'hooks' -Value $hooks
    }
    elseif ($hooks -isnot [pscustomobject]) {
        throw "The 'hooks' property must be a JSON object: $SourceLabel"
    }

    # Reinstall replaces every prior owned handler, then appends one canonical
    # group per event. User groups and handlers retain their original order.
    foreach ($eventName in $script:LifecycleHookEvents) {
        $null = Remove-CodexFinishOwnedLifecycleEventHandlers `
            -Hooks $hooks `
            -EventName $eventName `
            -RuntimeHookScript $RuntimeHookScript `
            -SourceLabel $SourceLabel

        $group = if ($eventName -eq 'SessionStart') {
            [pscustomobject] [ordered] @{
                matcher = 'startup|resume|clear|compact'
                hooks   = [object[]] @(
                    New-CodexFinishLifecycleHookHandler `
                        -RuntimeHookScript $RuntimeHookScript `
                        -StateDirectory $StateDirectory
                )
            }
        }
        else {
            [pscustomobject] [ordered] @{
                hooks = [object[]] @(
                    New-CodexFinishLifecycleHookHandler `
                        -RuntimeHookScript $RuntimeHookScript `
                        -StateDirectory $StateDirectory
                )
            }
        }

        $existingGroups = Get-CodexFinishProperty `
            -InputObject $hooks `
            -Name $eventName `
            -DefaultValue ([object[]] @())
        Set-CodexFinishProperty `
            -InputObject $hooks `
            -Name $eventName `
            -Value ([object[]](@($existingGroups) + @($group)))
    }

    $updated = ($document | ConvertTo-Json -Depth 30) + [Environment]::NewLine
    return [pscustomobject] @{
        Changed    = -not $updated.Equals([string]$Content, [StringComparison]::Ordinal)
        DeleteFile = $false
        Content    = $updated
    }
}

function Remove-CodexFinishManagedLifecycleHooks {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Content,
        [Parameter(Mandatory = $true)]
        [string] $RuntimeHookScript,
        [string] $SourceLabel = 'hooks.json'
    )

    $document = ConvertFrom-CodexFinishHooksDocument `
        -Content $Content `
        -SourceLabel $SourceLabel
    if ($null -eq $document) {
        return [pscustomobject] @{
            Changed    = $false
            DeleteFile = $false
            Content    = $Content
        }
    }

    $hooks = Get-CodexFinishProperty -InputObject $document -Name 'hooks'
    if ($null -eq $hooks) {
        return [pscustomobject] @{
            Changed    = $false
            DeleteFile = $false
            Content    = $Content
        }
    }
    if ($hooks -isnot [pscustomobject]) {
        throw "The 'hooks' property must be a JSON object: $SourceLabel"
    }

    $changed = $false
    foreach ($eventName in $script:LifecycleHookEvents) {
        if (Remove-CodexFinishOwnedLifecycleEventHandlers `
            -Hooks $hooks `
            -EventName $eventName `
            -RuntimeHookScript $RuntimeHookScript `
            -SourceLabel $SourceLabel
        ) {
            $changed = $true
        }
    }

    if (-not $changed) {
        return [pscustomobject] @{
            Changed    = $false
            DeleteFile = $false
            Content    = $Content
        }
    }

    $deleteFile = @($hooks.PSObject.Properties).Count -eq 0
    foreach ($property in $document.PSObject.Properties) {
        if ($property.Name -eq 'hooks') {
            continue
        }
        if (
            $property.Name -eq 'description' -and
            [string]$property.Value -ceq $script:LifecycleHookDescription
        ) {
            continue
        }
        $deleteFile = $false
    }

    return [pscustomobject] @{
        Changed    = $true
        DeleteFile = $deleteFile
        Content    = ($document | ConvertTo-Json -Depth 30) + [Environment]::NewLine
    }
}

function Test-CodexFinishManagedLifecycleHooks {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Content,
        [Parameter(Mandatory = $true)]
        [string] $RuntimeHookScript,
        [Parameter(Mandatory = $true)]
        [string] $StateDirectory,
        [string] $SourceLabel = 'hooks.json'
    )

    $document = ConvertFrom-CodexFinishHooksDocument `
        -Content $Content `
        -SourceLabel $SourceLabel
    if ($null -eq $document) {
        return $false
    }
    $hooks = Get-CodexFinishProperty -InputObject $document -Name 'hooks'
    if ($null -eq $hooks) {
        return $false
    }
    if ($hooks -isnot [pscustomobject]) {
        throw "The 'hooks' property must be a JSON object: $SourceLabel"
    }

    $expected = New-CodexFinishLifecycleHookHandler `
        -RuntimeHookScript $RuntimeHookScript `
        -StateDirectory $StateDirectory
    foreach ($eventName in $script:LifecycleHookEvents) {
        $eventProperty = $hooks.PSObject.Properties[$eventName]
        if ($null -eq $eventProperty -or $null -eq $eventProperty.Value) {
            return $false
        }

        $found = $false
        foreach ($group in @($eventProperty.Value)) {
            if ($null -eq $group -or $group -isnot [pscustomobject]) {
                throw "Each 'hooks.$EventName' entry must be an object: $SourceLabel"
            }
            $handlers = Get-CodexFinishProperty -InputObject $group -Name 'hooks'
            if ($null -eq $handlers) {
                throw "Each 'hooks.$EventName' entry must contain hooks: $SourceLabel"
            }
            foreach ($handler in @($handlers)) {
                if ($null -eq $handler -or $handler -isnot [pscustomobject]) {
                    throw "Each $EventName hook handler must be an object: $SourceLabel"
                }
                if (
                    [string](Get-CodexFinishProperty -InputObject $handler -Name 'type') -ceq 'command' -and
                    [string](Get-CodexFinishProperty -InputObject $handler -Name 'command') -ceq $expected.command -and
                    [string](Get-CodexFinishProperty -InputObject $handler -Name 'commandWindows') -ceq $expected.commandWindows -and
                    [int](Get-CodexFinishProperty -InputObject $handler -Name 'timeout' -DefaultValue 0) -eq 3 -and
                    $null -eq $handler.PSObject.Properties['async']
                ) {
                    $found = $true
                }
            }
        }
        if (-not $found) {
            return $false
        }
    }

    return $true
}

function Install-CodexFinishShoutUnlocked {
    [CmdletBinding()]
    param(
        [string] $TargetRoot,
        [string] $SourceDirectory = $PSScriptRoot,
        [switch] $Force
    )

    $layout = Get-CodexFinishLayout -TargetRoot $TargetRoot
    $sources = Get-CodexFinishSourceFiles -SourceDirectory $SourceDirectory
    $notifyBlock = New-CodexFinishNotifyBlock `
        -RuntimeScript $layout.RuntimeScript `
        -StateDirectory $layout.StateDirectory
    $configExisted = [IO.File]::Exists($layout.ConfigFile)
    $configOriginal = if ($configExisted) { [IO.File]::ReadAllText($layout.ConfigFile) } else { '' }
    $hooksExisted = [IO.File]::Exists($layout.HooksFile)
    $hooksOriginal = if ($hooksExisted) { [IO.File]::ReadAllText($layout.HooksFile) } else { $null }
    $previousState = Read-CodexFinishInstallState -Path $layout.InstallState
    $notifyUpdate = Set-CodexFinishManagedNotify `
        -Content $configOriginal `
        -NotifyBlock $notifyBlock `
        -Force:$Force
    $previousNotifyBlock = $notifyUpdate.PreviousBlock
    if ($null -ne $previousState) {
        $savedPrevious = Get-CodexFinishProperty -InputObject $previousState -Name 'previousNotifyBlock'
        if ($null -ne $savedPrevious) {
            $previousNotifyBlock = [string]$savedPrevious
        }
    }
    $legacyHookRemovedPreviously = $null -ne $previousState -and [bool](
        Get-CodexFinishProperty `
            -InputObject $previousState `
            -Name 'legacyHookRemoved' `
            -DefaultValue $false
    )

    $legacyUpdate = Remove-CodexFinishLegacyHook `
        -HooksFile $layout.HooksFile `
        -LegacyRuntimeScript $layout.LegacyRuntimeScript
    $hooksBaseContent = if ($legacyUpdate.Changed) {
        if ($legacyUpdate.DeleteFile) { '' } else { $legacyUpdate.Content }
    }
    else {
        $hooksOriginal
    }
    $lifecycleHookUpdate = Set-CodexFinishManagedLifecycleHooks `
        -Content $hooksBaseContent `
        -RuntimeHookScript $layout.RuntimeHookScript `
        -StateDirectory $layout.StateDirectory `
        -SourceLabel $layout.HooksFile
    $hooksExistedBeforeInstall = $hooksExisted -and -not (
        $legacyUpdate.Changed -and $legacyUpdate.DeleteFile
    )

    $backupPaths = New-Object Collections.Generic.List[string]
    if ($configExisted) {
        $backupPaths.Add($layout.ConfigFile)
    }
    if ($hooksExisted -and ($legacyUpdate.Changed -or $lifecycleHookUpdate.Changed)) {
        $backupPaths.Add($layout.HooksFile)
    }

    foreach ($source in $sources) {
        $target = Join-Path $layout.RuntimeDirectory $source.Name
        if ([IO.File]::Exists($target)) {
            if (-not (Test-CodexFinishOwnedRuntimeFile -Path $target -SourcePath $source.Source) -and -not $Force) {
                throw "Refusing to overwrite an unrecognized runtime file without -Force: $target"
            }
            $backupPaths.Add($target)
        }
    }
    if ([IO.File]::Exists($layout.InstallState)) {
        $backupPaths.Add($layout.InstallState)
    }

    $backupDirectory = New-CodexFinishBackupDirectory `
        -Layout $layout `
        -Paths $backupPaths.ToArray()
    $null = [IO.Directory]::CreateDirectory($layout.RuntimeDirectory)

    # Retain exact bytes for every file touched by installation, including assets.
    # Config rollback alone is insufficient when a runtime update fails midway.
    $originalFiles = @{}
    foreach ($source in $sources) {
        $target = Join-Path $layout.RuntimeDirectory $source.Name
        $originalFiles[$target] = if ([IO.File]::Exists($target)) { [IO.File]::ReadAllBytes($target) } else { $null }
    }
    foreach ($target in @($layout.SettingsFile, $layout.InstallState)) {
        $originalFiles[$target] = if ([IO.File]::Exists($target)) { [IO.File]::ReadAllBytes($target) } else { $null }
    }

    try {
        foreach ($source in $sources) {
            $targetPath = Join-Path $layout.RuntimeDirectory $source.Name
            $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($targetPath))
            [IO.File]::Copy(
                $source.Source,
                $targetPath,
                $true
            )
        }

        if (-not [IO.File]::Exists($layout.SettingsFile)) {
            $defaultSettings = Join-Path $layout.RuntimeDirectory 'default-settings.json'
            [IO.File]::Copy($defaultSettings, $layout.SettingsFile, $false)
        }

        Write-CodexFinishUtf8File -Path $layout.ConfigFile -Content $notifyUpdate.Content

        if ($legacyUpdate.Changed -or $lifecycleHookUpdate.Changed) {
            Write-CodexFinishUtf8File `
                -Path $layout.HooksFile `
                -Content $lifecycleHookUpdate.Content
        }

        $state = [pscustomobject] [ordered] @{
            schemaVersion       = 3
            installedAtUtc      = [DateTime]::UtcNow.ToString('o')
            pluginVersion       = Get-CodexFinishSourceVersion -SourceDirectory $SourceDirectory
            configExistedBefore = if ($null -ne $previousState) {
                [bool](Get-CodexFinishProperty -InputObject $previousState -Name 'configExistedBefore' -DefaultValue $configExisted)
            }
            else {
                $configExisted
            }
            hooksExistedBefore  = if ($null -ne $previousState) {
                [bool](Get-CodexFinishProperty -InputObject $previousState -Name 'hooksExistedBefore' -DefaultValue $hooksExistedBeforeInstall)
            }
            else {
                $hooksExistedBeforeInstall
            }
            previousNotifyBlock = $previousNotifyBlock
            notifyBlock         = $notifyBlock
            runtimeScript       = $layout.RuntimeScript
            lifecycleHookScript = $layout.RuntimeHookScript
            lifecycleHookDefinitionId = $script:LifecycleHookDefinitionId
            lifecycleHookEvents = [string[]]$script:LifecycleHookEvents
            runtimeFiles        = [string[]]$script:RuntimeFileNames
            legacyHookRemoved   = [bool]($legacyUpdate.Changed -or $legacyHookRemovedPreviously)
        }
        Write-CodexFinishUtf8File `
            -Path $layout.InstallState `
            -Content (($state | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
    }
    catch {
        foreach ($target in $originalFiles.Keys) {
            if ($null -ne $originalFiles[$target]) {
                # A late failure can be a sharing violation on an unchanged file.
                # Do not attempt to rewrite that file while restoring other files.
                if ([IO.File]::Exists($target) -and
                    [Convert]::ToBase64String([IO.File]::ReadAllBytes($target)) -ceq
                    [Convert]::ToBase64String([byte[]]$originalFiles[$target])) { continue }
                [IO.File]::WriteAllBytes($target, [byte[]]$originalFiles[$target])
            }
            elseif ([IO.File]::Exists($target)) { [IO.File]::Delete($target) }
        }
        if ($configExisted) {
            Write-CodexFinishUtf8File -Path $layout.ConfigFile -Content $configOriginal
        }
        elseif ([IO.File]::Exists($layout.ConfigFile)) {
            [IO.File]::Delete($layout.ConfigFile)
        }

        if ($hooksExisted) {
            Write-CodexFinishUtf8File -Path $layout.HooksFile -Content $hooksOriginal
        }
        elseif ([IO.File]::Exists($layout.HooksFile)) {
            [IO.File]::Delete($layout.HooksFile)
        }
        throw
    }

    return [pscustomobject] [ordered] @{
        Action            = 'Install'
        Installed         = $true
        TargetRoot        = $layout.Root
        RuntimeScript     = $layout.RuntimeScript
        RuntimeHookScript = $layout.RuntimeHookScript
        HookDefinitionId  = $script:LifecycleHookDefinitionId
        SettingsFile      = $layout.SettingsFile
        StateDirectory    = $layout.StateDirectory
        ConfigFile        = $layout.ConfigFile
        HooksFile         = $layout.HooksFile
        NotifyConfigured  = $true
        HooksConfigured   = $true
        LegacyHookRemoved = [bool]$legacyUpdate.Changed
        BackupDirectory   = $backupDirectory
        ReloadVSCodeOnce  = $true
        RuntimeParameters = 'None'
    }
}

function Set-CodexFinishShoutEnabled {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [bool] $Enabled,
        [string] $TargetRoot
    )

    $layout = Get-CodexFinishLayout -TargetRoot $TargetRoot
    if (-not [IO.File]::Exists($layout.RuntimeModule)) {
        throw 'Codex Finish Shout is not installed.'
    }

    Import-Module $layout.RuntimeModule -Force -ErrorAction Stop
    $settings = Get-CodexFinishSettings -ConfigPath $layout.SettingsFile
    $settings.enabled = $Enabled
    $result = Write-CodexFinishSettings -Settings $settings -ConfigPath $layout.SettingsFile

    return [pscustomobject] @{
        Action     = if ($Enabled) { 'Enable' } else { 'Disable' }
        Changed    = $true
        Enabled    = $Enabled
        Settings   = $result.ConfigPath
        BackupPath = $result.BackupPath
    }
}

function Get-CodexFinishShoutStatus {
    [CmdletBinding()]
    param(
        [string] $TargetRoot
    )

    $layout = Get-CodexFinishLayout -TargetRoot $TargetRoot
    $runtimeInstalled = [IO.File]::Exists($layout.RuntimeScript) -and
        [IO.File]::Exists($layout.RuntimeHookScript) -and
        [IO.File]::Exists($layout.RuntimeModule)
    $notifyConfigured = $false
    $configValid = $true
    $configError = $null

    if ([IO.File]::Exists($layout.ConfigFile)) {
        try {
            $content = [IO.File]::ReadAllText($layout.ConfigFile)
            $range = Get-CodexFinishNotifyRange -Lines @(ConvertTo-CodexFinishLineArray -Content $content)
            if ($null -ne $range -and $range.Kind -eq 'Managed') {
                $tomlPath = ConvertTo-CodexFinishTomlString -Value $layout.RuntimeScript
                $notifyConfigured = $content.IndexOf($tomlPath, [StringComparison]::Ordinal) -ge 0
            }
        }
        catch {
            $configValid = $false
            $configError = $_.Exception.Message
        }
    }

    $enabled = $false
    $audioFile = $null
    $audioExists = $false
    if ($runtimeInstalled) {
        try {
            Import-Module $layout.RuntimeModule -Force -ErrorAction Stop
            $settings = Get-CodexFinishSettings -ConfigPath $layout.SettingsFile
            $enabled = [bool]$settings.enabled
            $audioFile = Resolve-CodexFinishAudioFile `
                -AudioFile $settings.audioFile `
                -ConfigPath $layout.SettingsFile
            $audioExists = Test-CodexFinishAudioFileSupported -AudioFile $audioFile
        }
        catch {
            $configValid = $false
            $configError = $_.Exception.Message
        }
    }

    $hooksConfigured = $false
    $legacyPresent = $false
    if ([IO.File]::Exists($layout.HooksFile)) {
        try {
            $hooksContent = [IO.File]::ReadAllText($layout.HooksFile)
            $hooksConfigured = Test-CodexFinishManagedLifecycleHooks `
                -Content $hooksContent `
                -RuntimeHookScript $layout.RuntimeHookScript `
                -StateDirectory $layout.StateDirectory `
                -SourceLabel $layout.HooksFile
            $legacyPresent = (Remove-CodexFinishLegacyHook `
                -HooksFile $layout.HooksFile `
                -LegacyRuntimeScript $layout.LegacyRuntimeScript).Changed
        }
        catch {
            $configValid = $false
            $configError = $_.Exception.Message
        }
    }

    $hookObserved = $false
    $hookObservedUtc = $null
    if ([IO.File]::Exists($layout.HookReadyMarker)) {
        try {
            $marker = [IO.File]::ReadAllText($layout.HookReadyMarker) | ConvertFrom-Json -ErrorAction Stop
            $markerTimestamp = [DateTime]::MinValue
            if (
                [string](Get-CodexFinishProperty -InputObject $marker -Name 'guard') -ceq $script:LifecycleHookDescription -and
                [string](Get-CodexFinishProperty -InputObject $marker -Name 'definitionId') -ceq $script:LifecycleHookDefinitionId -and
                [DateTime]::TryParse(
                    [string](Get-CodexFinishProperty -InputObject $marker -Name 'observedUtc'),
                    [ref]$markerTimestamp
                )
            ) {
                $hookObserved = $true
                $hookObservedUtc = $markerTimestamp.ToUniversalTime().ToString('o')
            }
        }
        catch {
            # A malformed or stale readiness marker means authorization still
            # needs confirmation; it does not invalidate the user's config.
        }
    }

    $configurationReady = $runtimeInstalled -and $notifyConfigured -and
        $hooksConfigured -and $enabled -and $configValid

    return [pscustomobject] [ordered] @{
        Installed        = $runtimeInstalled
        Enabled          = $enabled
        NotifyConfigured = $notifyConfigured
        HooksConfigured  = $hooksConfigured
        ConfigurationReady = $configurationReady
        HookObserved     = $hookObserved
        HookObservedUtc  = $hookObservedUtc
        AuthorizationPending = $configurationReady -and -not $hookObserved
        Ready            = $configurationReady -and $hookObserved
        ConfigValid      = $configValid
        ConfigError      = $configError
        LegacyHookPresent = $legacyPresent
        RuntimeScript    = $layout.RuntimeScript
        RuntimeHookScript = $layout.RuntimeHookScript
        HookDefinitionId  = $script:LifecycleHookDefinitionId
        ConfigFile       = $layout.ConfigFile
        HooksFile        = $layout.HooksFile
        SettingsFile     = $layout.SettingsFile
        StateDirectory   = $layout.StateDirectory
        HookReadyMarker  = $layout.HookReadyMarker
        AudioFile        = $audioFile
        AudioExists      = $audioExists
        RuntimeParameters = 'None'
    }
}

function Uninstall-CodexFinishShoutUnlocked {
    [CmdletBinding()]
    param(
        [string] $TargetRoot,
        [switch] $Force
    )

    $layout = Get-CodexFinishLayout -TargetRoot $TargetRoot
    $state = Read-CodexFinishInstallState -Path $layout.InstallState
    $previousBlock = if ($null -ne $state) {
        [string](Get-CodexFinishProperty -InputObject $state -Name 'previousNotifyBlock')
    }
    else {
        $null
    }
    $expectedBlock = if ($null -ne $state) {
        [string](Get-CodexFinishProperty -InputObject $state -Name 'notifyBlock')
    }
    else {
        New-CodexFinishNotifyBlock `
            -RuntimeScript $layout.RuntimeScript `
            -StateDirectory $layout.StateDirectory
    }
    $configExistedBefore = if ($null -ne $state) {
        [bool](Get-CodexFinishProperty -InputObject $state -Name 'configExistedBefore' -DefaultValue $true)
    }
    else {
        $true
    }
    $hooksExistedBefore = if ($null -ne $state) {
        [bool](Get-CodexFinishProperty -InputObject $state -Name 'hooksExistedBefore' -DefaultValue $true)
    }
    else {
        $true
    }
    $installedHookScript = if ($null -ne $state) {
        [string](Get-CodexFinishProperty `
            -InputObject $state `
            -Name 'lifecycleHookScript' `
            -DefaultValue $layout.RuntimeHookScript)
    }
    else {
        $layout.RuntimeHookScript
    }

    $configChanged = $false
    $newConfig = $null
    if ([IO.File]::Exists($layout.ConfigFile)) {
        $remove = Remove-CodexFinishManagedNotify `
            -Content ([IO.File]::ReadAllText($layout.ConfigFile)) `
            -PreviousBlock $previousBlock `
            -ExpectedBlock $expectedBlock `
            -Force:$Force
        $configChanged = $remove.Changed
        $newConfig = $remove.Content
    }

    $hooksChanged = $false
    $deleteHooksFile = $false
    $newHooksContent = $null
    if ([IO.File]::Exists($layout.HooksFile)) {
        $removeHooks = Remove-CodexFinishManagedLifecycleHooks `
            -Content ([IO.File]::ReadAllText($layout.HooksFile)) `
            -RuntimeHookScript $installedHookScript `
            -SourceLabel $layout.HooksFile
        $hooksChanged = $removeHooks.Changed
        $deleteHooksFile = $removeHooks.DeleteFile
        $newHooksContent = $removeHooks.Content
    }

    $backupPaths = New-Object Collections.Generic.List[string]
    if ($configChanged) {
        $backupPaths.Add($layout.ConfigFile)
    }
    if ($hooksChanged) {
        $backupPaths.Add($layout.HooksFile)
    }
    foreach ($name in $script:RuntimeFileNames) {
        $path = Join-Path $layout.RuntimeDirectory $name
        if ([IO.File]::Exists($path)) {
            $backupPaths.Add($path)
        }
    }
    if ([IO.File]::Exists($layout.InstallState)) {
        $backupPaths.Add($layout.InstallState)
    }
    $backupDirectory = New-CodexFinishBackupDirectory `
        -Layout $layout `
        -Paths $backupPaths.ToArray()

    if ($configChanged) {
        if (-not $configExistedBefore -and [string]::IsNullOrWhiteSpace($newConfig)) {
            [IO.File]::Delete($layout.ConfigFile)
        }
        else {
            Write-CodexFinishUtf8File -Path $layout.ConfigFile -Content $newConfig
        }
    }

    if ($hooksChanged) {
        if ($deleteHooksFile -and -not $hooksExistedBefore) {
            [IO.File]::Delete($layout.HooksFile)
        }
        else {
            Write-CodexFinishUtf8File `
                -Path $layout.HooksFile `
                -Content $newHooksContent
        }
    }

    foreach ($name in $script:RuntimeFileNames) {
        $path = Join-Path $layout.RuntimeDirectory $name
        if ([IO.File]::Exists($path)) {
            [IO.File]::Delete($path)
        }
    }
    if ([IO.File]::Exists($layout.InstallState)) {
        [IO.File]::Delete($layout.InstallState)
    }
    foreach ($relativeDirectory in @('assets\music', 'assets')) {
        $assetDirectory = Join-Path $layout.RuntimeDirectory $relativeDirectory
        if ([IO.Directory]::Exists($assetDirectory) -and
            ([IO.Directory]::GetFileSystemEntries($assetDirectory)).Count -eq 0) {
            [IO.Directory]::Delete($assetDirectory, $false)
        }
    }
    if (
        [IO.Directory]::Exists($layout.RuntimeDirectory) -and
        ([IO.Directory]::GetFileSystemEntries($layout.RuntimeDirectory)).Count -eq 0
    ) {
        [IO.Directory]::Delete($layout.RuntimeDirectory, $false)
    }

    return [pscustomobject] [ordered] @{
        Action           = 'Uninstall'
        Removed          = $true
        ConfigChanged    = $configChanged
        HooksChanged     = $hooksChanged
        BackupDirectory  = $backupDirectory
        UserDataPreserved = $true
        ReloadVSCodeOnce = $true
    }
}

function Invoke-CodexFinishSetupLocked {
    param([string] $TargetRoot, [scriptblock] $Operation)
    $root = (Get-CodexFinishTargetRoot -TargetRoot $TargetRoot).TrimEnd('\', '/').ToLowerInvariant()
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $id = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($root))).Replace('-', '') }
    finally { $sha.Dispose() }
    $mutex = New-Object Threading.Mutex($false, ('Local\CodexFinishShoutSetup-' + $id))
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne(60000) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'Another backend installation is running. Try again shortly.' }
        & $Operation
    }
    finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Install-CodexFinishShout {
    [CmdletBinding()]
    param([string] $TargetRoot, [string] $SourceDirectory = $PSScriptRoot, [switch] $Force)
    Invoke-CodexFinishSetupLocked -TargetRoot $TargetRoot -Operation {
        Install-CodexFinishShoutUnlocked -TargetRoot $TargetRoot -SourceDirectory $SourceDirectory -Force:$Force
    }
}

function Uninstall-CodexFinishShout {
    [CmdletBinding()]
    param([string] $TargetRoot, [switch] $Force)
    Invoke-CodexFinishSetupLocked -TargetRoot $TargetRoot -Operation {
        Uninstall-CodexFinishShoutUnlocked -TargetRoot $TargetRoot -Force:$Force
    }
}

Export-ModuleMember -Function @(
    'Install-CodexFinishShout',
    'Set-CodexFinishShoutEnabled',
    'Get-CodexFinishShoutStatus',
    'Uninstall-CodexFinishShout'
)
