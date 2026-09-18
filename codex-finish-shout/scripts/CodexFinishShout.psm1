# Codex Finish Shout runtime module.
#
# The notify callback supplies completion *candidates*. Lifecycle hooks maintain
# the authoritative per-session running/stopped state used to accept or cancel
# those candidates. Audio, TTS, and hardware delivery happen only after claim.

Set-StrictMode -Version 2.0
$script:CodexFinishModulePath = $PSCommandPath

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

function Get-CodexFinishDefaultMessage {
    [CmdletBinding()]
    param()

    return -join @(
        [char] 0x6211
        [char] 0x5E72
        [char] 0x5B8C
        [char] 0x4E86
    )
}

function Get-CodexFinishDefaultHardwareMessage {
    [CmdletBinding()]
    param()

    return -join @(
        [char] 0x5B8C
        [char] 0x6210
    )
}

function Get-CodexFinishDefaultAnnouncementTemplate {
    [CmdletBinding()]
    param()

    return -join @(
        [char] 0x9879
        [char] 0x76EE
        [char] 0x201C
        '{project}'
        [char] 0x201D
        [char] 0x7684
        ' Codex '
        [char] 0x4EFB
        [char] 0x52A1
        [char] 0x5DF2
        [char] 0x7ECF
        [char] 0x6267
        [char] 0x884C
        [char] 0x7ED3
        [char] 0x675F
        [char] 0xFF0C
        [char] 0x73B0
        [char] 0x5728
        [char] 0x5F00
        [char] 0x59CB
        [char] 0x64AD
        [char] 0x653E
        [char] 0x97F3
        [char] 0x4E50
        [char] 0x3002
    )
}

function Get-CodexFinishSongFileName {
    [CmdletBinding()]
    param()

    $songName = -join @(
        [char] 0x7275
        [char] 0x4E1D
        [char] 0x620F
    )
    return $songName + '.mp3'
}

function Get-CodexFinishDefaultConfigPath {
    [CmdletBinding()]
    param()

    $userProfilePath = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    if ([string]::IsNullOrWhiteSpace($userProfilePath)) {
        throw 'Unable to resolve the current user profile.'
    }

    return Join-Path $userProfilePath '.codex\codex-finish-shout.json'
}

function Resolve-CodexFinishConfigPath {
    [CmdletBinding()]
    param(
        [string] $ConfigPath
    )

    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        return [IO.Path]::GetFullPath($ConfigPath)
    }

    $environmentConfig = [Environment]::GetEnvironmentVariable('CODEX_FINISH_SHOUT_CONFIG')
    if (-not [string]::IsNullOrWhiteSpace($environmentConfig)) {
        return [IO.Path]::GetFullPath($environmentConfig)
    }

    $pluginData = [Environment]::GetEnvironmentVariable('PLUGIN_DATA')
    if (-not [string]::IsNullOrWhiteSpace($pluginData)) {
        $pluginSettings = Join-Path $pluginData 'settings.json'
        if ([IO.File]::Exists($pluginSettings)) {
            return [IO.Path]::GetFullPath($pluginSettings)
        }
    }

    return [IO.Path]::GetFullPath((Get-CodexFinishDefaultConfigPath))
}

function Get-CodexFinishDefaultSettings {
    [CmdletBinding()]
    param()

    return [pscustomobject] [ordered] @{
        schemaVersion = 2
        enabled       = $true
        requiredClient = 'VS Code'
        mode          = 'audioFile'
        message       = Get-CodexFinishDefaultMessage
        audioFile     = 'builtin:soft-chime'
        fallbackMode  = 'tts'
        volume        = 100
        rate          = 0
        voiceName     = ''
        playback      = [pscustomobject] [ordered] @{
            mode            = 'once'
            seconds         = 30
            maximumSeconds  = 3600
        }
        completionGuard = [pscustomobject] [ordered] @{
            enabled       = $true
            graceSeconds  = 10
            lifecycleMode = 'require'
        }
        visual        = [pscustomobject] [ordered] @{
            enabled              = $true
            durationMilliseconds = 2000
        }
        projectMonitor = [pscustomobject] [ordered] @{
            maximumProjects = 6
        }
        announcement  = [pscustomobject] [ordered] @{
            enabled  = $true
            template = Get-CodexFinishDefaultAnnouncementTemplate
        }
        quietHours    = [pscustomobject] [ordered] @{
            enabled = $false
            start   = '22:00'
            end     = '08:00'
        }
        hardware     = [pscustomobject] [ordered] @{
            enabled              = $false
            transport            = 'serial'
            port                 = ''
            autoDetect           = $true
            baudRate             = 115200
            timeoutMilliseconds  = 1000
            message              = Get-CodexFinishDefaultHardwareMessage
            backgroundColor      = '#16A34A'
            foregroundColor      = '#FFFFFF'
        }
    }
}

function ConvertTo-CodexFinishBoolean {
    param(
        [object] $Value,
        [bool] $DefaultValue
    )

    if ($Value -is [bool]) {
        return $Value
    }
    if ($null -eq $Value) {
        return $DefaultValue
    }

    $text = ([string] $Value).Trim()
    if ($text.Equals('true', [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    if ($text.Equals('false', [StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    return $DefaultValue
}

function ConvertTo-CodexFinishInteger {
    param(
        [object] $Value,
        [int] $DefaultValue,
        [int] $Minimum,
        [int] $Maximum
    )

    $parsed = 0
    if ($null -eq $Value -or -not [int]::TryParse([string] $Value, [ref] $parsed)) {
        return $DefaultValue
    }

    return [Math]::Min($Maximum, [Math]::Max($Minimum, $parsed))
}

function Test-CodexFinishTimeText {
    param(
        [string] $Value
    )

    $parsed = [DateTime]::MinValue
    return [DateTime]::TryParseExact(
        $Value,
        'HH:mm',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None,
        [ref] $parsed
    )
}

function Test-CodexFinishColorText {
    param(
        [string] $Value
    )

    return $Value -match '^#[0-9A-Fa-f]{6}$'
}

function ConvertTo-CodexFinishSettings {
    [CmdletBinding()]
    param(
        [object] $InputObject
    )

    $defaults = Get-CodexFinishDefaultSettings
    if ($null -eq $InputObject) {
        return $defaults
    }
    if ($InputObject -isnot [pscustomobject]) {
        throw 'The settings root must be a JSON object.'
    }

    $settings = Get-CodexFinishDefaultSettings
    $settings.enabled = ConvertTo-CodexFinishBoolean `
        -Value (Get-CodexFinishProperty -InputObject $InputObject -Name 'enabled') `
        -DefaultValue $settings.enabled

    $requiredClient = [string] (
        Get-CodexFinishProperty `
            -InputObject $InputObject `
            -Name 'requiredClient' `
            -DefaultValue $settings.requiredClient
    )
    if (-not [string]::IsNullOrWhiteSpace($requiredClient) -and $requiredClient.Length -le 64) {
        $settings.requiredClient = $requiredClient
    }

    $mode = [string] (Get-CodexFinishProperty -InputObject $InputObject -Name 'mode' -DefaultValue $settings.mode)
    if ($mode -notin @('audioFile', 'tts', 'beep')) {
        $mode = $settings.mode
    }
    $settings.mode = $mode

    $message = [string] (Get-CodexFinishProperty -InputObject $InputObject -Name 'message' -DefaultValue $settings.message)
    if (-not [string]::IsNullOrWhiteSpace($message) -and $message.Length -le 256) {
        $settings.message = $message
    }

    $audioFile = [string] (Get-CodexFinishProperty -InputObject $InputObject -Name 'audioFile' -DefaultValue $settings.audioFile)
    if (-not [string]::IsNullOrWhiteSpace($audioFile)) {
        $settings.audioFile = $audioFile
    }

    $fallbackMode = [string] (Get-CodexFinishProperty -InputObject $InputObject -Name 'fallbackMode' -DefaultValue $settings.fallbackMode)
    if ($fallbackMode -notin @('tts', 'beep', 'none')) {
        $fallbackMode = $settings.fallbackMode
    }
    $settings.fallbackMode = $fallbackMode

    $settings.volume = ConvertTo-CodexFinishInteger `
        -Value (Get-CodexFinishProperty -InputObject $InputObject -Name 'volume') `
        -DefaultValue $settings.volume `
        -Minimum 0 `
        -Maximum 100
    $settings.rate = ConvertTo-CodexFinishInteger `
        -Value (Get-CodexFinishProperty -InputObject $InputObject -Name 'rate') `
        -DefaultValue $settings.rate `
        -Minimum -10 `
        -Maximum 10
    $settings.voiceName = [string] (Get-CodexFinishProperty -InputObject $InputObject -Name 'voiceName' -DefaultValue '')

    $playbackInput = Get-CodexFinishProperty -InputObject $InputObject -Name 'playback'
    if ($null -ne $playbackInput -and $playbackInput -is [pscustomobject]) {
        $playbackMode = [string] (
            Get-CodexFinishProperty `
                -InputObject $playbackInput `
                -Name 'mode' `
                -DefaultValue $settings.playback.mode
        )
        if ($playbackMode -in @('once', 'loop', 'seconds')) {
            $settings.playback.mode = $playbackMode
        }
        $settings.playback.seconds = ConvertTo-CodexFinishInteger `
            -Value (Get-CodexFinishProperty -InputObject $playbackInput -Name 'seconds') `
            -DefaultValue $settings.playback.seconds `
            -Minimum 1 `
            -Maximum 86400
        $settings.playback.maximumSeconds = ConvertTo-CodexFinishInteger `
            -Value (Get-CodexFinishProperty -InputObject $playbackInput -Name 'maximumSeconds') `
            -DefaultValue $settings.playback.maximumSeconds `
            -Minimum 1 `
            -Maximum 86400
    }

    $completionGuardInput = Get-CodexFinishProperty -InputObject $InputObject -Name 'completionGuard'
    if ($null -ne $completionGuardInput -and $completionGuardInput -is [pscustomobject]) {
        $settings.completionGuard.enabled = ConvertTo-CodexFinishBoolean `
            -Value (Get-CodexFinishProperty -InputObject $completionGuardInput -Name 'enabled') `
            -DefaultValue $settings.completionGuard.enabled
        $settings.completionGuard.graceSeconds = ConvertTo-CodexFinishInteger `
            -Value (Get-CodexFinishProperty -InputObject $completionGuardInput -Name 'graceSeconds') `
            -DefaultValue $settings.completionGuard.graceSeconds `
            -Minimum 0 `
            -Maximum 120
        $lifecycleMode = [string] (
            Get-CodexFinishProperty `
                -InputObject $completionGuardInput `
                -Name 'lifecycleMode' `
                -DefaultValue $settings.completionGuard.lifecycleMode
        )
        if ($lifecycleMode -in @('require', 'prefer', 'off')) {
            $settings.completionGuard.lifecycleMode = $lifecycleMode
        }
    }

    $visualInput = Get-CodexFinishProperty -InputObject $InputObject -Name 'visual'
    if ($null -ne $visualInput -and $visualInput -is [pscustomobject]) {
        $settings.visual.enabled = ConvertTo-CodexFinishBoolean `
            -Value (Get-CodexFinishProperty -InputObject $visualInput -Name 'enabled') `
            -DefaultValue $settings.visual.enabled
        $settings.visual.durationMilliseconds = ConvertTo-CodexFinishInteger `
            -Value (Get-CodexFinishProperty -InputObject $visualInput -Name 'durationMilliseconds') `
            -DefaultValue $settings.visual.durationMilliseconds `
            -Minimum 1000 `
            -Maximum 2000
    }

    $projectMonitorInput = Get-CodexFinishProperty -InputObject $InputObject -Name 'projectMonitor'
    if ($null -ne $projectMonitorInput -and $projectMonitorInput -is [pscustomobject]) {
        $settings.projectMonitor.maximumProjects = ConvertTo-CodexFinishInteger `
            -Value (Get-CodexFinishProperty -InputObject $projectMonitorInput -Name 'maximumProjects') `
            -DefaultValue $settings.projectMonitor.maximumProjects `
            -Minimum 1 `
            -Maximum 6
    }

    $announcementInput = Get-CodexFinishProperty -InputObject $InputObject -Name 'announcement'
    if ($null -ne $announcementInput -and $announcementInput -is [pscustomobject]) {
        $settings.announcement.enabled = ConvertTo-CodexFinishBoolean `
            -Value (Get-CodexFinishProperty -InputObject $announcementInput -Name 'enabled') `
            -DefaultValue $settings.announcement.enabled

        $announcementTemplate = [string] (
            Get-CodexFinishProperty `
                -InputObject $announcementInput `
                -Name 'template' `
                -DefaultValue $settings.announcement.template
        )
        if (-not [string]::IsNullOrWhiteSpace($announcementTemplate) -and $announcementTemplate.Length -le 512) {
            $settings.announcement.template = $announcementTemplate
        }
    }

    $quietInput = Get-CodexFinishProperty -InputObject $InputObject -Name 'quietHours'
    if ($null -ne $quietInput -and $quietInput -is [pscustomobject]) {
        $settings.quietHours.enabled = ConvertTo-CodexFinishBoolean `
            -Value (Get-CodexFinishProperty -InputObject $quietInput -Name 'enabled') `
            -DefaultValue $settings.quietHours.enabled

        $quietStart = [string] (Get-CodexFinishProperty -InputObject $quietInput -Name 'start' -DefaultValue $settings.quietHours.start)
        $quietEnd = [string] (Get-CodexFinishProperty -InputObject $quietInput -Name 'end' -DefaultValue $settings.quietHours.end)
        if (Test-CodexFinishTimeText -Value $quietStart) {
            $settings.quietHours.start = $quietStart
        }
        if (Test-CodexFinishTimeText -Value $quietEnd) {
            $settings.quietHours.end = $quietEnd
        }
    }

    $hardwareInput = Get-CodexFinishProperty -InputObject $InputObject -Name 'hardware'
    if ($null -ne $hardwareInput -and $hardwareInput -is [pscustomobject]) {
        $settings.hardware.enabled = ConvertTo-CodexFinishBoolean `
            -Value (Get-CodexFinishProperty -InputObject $hardwareInput -Name 'enabled') `
            -DefaultValue $settings.hardware.enabled

        $transport = [string] (
            Get-CodexFinishProperty `
                -InputObject $hardwareInput `
                -Name 'transport' `
                -DefaultValue $settings.hardware.transport
        )
        if ($transport -ceq 'serial') {
            $settings.hardware.transport = $transport
        }

        $port = [string] (Get-CodexFinishProperty -InputObject $hardwareInput -Name 'port' -DefaultValue '')
        if ([string]::IsNullOrWhiteSpace($port) -or $port -match '^COM[0-9]{1,3}$') {
            $settings.hardware.port = $port.Trim().ToUpperInvariant()
        }

        $settings.hardware.autoDetect = ConvertTo-CodexFinishBoolean `
            -Value (Get-CodexFinishProperty -InputObject $hardwareInput -Name 'autoDetect') `
            -DefaultValue $settings.hardware.autoDetect
        $settings.hardware.baudRate = ConvertTo-CodexFinishInteger `
            -Value (Get-CodexFinishProperty -InputObject $hardwareInput -Name 'baudRate') `
            -DefaultValue $settings.hardware.baudRate `
            -Minimum 1200 `
            -Maximum 921600
        $settings.hardware.timeoutMilliseconds = ConvertTo-CodexFinishInteger `
            -Value (Get-CodexFinishProperty -InputObject $hardwareInput -Name 'timeoutMilliseconds') `
            -DefaultValue $settings.hardware.timeoutMilliseconds `
            -Minimum 100 `
            -Maximum 5000

        $hardwareMessage = [string] (
            Get-CodexFinishProperty `
                -InputObject $hardwareInput `
                -Name 'message' `
                -DefaultValue $settings.hardware.message
        )
        if (-not [string]::IsNullOrWhiteSpace($hardwareMessage) -and $hardwareMessage.Length -le 32) {
            $settings.hardware.message = $hardwareMessage
        }

        $backgroundColor = [string] (
            Get-CodexFinishProperty `
                -InputObject $hardwareInput `
                -Name 'backgroundColor' `
                -DefaultValue $settings.hardware.backgroundColor
        )
        if (Test-CodexFinishColorText -Value $backgroundColor) {
            $settings.hardware.backgroundColor = $backgroundColor.ToUpperInvariant()
        }

        $foregroundColor = [string] (
            Get-CodexFinishProperty `
                -InputObject $hardwareInput `
                -Name 'foregroundColor' `
                -DefaultValue $settings.hardware.foregroundColor
        )
        if (Test-CodexFinishColorText -Value $foregroundColor) {
            $settings.hardware.foregroundColor = $foregroundColor.ToUpperInvariant()
        }
    }

    return $settings
}

function Get-CodexFinishSettings {
    [CmdletBinding()]
    param(
        [string] $ConfigPath
    )

    $resolvedConfig = Resolve-CodexFinishConfigPath -ConfigPath $ConfigPath
    if (-not [IO.File]::Exists($resolvedConfig)) {
        return Get-CodexFinishDefaultSettings
    }

    try {
        $document = [IO.File]::ReadAllText($resolvedConfig) | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "The settings file is not valid JSON: $resolvedConfig"
    }

    return ConvertTo-CodexFinishSettings -InputObject $document
}

function Write-CodexFinishUtf8File {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [Parameter(Mandatory = $true)]
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

function Write-CodexFinishSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Settings,
        [string] $ConfigPath,
        [string] $BackupDirectory
    )

    $resolvedConfig = Resolve-CodexFinishConfigPath -ConfigPath $ConfigPath
    if ([string]::IsNullOrWhiteSpace($BackupDirectory)) {
        $targetRoot = [IO.Path]::GetDirectoryName($resolvedConfig)
        $BackupDirectory = Join-Path $targetRoot 'backups\codex-finish-shout-plugin'
    }
    $resolvedBackup = [IO.Path]::GetFullPath($BackupDirectory)
    $backupPath = $null

    if ([IO.File]::Exists($resolvedConfig)) {
        $backupFolderName = [DateTime]::Now.ToString('yyyyMMdd-HHmmss-fff') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $backupFolder = Join-Path $resolvedBackup $backupFolderName
        $null = [IO.Directory]::CreateDirectory($backupFolder)
        $backupPath = Join-Path $backupFolder ([IO.Path]::GetFileName($resolvedConfig))
        [IO.File]::Copy($resolvedConfig, $backupPath, $false)
    }

    $normalized = ConvertTo-CodexFinishSettings -InputObject $Settings
    $json = ($normalized | ConvertTo-Json -Depth 10) + [Environment]::NewLine
    Write-CodexFinishUtf8File -Path $resolvedConfig -Content $json

    return [pscustomobject] @{
        ConfigPath = $resolvedConfig
        BackupPath = $backupPath
        Settings   = $normalized
    }
}

function Test-CodexFinishNotifyEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Event,
        [string] $RequiredClient = 'VS Code'
    )

    $eventName = [string] (Get-CodexFinishProperty -InputObject $Event -Name 'type')
    if ($eventName -cne 'agent-turn-complete') {
        return $false
    }

    $client = [string] (Get-CodexFinishProperty -InputObject $Event -Name 'client')
    if ([string]::IsNullOrWhiteSpace($client) -or $client -cne $RequiredClient) {
        return $false
    }

    # A real completion notification has a stable identity. Without these
    # fields a transient UI state (or a legacy hook payload) cannot be safely
    # deduplicated and must never start playback.
    $threadId = [string] (Get-CodexFinishProperty -InputObject $Event -Name 'thread-id')
    $turnId = [string] (Get-CodexFinishProperty -InputObject $Event -Name 'turn-id')
    $cwd = [string] (Get-CodexFinishProperty -InputObject $Event -Name 'cwd')
    $lastAssistantMessage = [string] (
        Get-CodexFinishProperty -InputObject $Event -Name 'last-assistant-message'
    )
    return (
        -not [string]::IsNullOrWhiteSpace($threadId) -and
        -not [string]::IsNullOrWhiteSpace($turnId) -and
        -not [string]::IsNullOrWhiteSpace($cwd) -and
        # Codex includes the final assistant text in a genuine turn-complete
        # notification. Startup/placeholder payloads have this field missing
        # or empty and must never claim a turn or start audio.
        -not [string]::IsNullOrWhiteSpace($lastAssistantMessage)
    )
}

function Wait-CodexFinishCompletionGracePeriod {
    [CmdletBinding()]
    param(
        [ValidateRange(0, 120)]
        [int] $Seconds = 10
    )

    if ($Seconds -le 0) {
        return
    }

    # Codex's notify command is asynchronous from the user's point of view.
    # Keep the event out of the claim/play path for a short settling window so
    # a momentary completed state cannot immediately start audio.
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        $remaining = ($deadline - [DateTime]::UtcNow).TotalMilliseconds
        if ($remaining -le 0) {
            break
        }
        Start-Sleep -Milliseconds ([Math]::Min(250, [Math]::Ceiling($remaining)))
    } while ([DateTime]::UtcNow -lt $deadline)
}

function Get-CodexFinishProjectPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Event
    )

    $cwd = [string] (Get-CodexFinishProperty -InputObject $Event -Name 'cwd')
    if ([string]::IsNullOrWhiteSpace($cwd)) {
        return $null
    }

    try {
        $fullPath = [IO.Path]::GetFullPath($cwd)

        # Older hook processes could decode UTF-8 stdin with the Windows ANSI
        # code page. Repair that specific mojibake only when the original path
        # does not exist and the repaired directory does, avoiding guesses for
        # legitimate (or not-yet-created) paths.
        if (-not [IO.Directory]::Exists($fullPath)) {
            try {
                $gbk = [Text.Encoding]::GetEncoding(936)
                $repairedCwd = [Text.Encoding]::UTF8.GetString($gbk.GetBytes($cwd))
                $repairedPath = [IO.Path]::GetFullPath($repairedCwd)
                if ([IO.Directory]::Exists($repairedPath)) {
                    $fullPath = $repairedPath
                }
            }
            catch {
                # Keep the original normalized path when it is not reversible.
            }
        }
        $rootPath = [IO.Path]::GetPathRoot($fullPath)
        if (
            -not [string]::IsNullOrWhiteSpace($rootPath) -and
            $fullPath.Length -gt $rootPath.Length
        ) {
            $fullPath = $fullPath.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        }
        return $fullPath
    }
    catch {
        return $null
    }
}

function Get-CodexFinishProjectName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Event
    )

    $projectPath = Get-CodexFinishProjectPath -Event $Event
    if (-not [string]::IsNullOrWhiteSpace($projectPath)) {
        $name = [IO.Path]::GetFileName($projectPath)
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            return $name
        }

        $rootName = $projectPath.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        if (-not [string]::IsNullOrWhiteSpace($rootName)) {
            return $rootName
        }
    }

    return -join @(
        [char] 0x5F53
        [char] 0x524D
        [char] 0x9879
        [char] 0x76EE
    )
}

function Get-CodexFinishProjectKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Event
    )

    $projectPath = Get-CodexFinishProjectPath -Event $Event
    if ([string]::IsNullOrWhiteSpace($projectPath)) {
        return $null
    }

    # Windows paths are case-insensitive. Normalizing case keeps the same project
    # identity when different VS Code windows use different path casing.
    $normalizedPath = $projectPath.ToUpperInvariant()
    $bytes = [Text.Encoding]::UTF8.GetBytes($normalizedPath)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash($bytes)
        return -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-CodexFinishBoardPortCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object] $HardwareSettings
    )

    # WMI/Plug-and-Play discovery can emit progress records on a fresh
    # PowerShell process. A notify handler must never leak anything to stderr.
    $ProgressPreference = 'SilentlyContinue'

    $serialPortLookupSucceeded = $false
    try {
        $serialPortNames = @([IO.Ports.SerialPort]::GetPortNames())
        $serialPortLookupSucceeded = $true
    }
    catch {
        $serialPortNames = @()
    }

    $configuredPort = [string] (Get-CodexFinishProperty -InputObject $HardwareSettings -Name 'port' -DefaultValue '')
    if (-not [string]::IsNullOrWhiteSpace($configuredPort)) {
        $normalizedConfiguredPort = $configuredPort.Trim().ToUpperInvariant()
        # A fixed port is a selection, not proof that the device is still
        # connected.  When Windows can enumerate ports, reject a stale COM name
        # immediately so the notification can fall back to the desktop path.
        if ($serialPortLookupSucceeded -and $serialPortNames -notcontains $normalizedConfiguredPort) {
            return @()
        }
        return @($normalizedConfiguredPort)
    }

    if (-not (ConvertTo-CodexFinishBoolean `
        -Value (Get-CodexFinishProperty -InputObject $HardwareSettings -Name 'autoDetect') `
        -DefaultValue $true
    )) {
        return @()
    }

    $exactPorts = New-Object Collections.Generic.List[string]
    $compatiblePorts = New-Object Collections.Generic.List[string]
    try {
        $devices = @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop)
        foreach ($device in $devices) {
            $friendlyName = [string] $device.Name
            $isEspressifUsbSerial = ([string] $device.DeviceID) -match '(?i)VID_303A&PID_1001'
            $hasKnownSerialName = $friendlyName -match '(?i)(ESP|JTAG/serial|USB Serial Device|USB-SERIAL|CP210|CH34)'
            if (
                [string]::IsNullOrWhiteSpace($friendlyName) -or
                (-not $isEspressifUsbSerial -and -not $hasKnownSerialName)
            ) {
                continue
            }

            $match = [regex]::Match($friendlyName, '(?i)\((COM[0-9]{1,3})\)')
            if ($match.Success) {
                $portName = $match.Groups[1].Value.ToUpperInvariant()
                if ($isEspressifUsbSerial) {
                    $exactPorts.Add($portName)
                }
                else {
                    $compatiblePorts.Add($portName)
                }
            }
        }
    }
    catch {
        # Device discovery is best effort. The notifier must remain silent and
        # must not affect Codex when the PnP service is unavailable.
    }

    # Prefer the ESP32-S3 native USB Serial/JTAG VID/PID. Generic USB-UART
    # names are retained only as a compatibility fallback for older boards.
    foreach ($candidateList in @($exactPorts, $compatiblePorts)) {
        foreach ($port in $candidateList.ToArray()) {
            if ($serialPortNames -contains $port) {
                return @($port)
            }
        }
    }

    return @()
}

function New-CodexFinishBoardPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object] $HardwareSettings,
        [Parameter(Mandatory = $true)]
        [string] $ProjectName,
        [string] $ProjectPath,
        [string] $ProjectKey,
        [string] $TurnId
    )

    return [pscustomobject] [ordered] @{
        version          = 1
        type             = 'completion'
        status           = 'completed'
        project          = ConvertTo-CodexFinishUtf8TruncatedText -Value $ProjectName -MaximumBytes 360
        message          = [string] (Get-CodexFinishProperty -InputObject $HardwareSettings -Name 'message' -DefaultValue (Get-CodexFinishDefaultHardwareMessage))
        background       = [string] (Get-CodexFinishProperty -InputObject $HardwareSettings -Name 'backgroundColor' -DefaultValue '#16A34A')
        foreground       = [string] (Get-CodexFinishProperty -InputObject $HardwareSettings -Name 'foregroundColor' -DefaultValue '#FFFFFF')
        eventId          = $TurnId
        projectKey       = $ProjectKey
    }
}

function ConvertTo-CodexFinishUtf8TruncatedText {
    param(
        [string] $Value,
        [ValidateRange(1, 1024)]
        [int] $MaximumBytes = 48
    )

    if ([string]::IsNullOrEmpty($Value)) {
        return ''
    }
    if ([Text.Encoding]::UTF8.GetByteCount($Value) -le $MaximumBytes) {
        return $Value
    }

    $builder = New-Object Text.StringBuilder
    $enumerator = [Globalization.StringInfo]::GetTextElementEnumerator($Value)
    while ($enumerator.MoveNext()) {
        $candidate = $builder.ToString() + [string]$enumerator.Current
        if ([Text.Encoding]::UTF8.GetByteCount($candidate) -gt $MaximumBytes) {
            break
        }
        $null = $builder.Append([string]$enumerator.Current)
    }
    return $builder.ToString()
}

function New-CodexFinishBoardSnapshotPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object] $MonitorState,
        [ValidateRange(1, 6)]
        [int] $MaximumProjects = 6
    )

    $allProjects = @(
        Get-CodexFinishProperty -InputObject $MonitorState -Name 'projects' -DefaultValue @()
    )
    $selectedProjects = @($allProjects | Sort-Object `
        @{ Expression = { if ([string]$_.status -ceq 'running') { 0 } else { 1 } }; Ascending = $true }, `
        @{ Expression = { ConvertFrom-CodexFinishUtcText $_.updatedAtUtc }; Descending = $true } |
        Select-Object -First $MaximumProjects)

    $boardProjects = foreach ($project in $selectedProjects) {
        $status = if ([string]$project.status -ceq 'running') { 'running' } else { 'completed' }
        [pscustomobject] [ordered] @{
            name         = ConvertTo-CodexFinishUtf8TruncatedText -Value ([string]$project.name) -MaximumBytes 48
            status       = $status
            projectKey   = [string]$project.projectKey
            updatedAtUtc = [string]$project.updatedAtUtc
        }
    }

    return [pscustomobject] [ordered] @{
        version  = 1
        type     = 'project_snapshot'
        total    = [int] (Get-CodexFinishProperty -InputObject $MonitorState -Name 'total' -DefaultValue $allProjects.Count)
        projects = [object[]]@($boardProjects)
    }
}

function Send-CodexFinishBoardPayloads {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object] $HardwareSettings,
        [Parameter(Mandatory = $true)]
        [object[]] $Payloads,
        [string] $SnapshotStateDirectory,
        [ValidateRange(1, 6)]
        [int] $MaximumProjects = 6
    )

    $result = [ordered] @{
        Sent           = $false
        Port           = $null
        Transport      = [string] (Get-CodexFinishProperty -InputObject $HardwareSettings -Name 'transport' -DefaultValue 'serial')
        Reason         = $null
        Error          = $null
        MessagesSent   = 0
        CompletionSent = $false
        SnapshotSent   = $false
    }

    if (-not (ConvertTo-CodexFinishBoolean `
        -Value (Get-CodexFinishProperty -InputObject $HardwareSettings -Name 'enabled') `
        -DefaultValue $true
    )) {
        $result.Reason = 'disabled'
        return [pscustomobject] $result
    }
    if ($result.Transport -cne 'serial') {
        $result.Reason = 'unsupported-transport'
        return [pscustomobject] $result
    }
    if (@($Payloads).Count -eq 0) {
        $result.Reason = 'no-payload'
        return [pscustomobject] $result
    }

    $ports = @(Get-CodexFinishBoardPortCandidates -HardwareSettings $HardwareSettings)
    if ($ports.Count -eq 0) {
        $result.Reason = 'board-not-connected'
        return [pscustomobject] $result
    }

    $baudRate = ConvertTo-CodexFinishInteger `
        -Value (Get-CodexFinishProperty -InputObject $HardwareSettings -Name 'baudRate') `
        -DefaultValue 115200 `
        -Minimum 1200 `
        -Maximum 921600
    $timeoutMilliseconds = ConvertTo-CodexFinishInteger `
        -Value (Get-CodexFinishProperty -InputObject $HardwareSettings -Name 'timeoutMilliseconds') `
        -DefaultValue 1000 `
        -Minimum 100 `
        -Maximum 5000
    $messages = foreach ($payload in @($Payloads)) {
        $json = ($payload | ConvertTo-Json -Depth 8 -Compress) + "`n"
        if ([Text.Encoding]::UTF8.GetByteCount($json) -ge 2048) {
            $result.Reason = 'payload-too-large'
            $result.Error = 'A board JSON line must be smaller than 2048 UTF-8 bytes.'
            return [pscustomobject] $result
        }
        [pscustomobject]@{
            Type = [string](Get-CodexFinishProperty -InputObject $payload -Name 'type')
            Json = $json
        }
    }

    $lastError = $null
    foreach ($portName in $ports) {
        $serial = $null
        $portMutex = $null
        $portLockTaken = $false
        try {
            $mutexName = 'Local\CodexFinishShout.Board.' + $portName
            $portMutex = New-Object Threading.Mutex($false, $mutexName)
            try {
                $portLockTaken = $portMutex.WaitOne($timeoutMilliseconds)
            }
            catch [Threading.AbandonedMutexException] {
                # The abandoned mutex is acquired by this process.
                $portLockTaken = $true
            }
            if (-not $portLockTaken) {
                $lastError = "Timed out waiting to send on $portName."
                continue
            }

            $serial = New-Object IO.Ports.SerialPort(
                $portName,
                $baudRate,
                [IO.Ports.Parity]::None,
                8,
                [IO.Ports.StopBits]::One
            )
            $serial.Encoding = New-Object Text.UTF8Encoding($false)
            $serial.NewLine = "`n"
            $serial.WriteTimeout = $timeoutMilliseconds
            $serial.ReadTimeout = $timeoutMilliseconds
            $serial.DtrEnable = $false
            $serial.RtsEnable = $false
            $serial.Open()
            foreach ($message in @($messages)) {
                if (
                    $message.Type -ceq 'project_snapshot' -and
                    -not [string]::IsNullOrWhiteSpace($SnapshotStateDirectory)
                ) {
                    # Refresh only after acquiring the port mutex. This prevents
                    # a delayed older Hook process from overwriting a newer
                    # project state on the screen.
                    $freshState = Get-CodexFinishProjectMonitorState `
                        -StateDirectory $SnapshotStateDirectory
                    $freshPayload = New-CodexFinishBoardSnapshotPayload `
                        -MonitorState $freshState `
                        -MaximumProjects $MaximumProjects
                    $message.Json = ($freshPayload | ConvertTo-Json -Depth 8 -Compress) + "`n"
                    if ([Text.Encoding]::UTF8.GetByteCount($message.Json) -ge 2048) {
                        throw 'A board JSON line must be smaller than 2048 UTF-8 bytes.'
                    }
                }
                $serial.Write($message.Json)
                $result.MessagesSent++
                if ($message.Type -ceq 'completion') {
                    $result.CompletionSent = $true
                }
                elseif ($message.Type -ceq 'project_snapshot') {
                    $result.SnapshotSent = $true
                }
            }
            $serial.BaseStream.Flush()
            $result.Sent = $true
            $result.Port = $portName
            $result.Reason = 'sent'
            return [pscustomobject] $result
        }
        catch {
            $lastError = $_.Exception.Message
            if ($result.MessagesSent -gt 0) {
                $result.Sent = $true
                $result.Port = $portName
                if ($result.CompletionSent -and -not $result.SnapshotSent) {
                    $result.Reason = 'completion-sent-snapshot-failed'
                }
                else {
                    $result.Reason = 'partially-sent'
                }
                $result.Error = $lastError
                return [pscustomobject] $result
            }
        }
        finally {
            if ($null -ne $serial) {
                try {
                    if ($serial.IsOpen) {
                        $serial.Close()
                    }
                }
                catch {
                    # Closing a disconnected USB device is best effort.
                }
                $serial.Dispose()
            }
            if ($portLockTaken -and $null -ne $portMutex) {
                try {
                    $portMutex.ReleaseMutex()
                }
                catch {
                    # A process teardown race must not affect Codex notify.
                }
            }
            if ($null -ne $portMutex) {
                $portMutex.Dispose()
            }
        }
    }

    $result.Reason = 'send-failed'
    $result.Error = $lastError
    return [pscustomobject] $result
}

function Send-CodexFinishBoardCompletion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object] $HardwareSettings,
        [Parameter(Mandatory = $true)]
        [string] $ProjectName,
        [string] $ProjectPath,
        [string] $ProjectKey,
        [string] $TurnId
    )

    $payload = New-CodexFinishBoardPayload `
        -HardwareSettings $HardwareSettings `
        -ProjectName $ProjectName `
        -ProjectPath $ProjectPath `
        -ProjectKey $ProjectKey `
        -TurnId $TurnId
    return Send-CodexFinishBoardPayloads -HardwareSettings $HardwareSettings -Payloads @($payload)
}

function Get-CodexFinishPresentationRoute {
    [CmdletBinding()]
    param(
        [object] $BoardResult
    )

    if (
        $null -ne $BoardResult -and
        (ConvertTo-CodexFinishBoolean `
            -Value (Get-CodexFinishProperty -InputObject $BoardResult -Name 'Sent') `
            -DefaultValue $false)
    ) {
        return 'hardware'
    }

    return 'desktop'
}

function Send-CodexFinishBoardSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object] $HardwareSettings,
        [Parameter(Mandatory = $true)]
        [object] $MonitorState,
        [ValidateRange(1, 6)]
        [int] $MaximumProjects = 6,
        [string] $StateDirectory
    )

    $payload = New-CodexFinishBoardSnapshotPayload `
        -MonitorState $MonitorState `
        -MaximumProjects $MaximumProjects
    return Send-CodexFinishBoardPayloads `
        -HardwareSettings $HardwareSettings `
        -Payloads @($payload) `
        -SnapshotStateDirectory $StateDirectory `
        -MaximumProjects $MaximumProjects
}

function Start-CodexFinishBoardSnapshotDelivery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object] $HardwareSettings,
        [Parameter(Mandatory = $true)]
        [string] $StateDirectory,
        [ValidateRange(1, 6)]
        [int] $MaximumProjects = 6
    )

    try {
        if (
            [string]::IsNullOrWhiteSpace($script:CodexFinishModulePath) -or
            -not [IO.File]::Exists($script:CodexFinishModulePath)
        ) {
            return $false
        }
        $envelope = [ordered]@{
            hardware = $HardwareSettings
            stateDirectory = [IO.Path]::GetFullPath($StateDirectory)
            maximumProjects = $MaximumProjects
        }
        $envelopeBase64 = [Convert]::ToBase64String(
            [Text.Encoding]::UTF8.GetBytes(($envelope | ConvertTo-Json -Depth 6 -Compress))
        )
        $escapedModule = $script:CodexFinishModulePath.Replace("'", "''")
        $command = @"
`$ErrorActionPreference = 'SilentlyContinue'
`$json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$envelopeBase64'))
`$delivery = `$json | ConvertFrom-Json
Import-Module '$escapedModule' -Force
`$state = Get-CodexFinishProjectMonitorState -StateDirectory ([string]`$delivery.stateDirectory)
`$null = Send-CodexFinishBoardSnapshot -HardwareSettings `$delivery.hardware -MonitorState `$state -MaximumProjects ([int]`$delivery.maximumProjects) -StateDirectory ([string]`$delivery.stateDirectory)
"@
        $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $powerShellPath = (Get-Command powershell.exe -ErrorAction Stop).Source
        $null = Start-Process `
            -FilePath $powerShellPath `
            -ArgumentList @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy',
                'Bypass', '-EncodedCommand', $encodedCommand
            ) `
            -WindowStyle Hidden
        return $true
    }
    catch {
        return $false
    }
}

function Get-CodexFinishAnnouncementMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Event,
        [Parameter(Mandatory = $true)]
        [object] $Settings
    )

    $announcement = Get-CodexFinishProperty -InputObject $Settings -Name 'announcement'
    if ($null -eq $announcement -or -not (
        ConvertTo-CodexFinishBoolean `
            -Value (Get-CodexFinishProperty -InputObject $announcement -Name 'enabled') `
            -DefaultValue $true
    )) {
        return $null
    }

    $template = [string] (
        Get-CodexFinishProperty `
            -InputObject $announcement `
            -Name 'template' `
            -DefaultValue (Get-CodexFinishDefaultAnnouncementTemplate)
    )
    if ([string]::IsNullOrWhiteSpace($template)) {
        return $null
    }

    return $template.Replace('{project}', (Get-CodexFinishProjectName -Event $Event))
}

function Get-CodexFinishTurnHash {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Event
    )

    $turnId = [string] (Get-CodexFinishProperty -InputObject $Event -Name 'turn-id')
    if ([string]::IsNullOrWhiteSpace($turnId)) {
        return $null
    }

    $threadId = [string] (Get-CodexFinishProperty -InputObject $Event -Name 'thread-id')
    $client = [string] (Get-CodexFinishProperty -InputObject $Event -Name 'client')
    $key = $client + [Environment]::NewLine + $threadId + [Environment]::NewLine + $turnId
    return Get-CodexFinishSha256Hex -Value $key
}

function Get-CodexFinishSha256Hex {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Value
    )

    $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash($bytes)
        return -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-CodexFinishThreadHash {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Event
    )

    # Hook payloads call this identity session_id; notify calls it thread-id.
    # Hash only that stable identity so cwd changes and client metadata cannot
    # split one lifecycle across unrelated state files.
    $threadId = [string] (Get-CodexFinishProperty -InputObject $Event -Name 'thread-id')
    if ([string]::IsNullOrWhiteSpace($threadId)) {
        $threadId = [string] (Get-CodexFinishProperty -InputObject $Event -Name 'session_id')
    }
    if ([string]::IsNullOrWhiteSpace($threadId)) {
        return $null
    }

    return Get-CodexFinishSha256Hex -Value $threadId
}

function Resolve-CodexFinishStateDirectory {
    param(
        [string] $StateDirectory
    )

    if (-not [string]::IsNullOrWhiteSpace($StateDirectory)) {
        return [IO.Path]::GetFullPath($StateDirectory)
    }

    $pluginData = [Environment]::GetEnvironmentVariable('PLUGIN_DATA')
    if (-not [string]::IsNullOrWhiteSpace($pluginData)) {
        return [IO.Path]::GetFullPath((Join-Path $pluginData 'state'))
    }

    $userProfilePath = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    return [IO.Path]::GetFullPath((Join-Path $userProfilePath '.codex\codex-finish-shout-state'))
}

function Resolve-CodexFinishThreadStatePaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Event,
        [string] $StateDirectory
    )

    $threadHash = Get-CodexFinishThreadHash -Event $Event
    if ([string]::IsNullOrWhiteSpace($threadHash)) {
        return $null
    }

    $resolvedState = Resolve-CodexFinishStateDirectory -StateDirectory $StateDirectory
    $null = [IO.Directory]::CreateDirectory($resolvedState)
    return [pscustomobject] [ordered] @{
        StateDirectory = $resolvedState
        ThreadHash     = $threadHash
        PendingPath    = Join-Path $resolvedState ($threadHash + '.pending.json')
        LifecyclePath  = Join-Path $resolvedState ($threadHash + '.lifecycle.json')
        LockPath       = Join-Path $resolvedState ($threadHash + '.state.lock')
    }
}

function Open-CodexFinishStateLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [ValidateRange(1, 60)]
        [int] $TimeoutSeconds = 10,
        [ValidateRange(0, 60000)]
        [int] $TimeoutMilliseconds = 0
    )

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $parentPath = [IO.Path]::GetDirectoryName($resolvedPath)
    $null = [IO.Directory]::CreateDirectory($parentPath)
    $timeout = if ($TimeoutMilliseconds -gt 0) {
        [TimeSpan]::FromMilliseconds($TimeoutMilliseconds)
    }
    else {
        [TimeSpan]::FromSeconds($TimeoutSeconds)
    }
    $deadline = [DateTime]::UtcNow.Add($timeout)

    do {
        try {
            return [IO.File]::Open(
                $resolvedPath,
                [IO.FileMode]::OpenOrCreate,
                [IO.FileAccess]::ReadWrite,
                [IO.FileShare]::None
            )
        }
        catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) {
                return $null
            }
            Start-Sleep -Milliseconds 50
        }
        catch {
            return $null
        }
    } while ([DateTime]::UtcNow -lt $deadline)

    return $null
}

function Resolve-CodexFinishProjectSettleStatePaths {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Event,
        [string] $StateDirectory
    )

    $projectKey = Get-CodexFinishProjectKey -Event $Event
    if ([string]::IsNullOrWhiteSpace($projectKey)) {
        return $null
    }

    $resolvedState = Resolve-CodexFinishStateDirectory -StateDirectory $StateDirectory
    $null = [IO.Directory]::CreateDirectory($resolvedState)
    $baseName = 'project-' + $projectKey + '.settle'
    return [pscustomobject] [ordered] @{
        StateDirectory = $resolvedState
        ProjectKey     = $projectKey
        StatePath      = Join-Path $resolvedState ($baseName + '.json')
        LockPath       = Join-Path $resolvedState ($baseName + '.lock')
    }
}

function Read-CodexFinishProjectSettleState {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if (-not [IO.File]::Exists($Path)) {
        return $null
    }

    try {
        return [IO.File]::ReadAllText($Path) | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Write-CodexFinishProjectActivityMarker {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Event,
        [Parameter(Mandatory = $true)]
        [string] $ActivityName,
        [string] $StateDirectory
    )

    $paths = Resolve-CodexFinishProjectSettleStatePaths `
        -Event $Event `
        -StateDirectory $StateDirectory
    if ($null -eq $paths) {
        return [pscustomobject]@{ Written = $false; Reason = 'invalid-project-identity' }
    }
    $observedUtc = [DateTime]::UtcNow.ToString('o')
    $markerPath = Join-Path $paths.StateDirectory (
        'project-' + $paths.ProjectKey + '.activity.' + [Guid]::NewGuid().ToString('N') + '.json'
    )
    try {
        # The unique marker deliberately requires no shared lock. It is the
        # fail-closed signal when a completion confirmation currently owns the
        # settle lock longer than the Hook's 250 ms budget.
        $record = [ordered]@{
            schemaVersion = 1
            projectKey    = $paths.ProjectKey
            activityName  = $ActivityName
            observedUtc   = $observedUtc
            threadHash    = Get-CodexFinishThreadHash -Event $Event
        }
        Write-CodexFinishUtf8File `
            -Path $markerPath `
            -Content (($record | ConvertTo-Json -Depth 4) + [Environment]::NewLine)
        return [pscustomobject]@{
            Written = $true; Reason = 'activity-marker-written'; Path = $markerPath; ObservedUtc = $observedUtc
        }
    }
    catch {
        return [pscustomobject]@{ Written = $false; Reason = 'activity-marker-write-failed' }
    }
}

function Test-CodexFinishProjectActivityAfterCandidate {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Event,
        [Parameter(Mandatory = $true)]
        [object] $PendingState,
        [Parameter(Mandatory = $true)]
        [string] $StateDirectory
    )

    $projectKey = Get-CodexFinishProjectKey -Event $Event
    $candidateObservedUtc = ConvertFrom-CodexFinishUtcText (
        Get-CodexFinishProperty -InputObject $PendingState -Name 'candidateObservedUtc'
    )
    if ($candidateObservedUtc -eq [DateTime]::MinValue) {
        return [pscustomobject]@{ ActivityObserved = $true; Reason = 'candidate-time-invalid' }
    }

    try {
        $pattern = 'project-' + $projectKey + '.activity.*.json'
        foreach ($markerPath in @([IO.Directory]::EnumerateFiles($StateDirectory, $pattern))) {
            $markerObservedUtc = [DateTime]::MinValue
            try {
                $marker = [IO.File]::ReadAllText($markerPath) | ConvertFrom-Json -ErrorAction Stop
                $markerObservedUtc = ConvertFrom-CodexFinishUtcText (
                    Get-CodexFinishProperty -InputObject $marker -Name 'observedUtc'
                )
            }
            catch {
                # A marker that is still being atomically replaced is checked
                # again by the post-finalization scan below.
                continue
            }
            if (
                $markerObservedUtc -lt [DateTime]::UtcNow.AddHours(-24) -or
                $markerObservedUtc -lt $candidateObservedUtc
            ) {
                try {
                    [IO.File]::Delete($markerPath)
                }
                catch {
                    # Marker cleanup is best effort.
                }
                continue
            }
            if ($markerObservedUtc -ge $candidateObservedUtc) {
                return [pscustomobject]@{
                    ActivityObserved = $true
                    Reason           = 'project-activity-marker-after-candidate'
                    MarkerPath       = $markerPath
                    ObservedUtc      = $markerObservedUtc.ToString('o')
                }
            }
        }
        return [pscustomobject]@{ ActivityObserved = $false; Reason = 'no-new-project-activity-marker' }
    }
    catch {
        # Failing closed is safer than announcing while project activity cannot
        # be audited.
        return [pscustomobject]@{ ActivityObserved = $true; Reason = 'project-activity-marker-scan-failed' }
    }
}

function Invalidate-CodexFinishProjectPendingCandidate {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Event,
        [Parameter(Mandatory = $true)]
        [string] $ActivityName,
        [string] $StateDirectory,
        [ValidateRange(50, 60000)]
        [int] $LockTimeoutMilliseconds = 10000
    )

    $activityMarker = Write-CodexFinishProjectActivityMarker `
        -Event $Event `
        -ActivityName $ActivityName `
        -StateDirectory $StateDirectory

    $paths = Resolve-CodexFinishProjectSettleStatePaths `
        -Event $Event `
        -StateDirectory $StateDirectory
    if ($null -eq $paths) {
        return [pscustomobject]@{
            Updated = $false; Reason = 'invalid-project-identity'; CandidateInvalidated = $false
        }
    }

    $lockStream = Open-CodexFinishStateLock `
        -Path $paths.LockPath `
        -TimeoutMilliseconds $LockTimeoutMilliseconds
    if ($null -eq $lockStream) {
        return [pscustomobject]@{
            Updated = $false; Reason = 'project-settle-lock-unavailable'; CandidateInvalidated = $false
        }
    }

    try {
        $existing = Read-CodexFinishProjectSettleState -Path $paths.StatePath
        $revision = 0
        if ($null -ne $existing) {
            try {
                $revision = [Math]::Max(
                    0,
                    [int](Get-CodexFinishProperty -InputObject $existing -Name 'activityRevision' -DefaultValue 0)
                )
            }
            catch {
                $revision = 0
            }
        }
        $invalidatedCandidateId = [string](
            Get-CodexFinishProperty -InputObject $existing -Name 'candidateId'
        )
        $now = [DateTime]::UtcNow.ToString('o')
        $record = [ordered]@{
            schemaVersion              = 1
            projectKey                 = $paths.ProjectKey
            activityRevision           = $revision + 1
            lastActivityName           = $ActivityName
            lastActivityUtc            = $now
            lastInvalidatedCandidateId = $invalidatedCandidateId
            candidateId                = $null
            candidateThreadHash        = $null
            candidateTurnHash          = $null
            candidateTurnId            = $null
            candidateObservedUtc       = $null
            candidateActivityRevision  = $null
            candidateLifecycleGuardUsed = $null
            candidateAuthoritativeRootNotify = $null
            # Preserve the last committed identity across later activity.  It
            # does not block a newer observed turn, but prevents SessionEnd
            # recovery from re-claiming an older already-announced turn.
            lastClaimedCandidateId      = Get-CodexFinishProperty -InputObject $existing -Name 'lastClaimedCandidateId'
            lastClaimedThreadHash       = Get-CodexFinishProperty -InputObject $existing -Name 'lastClaimedThreadHash'
            lastClaimedTurnHash         = Get-CodexFinishProperty -InputObject $existing -Name 'lastClaimedTurnHash'
            lastClaimedTurnId           = Get-CodexFinishProperty -InputObject $existing -Name 'lastClaimedTurnId'
            lastClaimedUtc              = Get-CodexFinishProperty -InputObject $existing -Name 'lastClaimedUtc'
            updatedUtc                 = $now
        }
        Write-CodexFinishUtf8File `
            -Path $paths.StatePath `
            -Content (($record | ConvertTo-Json -Depth 5) + [Environment]::NewLine)
        $markerRetained = [bool]$activityMarker.Written
        if ($activityMarker.Written -and [IO.File]::Exists([string]$activityMarker.Path)) {
            try {
                # This activity is now durably folded into activityRevision.
                # Delete only its own marker: another lock-free Hook may have
                # written a marker while waiting for this project lock.
                [IO.File]::Delete([string]$activityMarker.Path)
                $markerRetained = $false
            }
            catch {
                # The redundant marker remains safe and is pruned by a later
                # candidate scan.
            }
        }
        return [pscustomobject]@{
            Updated              = $true
            Reason               = 'project-activity-recorded'
            CandidateInvalidated = -not [string]::IsNullOrWhiteSpace($invalidatedCandidateId)
            ActivityRevision     = $record.activityRevision
            ActivityMarkerWritten = [bool]$activityMarker.Written
            ActivityMarkerRetained = $markerRetained
        }
    }
    catch {
        return [pscustomobject]@{
            Updated = $false; Reason = 'project-activity-write-failed'; CandidateInvalidated = $false
        }
    }
    finally {
        $lockStream.Dispose()
    }
}

function Register-CodexFinishProjectPendingCandidate {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Event,
        [Parameter(Mandatory = $true)]
        [string] $CandidateId,
        [Parameter(Mandatory = $true)]
        [string] $ObservedUtc,
        [bool] $LifecycleGuardUsed,
        [bool] $AuthoritativeRootNotify,
        [string] $StateDirectory,
        [switch] $OnlyIfVacant
    )

    $paths = Resolve-CodexFinishProjectSettleStatePaths `
        -Event $Event `
        -StateDirectory $StateDirectory
    if ($null -eq $paths) {
        return [pscustomobject]@{ Recorded = $false; Reason = 'invalid-project-identity' }
    }

    $lockStream = Open-CodexFinishStateLock -Path $paths.LockPath
    if ($null -eq $lockStream) {
        return [pscustomobject]@{ Recorded = $false; Reason = 'project-settle-lock-unavailable' }
    }

    try {
        $existing = Read-CodexFinishProjectSettleState -Path $paths.StatePath
        $candidateObserved = ConvertFrom-CodexFinishUtcText $ObservedUtc
        if ($candidateObserved -eq [DateTime]::MinValue) {
            return [pscustomobject]@{ Recorded = $false; Reason = 'candidate-time-invalid' }
        }

        # The observation timestamp is taken before the caller waits for this
        # project lock. Activity can therefore acquire the lock first, fold its
        # marker into the revision, and delete the marker before this candidate
        # arrives. Never adopt that newer revision as the candidate baseline.
        $lastActivity = ConvertFrom-CodexFinishUtcText (
            Get-CodexFinishProperty -InputObject $existing -Name 'lastActivityUtc'
        )
        if ($lastActivity -ne [DateTime]::MinValue -and $lastActivity -ge $candidateObserved) {
            return [pscustomobject]@{
                Recorded = $false; Reason = 'project-activity-after-candidate'
            }
        }

        if ($OnlyIfVacant) {
            $currentCandidateId = [string](
                Get-CodexFinishProperty -InputObject $existing -Name 'candidateId'
            )
            $currentCandidateObserved = ConvertFrom-CodexFinishUtcText (
                Get-CodexFinishProperty -InputObject $existing -Name 'candidateObservedUtc'
            )
            if (
                -not [string]::IsNullOrWhiteSpace($currentCandidateId) -and
                $currentCandidateObserved -ge [DateTime]::UtcNow.AddMinutes(-5)
            ) {
                return [pscustomobject]@{
                    Recorded = $false; Reason = 'project-candidate-already-pending'
                }
            }
            $lastClaimed = ConvertFrom-CodexFinishUtcText (
                Get-CodexFinishProperty -InputObject $existing -Name 'lastClaimedUtc'
            )
            if ($lastClaimed -ne [DateTime]::MinValue -and $lastClaimed -ge $candidateObserved) {
                return [pscustomobject]@{
                    Recorded = $false; Reason = 'project-already-claimed'
                }
            }
        }

        $activityRevision = 0
        if ($null -ne $existing) {
            try {
                $activityRevision = [Math]::Max(
                    0,
                    [int](Get-CodexFinishProperty -InputObject $existing -Name 'activityRevision' -DefaultValue 0)
                )
            }
            catch {
                $activityRevision = 0
            }
        }
        $record = [ordered]@{
            schemaVersion              = 1
            projectKey                 = $paths.ProjectKey
            activityRevision           = $activityRevision
            lastActivityName           = Get-CodexFinishProperty -InputObject $existing -Name 'lastActivityName'
            lastActivityUtc            = Get-CodexFinishProperty -InputObject $existing -Name 'lastActivityUtc'
            lastInvalidatedCandidateId = $null
            candidateId                = $CandidateId
            candidateThreadHash        = Get-CodexFinishThreadHash -Event $Event
            candidateTurnHash          = Get-CodexFinishTurnHash -Event $Event
            candidateTurnId            = [string](Get-CodexFinishProperty -InputObject $Event -Name 'turn-id')
            candidateObservedUtc       = $ObservedUtc
            candidateActivityRevision  = $activityRevision
            candidateLifecycleGuardUsed = $LifecycleGuardUsed
            candidateAuthoritativeRootNotify = $AuthoritativeRootNotify
            lastClaimedCandidateId      = Get-CodexFinishProperty -InputObject $existing -Name 'lastClaimedCandidateId'
            lastClaimedThreadHash       = Get-CodexFinishProperty -InputObject $existing -Name 'lastClaimedThreadHash'
            lastClaimedTurnHash         = Get-CodexFinishProperty -InputObject $existing -Name 'lastClaimedTurnHash'
            lastClaimedTurnId           = Get-CodexFinishProperty -InputObject $existing -Name 'lastClaimedTurnId'
            lastClaimedUtc              = Get-CodexFinishProperty -InputObject $existing -Name 'lastClaimedUtc'
            updatedUtc                 = [DateTime]::UtcNow.ToString('o')
        }
        Write-CodexFinishUtf8File `
            -Path $paths.StatePath `
            -Content (($record | ConvertTo-Json -Depth 5) + [Environment]::NewLine)
        return [pscustomobject]@{
            Recorded         = $true
            Reason           = 'project-candidate-recorded'
            ProjectKey       = $paths.ProjectKey
            ActivityRevision = $activityRevision
        }
    }
    catch {
        return [pscustomobject]@{ Recorded = $false; Reason = 'project-candidate-write-failed' }
    }
    finally {
        $lockStream.Dispose()
    }
}

function Test-CodexFinishProjectHasPendingCandidate {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Event,
        [string] $StateDirectory,
        [ValidateRange(1, 60)]
        [int] $MaximumAgeMinutes = 5
    )

    $paths = Resolve-CodexFinishProjectSettleStatePaths `
        -Event $Event `
        -StateDirectory $StateDirectory
    if ($null -eq $paths) {
        return $false
    }
    $lockStream = Open-CodexFinishStateLock -Path $paths.LockPath -TimeoutMilliseconds 250
    if ($null -eq $lockStream) {
        # A short-lived lock holder is registering or confirming a candidate.
        # Staying red is the safe presentation until that operation completes.
        return $true
    }
    try {
        $state = Read-CodexFinishProjectSettleState -Path $paths.StatePath
        $candidateId = [string](Get-CodexFinishProperty -InputObject $state -Name 'candidateId')
        if ([string]::IsNullOrWhiteSpace($candidateId)) {
            return $false
        }
        $observed = ConvertFrom-CodexFinishUtcText (
            Get-CodexFinishProperty -InputObject $state -Name 'candidateObservedUtc'
        )
        return $observed -ge [DateTime]::UtcNow.AddMinutes(-1 * $MaximumAgeMinutes)
    }
    finally {
        $lockStream.Dispose()
    }
}

function Test-CodexFinishProjectTurnAlreadyClaimed {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Event,
        [string] $StateDirectory,
        [ValidateRange(50, 60000)]
        [int] $LockTimeoutMilliseconds = 250
    )

    $paths = Resolve-CodexFinishProjectSettleStatePaths `
        -Event $Event `
        -StateDirectory $StateDirectory
    if ($null -eq $paths) {
        return [pscustomobject]@{ Matched = $false; LockAcquired = $false; Reason = 'invalid-project-identity' }
    }
    $lockStream = Open-CodexFinishStateLock `
        -Path $paths.LockPath `
        -TimeoutMilliseconds $LockTimeoutMilliseconds
    if ($null -eq $lockStream) {
        return [pscustomobject]@{ Matched = $false; LockAcquired = $false; Reason = 'project-settle-lock-unavailable' }
    }
    try {
        $state = Read-CodexFinishProjectSettleState -Path $paths.StatePath
        $threadHash = Get-CodexFinishThreadHash -Event $Event
        $turnId = [string](Get-CodexFinishProperty -InputObject $Event -Name 'turn-id')
        if ([string]::IsNullOrWhiteSpace($turnId)) {
            $turnId = [string](Get-CodexFinishProperty -InputObject $Event -Name 'turn_id')
        }
        $claimedThreadHash = [string](
            Get-CodexFinishProperty -InputObject $state -Name 'lastClaimedThreadHash'
        )
        $claimedTurnId = [string](
            Get-CodexFinishProperty -InputObject $state -Name 'lastClaimedTurnId'
        )
        $matched = (
            -not [string]::IsNullOrWhiteSpace($threadHash) -and
            -not [string]::IsNullOrWhiteSpace($turnId) -and
            $claimedThreadHash -ceq $threadHash -and
            $claimedTurnId -ceq $turnId
        )

        # Upgrade compatibility for a settle record written before the
        # explicit thread/turn fields were added.
        if (-not $matched -and [string]::IsNullOrWhiteSpace($claimedTurnId)) {
            $normalizedEvent = [pscustomobject]@{
                client      = 'VS Code'
                'thread-id' = [string](Get-CodexFinishProperty -InputObject $Event -Name 'session_id')
                'turn-id'   = $turnId
                cwd         = [string](Get-CodexFinishProperty -InputObject $Event -Name 'cwd')
            }
            if ([string]::IsNullOrWhiteSpace([string]$normalizedEvent.'thread-id')) {
                $normalizedEvent.'thread-id' = [string](
                    Get-CodexFinishProperty -InputObject $Event -Name 'thread-id'
                )
            }
            $matched = (
                [string](Get-CodexFinishProperty -InputObject $state -Name 'lastClaimedTurnHash') -ceq
                (Get-CodexFinishTurnHash -Event $normalizedEvent)
            )
        }
        return [pscustomobject]@{ Matched = $matched; LockAcquired = $true; Reason = 'checked' }
    }
    finally {
        $lockStream.Dispose()
    }
}

function Test-CodexFinishProjectSessionsIdle {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Event,
        [Parameter(Mandatory = $true)]
        [object] $PendingState,
        [Parameter(Mandatory = $true)]
        [string] $StateDirectory,
        [ValidateRange(1, 24)]
        [int] $RunningStaleHours = 6
    )

    $projectKey = Get-CodexFinishProjectKey -Event $Event
    $candidateThreadHash = [string](
        Get-CodexFinishProperty -InputObject $PendingState -Name 'candidateThreadHash'
    )
    $guardUsed = ConvertTo-CodexFinishBoolean `
        -Value (Get-CodexFinishProperty `
            -InputObject $PendingState `
            -Name 'candidateLifecycleGuardUsed' `
            -DefaultValue $false) `
        -DefaultValue $false
    $authoritativeRootNotify = ConvertTo-CodexFinishBoolean `
        -Value (Get-CodexFinishProperty `
            -InputObject $PendingState `
            -Name 'candidateAuthoritativeRootNotify' `
            -DefaultValue $false) `
        -DefaultValue $false
    $candidateTurnId = [string](
        Get-CodexFinishProperty -InputObject $PendingState -Name 'candidateTurnId'
    )
    $idleLifecycleThreads = @{}
    $runningCutoff = [DateTime]::UtcNow.AddHours(-1 * $RunningStaleHours)

    foreach ($lifecyclePath in @([IO.Directory]::EnumerateFiles($StateDirectory, '*.lifecycle.json'))) {
        $lifecycle = Read-CodexFinishLifecycleState -Path $lifecyclePath
        if ($null -eq $lifecycle) {
            continue
        }
        if ([string](Get-CodexFinishProperty -InputObject $lifecycle -Name 'rootStatus') -ceq 'ended') {
            continue
        }
        $lifecycleEvent = [pscustomobject]@{
            cwd        = [string](Get-CodexFinishProperty -InputObject $lifecycle -Name 'cwd')
            session_id = [string](Get-CodexFinishProperty -InputObject $lifecycle -Name 'sessionId')
        }
        if ((Get-CodexFinishProjectKey -Event $lifecycleEvent) -cne $projectKey) {
            continue
        }
        $updatedUtc = ConvertFrom-CodexFinishUtcText (
            Get-CodexFinishProperty -InputObject $lifecycle -Name 'updatedUtc'
        )
        if ($updatedUtc -lt $runningCutoff) {
            continue
        }
        $threadHash = [string](
            Get-CodexFinishProperty -InputObject $lifecycle -Name 'threadHash'
        )
        if ([string]::IsNullOrWhiteSpace($threadHash)) {
            $threadHash = Get-CodexFinishThreadHash -Event $lifecycleEvent
        }
        $candidateAuthoritativeSession = (
            $authoritativeRootNotify -and
            $threadHash -ceq $candidateThreadHash -and
            [string](Get-CodexFinishProperty -InputObject $lifecycle -Name 'currentTurnId') -ceq $candidateTurnId
        )
        if ($candidateAuthoritativeSession) {
            # A matching root notify is the completion boundary for its own
            # turn. Reusable child identities can remain in lifecycle state
            # without representing queued/running work. Any later child Hook
            # still invalidates the candidate through the activity marker.
            if (-not [string]::IsNullOrWhiteSpace($threadHash)) {
                $idleLifecycleThreads[$threadHash] = $true
            }
            continue
        }
        $activeSubagents = @(Get-CodexFinishActiveSubagentIds -LifecycleState $lifecycle)
        if ($activeSubagents.Count -gt 0) {
            return [pscustomobject]@{
                Idle = $false; Reason = 'project-subagent-still-active'; ThreadHash = $threadHash
            }
        }
        if ([string](Get-CodexFinishProperty -InputObject $lifecycle -Name 'rootStatus') -cne 'stopped') {
            return [pscustomobject]@{
                Idle = $false; Reason = 'project-session-still-running'; ThreadHash = $threadHash
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($threadHash)) {
            $idleLifecycleThreads[$threadHash] = $true
        }
    }

    $monitor = Get-CodexFinishProjectMonitorState -StateDirectory $StateDirectory
    $project = @(
        @(Get-CodexFinishProperty -InputObject $monitor -Name 'projects' -DefaultValue @()) |
            Where-Object { [string]$_.projectKey -ceq $projectKey }
    ) | Select-Object -First 1
    if ($null -ne $project) {
        foreach ($session in @(
            Get-CodexFinishProperty -InputObject $project -Name 'sessions' -DefaultValue @()
        )) {
            if ([string]$session.status -cne 'running') {
                continue
            }
            $threadHash = [string]$session.threadHash
            if ($idleLifecycleThreads.ContainsKey($threadHash)) {
                # This is the externally red settling representation of a
                # lifecycle session that is logically stopped.
                continue
            }
            if (-not $guardUsed -and $threadHash -ceq $candidateThreadHash) {
                # prefer/off mode can legitimately have no lifecycle file for
                # the candidate's own session. Other running sessions still
                # fail closed.
                continue
            }
            return [pscustomobject]@{
                Idle = $false; Reason = 'project-session-still-running'; ThreadHash = $threadHash
            }
        }
    }

    return [pscustomobject]@{ Idle = $true; Reason = 'project-idle'; ThreadHash = $null }
}

function Confirm-CodexFinishProjectPendingCandidate {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Event,
        [Parameter(Mandatory = $true)]
        [string] $CandidateId,
        [string] $StateDirectory
    )

    $paths = Resolve-CodexFinishProjectSettleStatePaths `
        -Event $Event `
        -StateDirectory $StateDirectory
    if ($null -eq $paths) {
        return [pscustomobject]@{ Claimed = $false; Reason = 'invalid-project-identity' }
    }
    $lockStream = Open-CodexFinishStateLock -Path $paths.LockPath
    if ($null -eq $lockStream) {
        return [pscustomobject]@{ Claimed = $false; Reason = 'project-settle-lock-unavailable' }
    }

    $monitorFinalized = $false
    $claimCommitted = $false
    try {
        $state = Read-CodexFinishProjectSettleState -Path $paths.StatePath
        if ($null -eq $state) {
            return [pscustomobject]@{ Claimed = $false; Reason = 'project-candidate-missing' }
        }
        $currentCandidateId = [string](Get-CodexFinishProperty -InputObject $state -Name 'candidateId')
        if ($currentCandidateId -cne $CandidateId) {
            $invalidatedCandidateId = [string](
                Get-CodexFinishProperty -InputObject $state -Name 'lastInvalidatedCandidateId'
            )
            $reason = if ($invalidatedCandidateId -ceq $CandidateId) {
                'project-activity-after-candidate'
            }
            elseif ([string]::IsNullOrWhiteSpace($currentCandidateId)) {
                'project-candidate-missing'
            }
            else {
                'project-candidate-superseded'
            }
            return [pscustomobject]@{ Claimed = $false; Reason = $reason }
        }
        if (
            [string](Get-CodexFinishProperty -InputObject $state -Name 'candidateTurnHash') -cne
            (Get-CodexFinishTurnHash -Event $Event)
        ) {
            return [pscustomobject]@{ Claimed = $false; Reason = 'project-candidate-turn-mismatch' }
        }
        if (
            [int](Get-CodexFinishProperty -InputObject $state -Name 'candidateActivityRevision' -DefaultValue -1) -ne
            [int](Get-CodexFinishProperty -InputObject $state -Name 'activityRevision' -DefaultValue 0)
        ) {
            return [pscustomobject]@{ Claimed = $false; Reason = 'project-activity-after-candidate' }
        }

        $activityCheck = Test-CodexFinishProjectActivityAfterCandidate `
            -Event $Event `
            -PendingState $state `
            -StateDirectory $paths.StateDirectory
        if ($activityCheck.ActivityObserved) {
            return [pscustomobject]@{
                Claimed = $false
                Reason = 'project-activity-after-candidate'
                ActivityReason = $activityCheck.Reason
            }
        }

        $idleResult = Test-CodexFinishProjectSessionsIdle `
            -Event $Event `
            -PendingState $state `
            -StateDirectory $paths.StateDirectory
        if (-not $idleResult.Idle) {
            return [pscustomobject]@{
                Claimed = $false; Reason = $idleResult.Reason; RunningThreadHash = $idleResult.ThreadHash
            }
        }

        # A notify/Stop worker sleeps outside all locks.  The VS Code window
        # may close during that quiet period, so re-check the live workspace
        # lease at the final claim boundary.  PID + process-start validation in
        # the lease reader preserves this through machine sleep while rejecting
        # dead/reused window processes.
        $leaseState = Get-CodexFinishWorkspaceLeaseState `
            -StateDirectory $paths.StateDirectory `
            -NowUtc ([DateTime]::UtcNow)
        if ($leaseState.Enabled) {
            $projectPath = Get-CodexFinishProjectPath -Event $Event
            $projectPresent = $false
            foreach ($workspacePath in @($leaseState.WorkspacePaths)) {
                if (Test-CodexFinishProjectInsideWorkspace `
                    -ProjectPath $projectPath `
                    -WorkspacePath $workspacePath
                ) {
                    $projectPresent = $true
                    break
                }
            }
            if (-not $projectPresent) {
                $revision = [int](Get-CodexFinishProperty `
                    -InputObject $state -Name 'activityRevision' -DefaultValue 0) + 1
                Set-CodexFinishProperty -InputObject $state -Name 'activityRevision' -Value $revision
                Set-CodexFinishProperty -InputObject $state -Name 'lastActivityName' -Value 'WorkspaceLeaseAbsent'
                Set-CodexFinishProperty -InputObject $state -Name 'lastActivityUtc' -Value ([DateTime]::UtcNow.ToString('o'))
                Set-CodexFinishProperty -InputObject $state -Name 'lastInvalidatedCandidateId' -Value $CandidateId
                foreach ($name in @(
                    'candidateId', 'candidateThreadHash', 'candidateTurnHash', 'candidateTurnId',
                    'candidateObservedUtc', 'candidateActivityRevision',
                    'candidateLifecycleGuardUsed', 'candidateAuthoritativeRootNotify'
                )) {
                    Set-CodexFinishProperty -InputObject $state -Name $name -Value $null
                }
                Set-CodexFinishProperty -InputObject $state -Name 'updatedUtc' -Value ([DateTime]::UtcNow.ToString('o'))
                Write-CodexFinishUtf8File `
                    -Path $paths.StatePath `
                    -Content (($state | ConvertTo-Json -Depth 5) + [Environment]::NewLine)
                return [pscustomobject]@{
                    Claimed = $false; Reason = 'project-not-present'; LeaseState = $leaseState
                }
            }
        }

        # Keep the project lock while publishing the completed aggregate. An
        # activity Hook invalidates under this same lock before it writes its
        # lifecycle/monitor state, so it cannot be overwritten by this sweep.
        $completedUtc = [DateTime]::UtcNow
        $monitorResult = Update-CodexFinishProjectMonitorState `
            -Event $Event `
            -Status completed `
            -StateDirectory $paths.StateDirectory `
            -NowUtc $completedUtc `
            -CompleteProject `
            -DisableRetry
        if (-not $monitorResult.Updated) {
            return [pscustomobject]@{
                Claimed = $false; Reason = 'project-monitor-finalize-failed'; MonitorReason = $monitorResult.Reason
            }
        }
        $monitorFinalized = $true


        # Activity markers are lock-free by design, so scan again after the
        # monitor write. A Hook that exhausted its 250 ms settle-lock budget is
        # still visible here and suppresses audio.
        $activityCheck = Test-CodexFinishProjectActivityAfterCandidate `
            -Event $Event `
            -PendingState $state `
            -StateDirectory $paths.StateDirectory
        if ($activityCheck.ActivityObserved) {
            $rollbackResult = Update-CodexFinishProjectMonitorState `
                -Event $Event `
                -Status running `
                -StateDirectory $paths.StateDirectory `
                -NowUtc ([DateTime]::UtcNow)
            return [pscustomobject]@{
                Claimed = $false
                Reason = 'project-activity-after-candidate'
                ActivityReason = $activityCheck.Reason
                MonitorRollbackUpdated = [bool]$rollbackResult.Updated
                MonitorRollbackRetryScheduled = [bool](
                    Get-CodexFinishProperty -InputObject $rollbackResult -Name 'RetryScheduled' -DefaultValue $false
                )
            }
        }

        $record = [ordered]@{
            schemaVersion              = 1
            projectKey                 = $paths.ProjectKey
            activityRevision           = [int](Get-CodexFinishProperty -InputObject $state -Name 'activityRevision' -DefaultValue 0)
            lastActivityName           = Get-CodexFinishProperty -InputObject $state -Name 'lastActivityName'
            lastActivityUtc            = Get-CodexFinishProperty -InputObject $state -Name 'lastActivityUtc'
            lastInvalidatedCandidateId = $null
            candidateId                = $null
            candidateThreadHash        = $null
            candidateTurnHash          = $null
            candidateTurnId            = $null
            candidateObservedUtc       = $null
            candidateActivityRevision  = $null
            candidateLifecycleGuardUsed = $null
            candidateAuthoritativeRootNotify = $null
            lastClaimedCandidateId      = $CandidateId
            lastClaimedThreadHash       = Get-CodexFinishThreadHash -Event $Event
            lastClaimedTurnHash         = Get-CodexFinishTurnHash -Event $Event
            lastClaimedTurnId           = [string](Get-CodexFinishProperty -InputObject $Event -Name 'turn-id')
            lastClaimedUtc              = $completedUtc.ToString('o')
            updatedUtc                 = $completedUtc.ToString('o')
        }
        Write-CodexFinishUtf8File `
            -Path $paths.StatePath `
            -Content (($record | ConvertTo-Json -Depth 5) + [Environment]::NewLine)
        $claimCommitted = $true
        return [pscustomobject]@{
            Claimed             = $true
            Reason              = 'project-claimed'
            ProjectKey          = $paths.ProjectKey
            ProjectMonitorState = $monitorResult.State
        }
    }
    catch {
        $rollbackResult = $null
        if ($monitorFinalized -and -not $claimCommitted) {
            # The aggregate cannot remain green unless the settle claim was
            # durably committed. A retry marker makes the fail-closed rollback
            # recoverable even when the monitor lock is briefly unavailable.
            $rollbackResult = Update-CodexFinishProjectMonitorState `
                -Event $Event `
                -Status running `
                -StateDirectory $paths.StateDirectory `
                -NowUtc ([DateTime]::UtcNow)
        }
        return [pscustomobject]@{
            Claimed = $false
            Reason = 'project-candidate-confirm-failed'
            MonitorRollbackUpdated = [bool]($null -ne $rollbackResult -and $rollbackResult.Updated)
            MonitorRollbackRetryScheduled = [bool](
                $null -ne $rollbackResult -and
                (Get-CodexFinishProperty -InputObject $rollbackResult -Name 'RetryScheduled' -DefaultValue $false)
            )
        }
    }
    finally {
        $lockStream.Dispose()
    }
}

function Invoke-CodexFinishStoppedProjectSettlement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object] $HookEvent,
        [string] $StateDirectory,
        [string] $ConfigPath,
        [Parameter(Mandatory = $true)]
        [string] $ObservedUtc,
        [switch] $SkipAudio,
        [switch] $SkipOverlay
    )

    $threadId = [string](Get-CodexFinishProperty -InputObject $HookEvent -Name 'session_id')
    if ([string]::IsNullOrWhiteSpace($threadId)) {
        $threadId = [string](Get-CodexFinishProperty -InputObject $HookEvent -Name 'thread-id')
    }
    $turnId = [string](Get-CodexFinishProperty -InputObject $HookEvent -Name 'turn_id')
    if ([string]::IsNullOrWhiteSpace($turnId)) {
        $turnId = [string](Get-CodexFinishProperty -InputObject $HookEvent -Name 'turn-id')
    }
    if ((ConvertFrom-CodexFinishUtcText $ObservedUtc) -eq [DateTime]::MinValue) {
        return [pscustomobject]@{ Claimed = $false; SuppressedReason = 'candidate-time-invalid' }
    }
    $event = [pscustomobject]@{
        type                     = 'agent-turn-complete'
        client                   = 'VS Code'
        'thread-id'              = $threadId
        'turn-id'                = $turnId
        cwd                      = [string](Get-CodexFinishProperty -InputObject $HookEvent -Name 'cwd')
        'last-assistant-message' = 'stop-only-fallback'
    }
    if (
        [string]::IsNullOrWhiteSpace($threadId) -or
        [string]::IsNullOrWhiteSpace($turnId) -or
        [string]::IsNullOrWhiteSpace([string]$event.cwd)
    ) {
        return [pscustomobject]@{ Claimed = $false; SuppressedReason = 'invalid-thread-state' }
    }
    $result = Invoke-CodexFinishNotification `
        -Event $event `
        -ConfigPath $ConfigPath `
        -StateDirectory $StateDirectory `
        -StopOnlyCandidate `
        -ObservedUtc $ObservedUtc `
        -CompletionGraceSeconds 0 `
        -SkipAudio:$SkipAudio `
        -SkipOverlay:$SkipOverlay
    $reason = if ($result.Claimed) { 'claimed' } else { [string]$result.SuppressedReason }
    $result | Add-Member -NotePropertyName Reason -NotePropertyValue $reason -Force
    return $result
}

function Start-CodexFinishStoppedProjectSettlement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object] $HookEvent,
        [string] $StateDirectory,
        [string] $ConfigPath,
        [ValidateRange(0, 120)]
        [int] $GraceSeconds = 10,
        [switch] $SkipAudio,
        [switch] $SkipOverlay
    )

    if (
        [string]::IsNullOrWhiteSpace($script:CodexFinishModulePath) -or
        -not [IO.File]::Exists($script:CodexFinishModulePath)
    ) {
        return $false
    }
    try {
        $resolvedState = Resolve-CodexFinishStateDirectory -StateDirectory $StateDirectory
        $workerEvent = [ordered]@{
            session_id = [string](Get-CodexFinishProperty -InputObject $HookEvent -Name 'session_id')
            turn_id    = [string](Get-CodexFinishProperty -InputObject $HookEvent -Name 'turn_id')
            cwd        = [string](Get-CodexFinishProperty -InputObject $HookEvent -Name 'cwd')
        }
        $envelope = [ordered]@{
            event          = $workerEvent
            stateDirectory = $resolvedState
            configPath     = [string]$ConfigPath
            observedUtc    = [DateTime]::UtcNow.ToString('o')
            graceSeconds   = $GraceSeconds
            skipAudio      = [bool]$SkipAudio
            skipOverlay    = [bool]$SkipOverlay
        }
        $envelopeBase64 = [Convert]::ToBase64String(
            [Text.Encoding]::UTF8.GetBytes(($envelope | ConvertTo-Json -Depth 5 -Compress))
        )
        $escapedModule = $script:CodexFinishModulePath.Replace("'", "''")
        $command = @"
`$ErrorActionPreference = 'SilentlyContinue'
`$json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$envelopeBase64'))
`$work = `$json | ConvertFrom-Json
Import-Module '$escapedModule' -Force
Wait-CodexFinishCompletionGracePeriod -Seconds ([int]`$work.graceSeconds)
`$event = [pscustomobject]@{
    type = 'agent-turn-complete'
    client = 'VS Code'
    'thread-id' = [string]`$work.event.session_id
    'turn-id' = [string]`$work.event.turn_id
    cwd = [string]`$work.event.cwd
    'last-assistant-message' = 'stop-only-fallback'
}
Invoke-CodexFinishNotification -Event `$event -ConfigPath ([string]`$work.configPath) -StateDirectory ([string]`$work.stateDirectory) -StopOnlyCandidate -ObservedUtc ([string]`$work.observedUtc) -CompletionGraceSeconds 0 -SkipAudio:([bool]`$work.skipAudio) -SkipOverlay:([bool]`$work.skipOverlay) | Out-Null
"@
        $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $powerShellPath = (Get-Command powershell.exe -ErrorAction Stop).Source
        $null = Start-Process `
            -FilePath $powerShellPath `
            -ArgumentList @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy',
                'Bypass', '-EncodedCommand', $encodedCommand
            ) `
            -WindowStyle Hidden
        return $true
    }
    catch {
        return $false
    }
}

function Read-CodexFinishLifecycleState {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if (-not [IO.File]::Exists($Path)) {
        return $null
    }

    try {
        return [IO.File]::ReadAllText($Path) | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function New-CodexFinishEmptyProjectMonitorState {
    param(
        [object] $UpdatedAtUtc = $null
    )

    return [pscustomobject] [ordered] @{
        schemaVersion = 1
        updatedAtUtc  = $UpdatedAtUtc
        total         = 0
        running       = 0
        completed     = 0
        projects      = [object[]] @()
    }
}

function Read-CodexFinishProjectMonitorFile {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if (-not [IO.File]::Exists($Path)) {
        return $null
    }
    try {
        $document = [IO.File]::ReadAllText($Path) | ConvertFrom-Json -ErrorAction Stop
        if ([int](Get-CodexFinishProperty -InputObject $document -Name 'schemaVersion' -DefaultValue 0) -ne 1) {
            return $null
        }
        return $document
    }
    catch {
        return $null
    }
}

function ConvertTo-CodexFinishNormalizedDirectoryPath {
    param(
        [object] $Path
    )

    if ([string]::IsNullOrWhiteSpace([string]$Path)) {
        return $null
    }
    try {
        $pathText = [string]$Path
        $fullPath = [IO.Path]::GetFullPath($pathText)
        # Runtime files produced by releases before stdin was decoded as UTF-8
        # can contain reversible UTF-8-as-GBK mojibake.  A lease is written by
        # VS Code with the real Unicode path, so repair the persisted path
        # before comparing it or recomputing its project key.  Requiring the
        # repaired directory to exist keeps legitimate GBK-looking names from
        # being guessed at.
        if (-not [IO.Directory]::Exists($fullPath)) {
            try {
                $gbk = [Text.Encoding]::GetEncoding(936)
                $repairedText = [Text.Encoding]::UTF8.GetString($gbk.GetBytes($pathText))
                if (-not $repairedText.Contains([char]0xFFFD)) {
                    $repairedPath = [IO.Path]::GetFullPath($repairedText)
                    if ([IO.Directory]::Exists($repairedPath)) {
                        $fullPath = $repairedPath
                    }
                }
            }
            catch {
                # Keep the original normalized value when it is not a
                # reversible legacy path.
            }
        }
        if ([IO.Path]::AltDirectorySeparatorChar -ne [IO.Path]::DirectorySeparatorChar) {
            $fullPath = $fullPath.Replace(
                [IO.Path]::AltDirectorySeparatorChar,
                [IO.Path]::DirectorySeparatorChar
            )
        }
        $root = [IO.Path]::GetPathRoot($fullPath)
        if (
            -not [string]::IsNullOrWhiteSpace($root) -and
            $fullPath.Length -gt $root.Length
        ) {
            $fullPath = $fullPath.TrimEnd([IO.Path]::DirectorySeparatorChar)
        }
        return $fullPath
    }
    catch {
        return $null
    }
}

function Test-CodexFinishProjectInsideWorkspace {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectPath,
        [Parameter(Mandatory = $true)]
        [string] $WorkspacePath
    )

    $project = ConvertTo-CodexFinishNormalizedDirectoryPath -Path $ProjectPath
    $workspace = ConvertTo-CodexFinishNormalizedDirectoryPath -Path $WorkspacePath
    if ([string]::IsNullOrWhiteSpace($project) -or [string]::IsNullOrWhiteSpace($workspace)) {
        return $false
    }
    if ($project.Equals($workspace, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    $workspacePrefix = $workspace
    if (-not $workspacePrefix.EndsWith([string][IO.Path]::DirectorySeparatorChar)) {
        $workspacePrefix += [IO.Path]::DirectorySeparatorChar
    }
    if ($project.StartsWith($workspacePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    # A VS Code workspace can point at a subfolder while Codex reports the
    # enclosing git root.  Treat that as the same open project, while keeping
    # the separator boundary so D:\foo never matches D:\foobar.
    $projectPrefix = $project
    if (-not $projectPrefix.EndsWith([string][IO.Path]::DirectorySeparatorChar)) {
        $projectPrefix += [IO.Path]::DirectorySeparatorChar
    }
    return $workspace.StartsWith($projectPrefix, [StringComparison]::OrdinalIgnoreCase)
}

function Get-CodexFinishWorkspaceLeaseProcessDisposition {
    param(
        [object] $ProcessId,
        [object] $ProcessStartedUtc,
        [ValidateRange(0, 60)]
        [int] $StartTimeToleranceSeconds = 10
    )

    $numericProcessId = 0
    if (-not [int]::TryParse([string]$ProcessId, [ref]$numericProcessId) -or $numericProcessId -le 0) {
        return 'invalid'
    }
    $expectedStart = ConvertFrom-CodexFinishUtcText $ProcessStartedUtc
    if ($expectedStart -eq [DateTime]::MinValue) {
        return 'invalid'
    }

    try {
        $process = Get-Process -Id $numericProcessId -ErrorAction Stop
    }
    catch {
        if (
            [string]$_.FullyQualifiedErrorId -like 'NoProcessFoundForGivenId*' -or
            $_.Exception.Message -match 'Cannot find a process|no process'
        ) {
            return 'dead'
        }
        return 'unknown'
    }
    try {
        $actualStart = $process.StartTime.ToUniversalTime()
        if ([Math]::Abs(($actualStart - $expectedStart).TotalSeconds) -le $StartTimeToleranceSeconds) {
            return 'alive'
        }
        return 'reused'
    }
    catch {
        return 'unknown'
    }
}

function Test-CodexFinishWorkspaceLeaseProcess {
    param(
        [object] $ProcessId,
        [object] $ProcessStartedUtc,
        [ValidateRange(0, 60)]
        [int] $StartTimeToleranceSeconds = 10
    )

    return (Get-CodexFinishWorkspaceLeaseProcessDisposition `
        -ProcessId $ProcessId `
        -ProcessStartedUtc $ProcessStartedUtc `
        -StartTimeToleranceSeconds $StartTimeToleranceSeconds) -ceq 'alive'
}

function Remove-CodexFinishWorkspaceLeaseFileIfUnchanged {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [Parameter(Mandatory = $true)]
        [string] $ExpectedText,
        [Parameter(Mandatory = $true)]
        [long] $ExpectedWriteTicks,
        [Parameter(Mandatory = $true)]
        [long] $ExpectedLength,
        [scriptblock] $AfterQuarantineMove
    )

    $quarantinePath = Join-Path ([IO.Path]::GetDirectoryName($Path)) (
        '.workspace-lease-quarantine-' + [Guid]::NewGuid().ToString('N') + '.tmp'
    )
    try {
        # Rename first, then delete only the exact quarantined file.  A lease
        # atomically published before the rename is restored if it does not
        # match the stale fingerprint; one published after the rename remains
        # at the canonical path and can never be deleted by this cleanup.
        [IO.File]::Move($Path, $quarantinePath)
        if ($null -ne $AfterQuarantineMove) {
            & $AfterQuarantineMove $Path $quarantinePath
        }
        $verify = [IO.FileInfo]::new($quarantinePath)
        $verify.Refresh()
        $verifyText = [IO.File]::ReadAllText($quarantinePath)
        if (
            $verify.LastWriteTimeUtc.Ticks -ne $ExpectedWriteTicks -or
            $verify.Length -ne $ExpectedLength -or
            $verifyText -cne $ExpectedText
        ) {
            if (-not [IO.File]::Exists($Path)) {
                [IO.File]::Move($quarantinePath, $Path)
            }
            else {
                # Another heartbeat already recreated the canonical path.
                # Preserve this mismatched lease under the normal discovery
                # pattern; leaseId/updatedAt deduplication selects the newest.
                [IO.File]::Move(
                    $quarantinePath,
                    (Join-Path ([IO.Path]::GetDirectoryName($Path)) (
                        'workspace-lease-recovered-' + [Guid]::NewGuid().ToString('N') + '.json'
                    ))
                )
            }
            return $false
        }
        [IO.File]::Delete($quarantinePath)
        return -not [IO.File]::Exists($quarantinePath)
    }
    catch {
        if ([IO.File]::Exists($quarantinePath)) {
            try {
                if (-not [IO.File]::Exists($Path)) {
                    [IO.File]::Move($quarantinePath, $Path)
                }
                else {
                    [IO.File]::Move(
                        $quarantinePath,
                        (Join-Path ([IO.Path]::GetDirectoryName($Path)) (
                            'workspace-lease-recovered-' + [Guid]::NewGuid().ToString('N') + '.json'
                        ))
                    )
                }
            }
            catch {
                # Leave the quarantine file recoverable rather than deleting
                # bytes that might be a newly published heartbeat.
            }
        }
        return $false
    }
}

function Remove-CodexFinishExpiredWorkspaceLeases {
    [CmdletBinding()]
    param(
        [string] $StateDirectory,
        [ValidateRange(1, 3600)]
        [int] $LeaseTtlSeconds = 20,
        [ValidateRange(30, 86400)]
        [int] $MalformedMinimumAgeSeconds = 60,
        [ValidateRange(1, 1000)]
        [int] $MaximumRemovals = 128,
        [DateTime] $NowUtc = ([DateTime]::UtcNow)
    )

    if ($NowUtc.Kind -ne [DateTimeKind]::Utc) { $NowUtc = $NowUtc.ToUniversalTime() }
    $resolvedState = Resolve-CodexFinishStateDirectory -StateDirectory $StateDirectory
    $result = [ordered]@{ Scanned = 0; Removed = 0; Retained = 0; Errors = 0 }
    if (-not [IO.Directory]::Exists($resolvedState)) { return [pscustomobject]$result }

    foreach ($leasePath in @([IO.Directory]::EnumerateFiles($resolvedState, 'workspace-lease-*.json'))) {
        $result.Scanned++
        if ($result.Removed -ge $MaximumRemovals) { break }
        $initialText = $null
        $initialWriteTicks = 0L
        $initialLength = -1L
        $remove = $false
        try {
            $info = [IO.FileInfo]::new($leasePath)
            $info.Refresh()
            $initialWriteTicks = $info.LastWriteTimeUtc.Ticks
            $initialLength = $info.Length
            $initialText = [IO.File]::ReadAllText($leasePath)
            try {
                $lease = $initialText | ConvertFrom-Json -ErrorAction Stop
                if ([int](Get-CodexFinishProperty -InputObject $lease -Name 'schemaVersion' -DefaultValue 0) -ne 1) {
                    throw 'unsupported lease schema'
                }
                $updated = ConvertFrom-CodexFinishUtcText (
                    Get-CodexFinishProperty -InputObject $lease -Name 'updatedAtUtc'
                )
                if ($updated -eq [DateTime]::MinValue) { throw 'invalid lease timestamp' }
                if ($updated -ge $NowUtc.AddSeconds(-1 * $LeaseTtlSeconds)) {
                    $result.Retained++
                    continue
                }
                $disposition = Get-CodexFinishWorkspaceLeaseProcessDisposition `
                    -ProcessId (Get-CodexFinishProperty -InputObject $lease -Name 'processId') `
                    -ProcessStartedUtc (Get-CodexFinishProperty -InputObject $lease -Name 'processStartedUtc')
                if ($disposition -ceq 'alive' -or $disposition -ceq 'unknown') {
                    $result.Retained++
                    continue
                }
                $remove = $true
            }
            catch {
                # A malformed file may be in the middle of manual/legacy
                # replacement.  Only age it out well beyond a heartbeat TTL.
                $remove = $info.LastWriteTimeUtc -lt $NowUtc.AddSeconds(-1 * $MalformedMinimumAgeSeconds)
                if (-not $remove) { $result.Retained++ }
            }

            if ($remove) {
                # Re-read identity and bytes immediately before delete.  An
                # atomic heartbeat replacement changes at least content,
                # length, or LastWriteTime and is therefore retained.
                $deleted = Remove-CodexFinishWorkspaceLeaseFileIfUnchanged `
                    -Path $leasePath `
                    -ExpectedText $initialText `
                    -ExpectedWriteTicks $initialWriteTicks `
                    -ExpectedLength $initialLength
                if (-not $deleted) {
                    $result.Retained++
                    continue
                }
                $result.Removed++
            }
        }
        catch {
            $result.Errors++
        }
    }
    return [pscustomobject]$result
}

function Get-CodexFinishWorkspaceLeaseState {
    [CmdletBinding()]
    param(
        [string] $StateDirectory,
        [ValidateRange(1, 3600)]
        [int] $LeaseTtlSeconds = 20,
        [DateTime] $NowUtc = ([DateTime]::UtcNow)
    )

    if ($NowUtc.Kind -ne [DateTimeKind]::Utc) {
        $NowUtc = $NowUtc.ToUniversalTime()
    }
    $resolvedState = Resolve-CodexFinishStateDirectory -StateDirectory $StateDirectory
    $monitorPath = Join-Path $resolvedState 'workspace-monitor.json'
    $result = [ordered] @{
        Enabled          = $false
        Reason           = 'workspace-monitor-disabled'
        StateDirectory   = $resolvedState
        MonitorPath      = $monitorPath
        LeaseTtlSeconds  = $LeaseTtlSeconds
        LeaseFilesSeen   = 0
        ValidLeaseCount  = 0
        ValidLeases      = [object[]] @()
        WorkspacePaths   = [string[]] @()
        ObservedAtUtc    = $NowUtc.ToString('o')
    }

    $marker = Read-CodexFinishProjectMonitorFile -Path $monitorPath
    if ($null -eq $marker) {
        if ([IO.File]::Exists($monitorPath)) {
            $result.Reason = 'workspace-monitor-invalid'
        }
        return [pscustomobject]$result
    }
    $result.Enabled = $true
    $result.Reason = 'enabled'

    $validLeaseMap = @{}
    $workspaceMap = @{}
    if ([IO.Directory]::Exists($resolvedState)) {
        foreach ($leasePath in @([IO.Directory]::EnumerateFiles($resolvedState, 'workspace-lease-*.json'))) {
            $result.LeaseFilesSeen++
            try {
                $lease = [IO.File]::ReadAllText($leasePath) | ConvertFrom-Json -ErrorAction Stop
                if ([int](Get-CodexFinishProperty -InputObject $lease -Name 'schemaVersion' -DefaultValue 0) -ne 1) {
                    continue
                }
                $leaseId = [string](Get-CodexFinishProperty -InputObject $lease -Name 'leaseId')
                if ([string]::IsNullOrWhiteSpace($leaseId)) {
                    continue
                }
                $updatedUtc = ConvertFrom-CodexFinishUtcText (
                    Get-CodexFinishProperty -InputObject $lease -Name 'updatedAtUtc'
                )
                if ($updatedUtc -eq [DateTime]::MinValue) {
                    continue
                }
                $heartbeatFresh = $updatedUtc -ge $NowUtc.AddSeconds(-1 * $LeaseTtlSeconds)
                $processMatches = $false
                if (-not $heartbeatFresh) {
                    $processMatches = Test-CodexFinishWorkspaceLeaseProcess `
                        -ProcessId (Get-CodexFinishProperty -InputObject $lease -Name 'processId') `
                        -ProcessStartedUtc (Get-CodexFinishProperty -InputObject $lease -Name 'processStartedUtc')
                }
                if (-not $heartbeatFresh -and -not $processMatches) {
                    continue
                }

                $normalizedPaths = New-Object Collections.Generic.List[string]
                $leasePathMap = @{}
                foreach ($workspacePath in @(
                    Get-CodexFinishProperty -InputObject $lease -Name 'workspacePaths' -DefaultValue @()
                )) {
                    $normalized = ConvertTo-CodexFinishNormalizedDirectoryPath -Path $workspacePath
                    if (
                        -not [string]::IsNullOrWhiteSpace($normalized) -and
                        -not $leasePathMap.ContainsKey($normalized)
                    ) {
                        $leasePathMap[$normalized] = $true
                        $workspaceMap[$normalized] = $true
                        $normalizedPaths.Add($normalized)
                    }
                }
                if ($normalizedPaths.Count -eq 0) {
                    continue
                }

                $normalizedLease = [pscustomobject] [ordered] @{
                    schemaVersion    = 1
                    leaseId          = $leaseId
                    processId        = [int](Get-CodexFinishProperty -InputObject $lease -Name 'processId' -DefaultValue 0)
                    processStartedUtc = [string](Get-CodexFinishProperty -InputObject $lease -Name 'processStartedUtc')
                    workspacePaths   = [string[]]$normalizedPaths.ToArray()
                    updatedAtUtc     = $updatedUtc.ToString('o')
                    aliveReason      = if ($heartbeatFresh) { 'heartbeat' } else { 'process' }
                    sourcePath       = $leasePath
                }
                if (
                    -not $validLeaseMap.ContainsKey($leaseId) -or
                    (ConvertFrom-CodexFinishUtcText $validLeaseMap[$leaseId].updatedAtUtc) -lt $updatedUtc
                ) {
                    $validLeaseMap[$leaseId] = $normalizedLease
                }
            }
            catch {
                # A lease writer publishes atomically, but malformed or manually
                # edited files remain untrusted and are ignored.
            }
        }
    }

    $result.ValidLeases = [object[]]@($validLeaseMap.Values)
    $result.ValidLeaseCount = @($result.ValidLeases).Count
    $result.WorkspacePaths = [string[]]@($workspaceMap.Keys | Sort-Object)
    return [pscustomobject]$result
}

function Select-CodexFinishProjectMonitorForWorkspaces {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object] $MonitorState,
        [object[]] $WorkspacePaths = @(),
        [DateTime] $NowUtc = ([DateTime]::UtcNow)
    )

    if ($NowUtc.Kind -ne [DateTimeKind]::Utc) {
        $NowUtc = $NowUtc.ToUniversalTime()
    }
    $normalizedWorkspaces = @(
        $WorkspacePaths |
            ForEach-Object { ConvertTo-CodexFinishNormalizedDirectoryPath -Path $_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )
    $projects = New-Object Collections.Generic.List[object]
    foreach ($project in @(
        Get-CodexFinishProperty -InputObject $MonitorState -Name 'projects' -DefaultValue @()
    )) {
        $projectPath = [string](Get-CodexFinishProperty -InputObject $project -Name 'projectPath')
        $matched = $false
        foreach ($workspacePath in $normalizedWorkspaces) {
            if (Test-CodexFinishProjectInsideWorkspace -ProjectPath $projectPath -WorkspacePath $workspacePath) {
                $matched = $true
                break
            }
        }
        if ($matched) {
            $projects.Add($project)
        }
    }

    $orderedProjects = @($projects.ToArray() | Sort-Object `
        @{ Expression = { if ([string]$_.status -ceq 'running') { 0 } else { 1 } }; Ascending = $true }, `
        @{ Expression = { ConvertFrom-CodexFinishUtcText $_.updatedAtUtc }; Descending = $true })
    $runningCount = @($orderedProjects | Where-Object { [string]$_.status -ceq 'running' }).Count
    return [pscustomobject] [ordered] @{
        schemaVersion = 1
        updatedAtUtc  = $NowUtc.ToString('o')
        total         = $orderedProjects.Count
        running       = $runningCount
        completed     = $orderedProjects.Count - $runningCount
        projects      = [object[]]$orderedProjects
    }
}

function Get-CodexFinishProjectMonitorState {
    [CmdletBinding()]
    param(
        [string] $StateDirectory
    )

    $resolvedState = Resolve-CodexFinishStateDirectory -StateDirectory $StateDirectory
    $monitorPath = Join-Path $resolvedState 'project-monitor.json'
    if ([IO.File]::Exists($monitorPath)) {
        try {
            return [IO.File]::ReadAllText($monitorPath) | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            # A reader can safely treat an invalid/legacy snapshot as empty.
            # Writers replace the file atomically and will repair it.
        }
    }

    return New-CodexFinishEmptyProjectMonitorState
}

function New-CodexFinishProjectMonitorStateFromProjects {
    param(
        [object[]] $Projects = @(),
        [DateTime] $NowUtc = ([DateTime]::UtcNow),
        [ValidateRange(1, 500)]
        [int] $MaximumStoredProjects = 50
    )

    if ($NowUtc.Kind -ne [DateTimeKind]::Utc) {
        $NowUtc = $NowUtc.ToUniversalTime()
    }
    $normalizedProjects = New-Object Collections.Generic.List[object]
    foreach ($project in @($Projects)) {
        $sessions = @(
            Get-CodexFinishProperty -InputObject $project -Name 'sessions' -DefaultValue @()
        )
        if ($sessions.Count -eq 0) {
            continue
        }
        $projectStatus = if (@($sessions | Where-Object { [string]$_.status -ceq 'running' }).Count -gt 0) {
            'running'
        }
        else {
            'completed'
        }
        $latestSession = $sessions |
            Sort-Object @{ Expression = { ConvertFrom-CodexFinishUtcText $_.updatedAtUtc }; Descending = $true } |
            Select-Object -First 1
        $normalizedProjects.Add([pscustomobject] [ordered] @{
            name          = [string](Get-CodexFinishProperty -InputObject $project -Name 'name')
            status        = $projectStatus
            projectKey    = [string](Get-CodexFinishProperty -InputObject $project -Name 'projectKey')
            projectPath   = [string](Get-CodexFinishProperty -InputObject $project -Name 'projectPath')
            updatedAtUtc  = [string]$latestSession.updatedAtUtc
            sessions      = [object[]]$sessions
        })
    }
    $orderedProjects = @($normalizedProjects.ToArray() | Sort-Object `
        @{ Expression = { if ([string]$_.status -ceq 'running') { 0 } else { 1 } }; Ascending = $true }, `
        @{ Expression = { ConvertFrom-CodexFinishUtcText $_.updatedAtUtc }; Descending = $true } |
        Select-Object -First $MaximumStoredProjects)
    $runningCount = @($orderedProjects | Where-Object { [string]$_.status -ceq 'running' }).Count
    return [pscustomobject] [ordered] @{
        schemaVersion = 1
        updatedAtUtc  = $NowUtc.ToString('o')
        total         = $orderedProjects.Count
        running       = $runningCount
        completed     = $orderedProjects.Count - $runningCount
        projects      = [object[]]$orderedProjects
    }
}

function Merge-CodexFinishLifecycleProjectMonitorState {
    param(
        [Parameter(Mandatory = $true)]
        [object] $MonitorState,
        [Parameter(Mandatory = $true)]
        [string] $StateDirectory,
        [DateTime] $NowUtc = ([DateTime]::UtcNow),
        [ValidateRange(1, 168)]
        [int] $RetentionHours = 24,
        [ValidateRange(1, 24)]
        [int] $RunningStaleHours = 6,
        [ValidateRange(1, 500)]
        [int] $MaximumStoredProjects = 50
    )

    if ($NowUtc.Kind -ne [DateTimeKind]::Utc) {
        $NowUtc = $NowUtc.ToUniversalTime()
    }
    $cutoff = $NowUtc.AddHours(-1 * $RetentionHours)
    $runningCutoff = $NowUtc.AddHours(-1 * $RunningStaleHours)
    $lifecyclePaths = @()
    if ([IO.Directory]::Exists($StateDirectory)) {
        $lifecyclePaths = @([IO.Directory]::EnumerateFiles($StateDirectory, '*.lifecycle.json'))
    }
    $endedThreadHashes = @{}
    foreach ($lifecyclePath in $lifecyclePaths) {
        $endedLifecycle = Read-CodexFinishLifecycleState -Path $lifecyclePath
        if (
            $null -eq $endedLifecycle -or
            [string](Get-CodexFinishProperty -InputObject $endedLifecycle -Name 'rootStatus') -cne 'ended'
        ) {
            continue
        }
        $endedThreadHash = [string](Get-CodexFinishProperty `
            -InputObject $endedLifecycle -Name 'threadHash')
        if ([string]::IsNullOrWhiteSpace($endedThreadHash)) {
            $endedThreadHash = Get-CodexFinishThreadHash -Event ([pscustomobject]@{
                session_id = [string](Get-CodexFinishProperty -InputObject $endedLifecycle -Name 'sessionId')
            })
        }
        if (-not [string]::IsNullOrWhiteSpace($endedThreadHash)) {
            $endedThreadHashes[$endedThreadHash] = $true
        }
    }
    $projectMap = @{}
    foreach ($project in @(
        Get-CodexFinishProperty -InputObject $MonitorState -Name 'projects' -DefaultValue @()
    )) {
        $projectPath = ConvertTo-CodexFinishNormalizedDirectoryPath -Path (
            Get-CodexFinishProperty -InputObject $project -Name 'projectPath'
        )
        if ([string]::IsNullOrWhiteSpace($projectPath)) {
            continue
        }
        $projectEvent = [pscustomobject]@{ cwd = $projectPath }
        $projectKey = Get-CodexFinishProjectKey -Event $projectEvent
        $sessions = New-Object Collections.Generic.List[object]
        foreach ($session in @(
            Get-CodexFinishProperty -InputObject $project -Name 'sessions' -DefaultValue @()
        )) {
            $status = [string](Get-CodexFinishProperty -InputObject $session -Name 'status')
            $updated = ConvertFrom-CodexFinishUtcText (
                Get-CodexFinishProperty -InputObject $session -Name 'updatedAtUtc'
            )
            if (
                ($status -ceq 'running' -and $updated -lt $runningCutoff) -or
                ($status -cne 'running' -and $updated -lt $cutoff)
            ) {
                continue
            }
            $threadHash = [string](Get-CodexFinishProperty -InputObject $session -Name 'threadHash')
            if (
                [string]::IsNullOrWhiteSpace($threadHash) -or
                $status -notin @('running', 'completed') -or
                $endedThreadHashes.ContainsKey($threadHash)
            ) {
                continue
            }
            $sessions.Add([pscustomobject] [ordered] @{
                threadHash   = $threadHash
                status       = $status
                updatedAtUtc = $updated.ToString('o')
            })
        }
        if ($sessions.Count -gt 0) {
            $projectMap[$projectKey] = [pscustomobject] [ordered] @{
                name          = Get-CodexFinishProjectName -Event $projectEvent
                status        = [string](Get-CodexFinishProperty -InputObject $project -Name 'status')
                projectKey    = $projectKey
                projectPath   = $projectPath
                updatedAtUtc  = [string](Get-CodexFinishProperty -InputObject $project -Name 'updatedAtUtc')
                sessions      = [object[]]$sessions.ToArray()
            }
        }
    }

    if ([IO.Directory]::Exists($StateDirectory)) {
        foreach ($lifecyclePath in $lifecyclePaths) {
            $lifecycle = Read-CodexFinishLifecycleState -Path $lifecyclePath
            if ($null -eq $lifecycle) {
                continue
            }
            if ([string](Get-CodexFinishProperty -InputObject $lifecycle -Name 'rootStatus') -ceq 'ended') {
                continue
            }
            $lifecycleEvent = [pscustomobject]@{
                cwd        = [string](Get-CodexFinishProperty -InputObject $lifecycle -Name 'cwd')
                session_id = [string](Get-CodexFinishProperty -InputObject $lifecycle -Name 'sessionId')
            }
            $projectKey = Get-CodexFinishProjectKey -Event $lifecycleEvent
            $threadHash = [string](Get-CodexFinishProperty -InputObject $lifecycle -Name 'threadHash')
            if ([string]::IsNullOrWhiteSpace($threadHash)) {
                $threadHash = Get-CodexFinishThreadHash -Event $lifecycleEvent
            }
            $updated = ConvertFrom-CodexFinishUtcText (
                Get-CodexFinishProperty -InputObject $lifecycle -Name 'updatedUtc'
            )
            if (
                [string]::IsNullOrWhiteSpace($projectKey) -or
                [string]::IsNullOrWhiteSpace($threadHash) -or
                $updated -lt $runningCutoff
            ) {
                continue
            }

            $canImport = Remove-CodexFinishProjectSessionFromOtherProjects `
                -ProjectMap $projectMap `
                -ThreadHash $threadHash `
                -ExceptProjectKey $projectKey `
                -ObservedUtc $updated
            if (-not $canImport) {
                continue
            }
            $sessions = New-Object Collections.Generic.List[object]
            $hasNewer = $false
            if ($projectMap.ContainsKey($projectKey)) {
                foreach ($session in @($projectMap[$projectKey].sessions)) {
                    if ([string]$session.threadHash -ceq $threadHash) {
                        if ((ConvertFrom-CodexFinishUtcText $session.updatedAtUtc) -ge $updated) {
                            $hasNewer = $true
                            $sessions.Add($session)
                        }
                    }
                    else {
                        $sessions.Add($session)
                    }
                }
            }
            if (-not $hasNewer) {
                # Lifecycle alone cannot prove a completed aggregate; keep the
                # restored row red until normal completion confirmation runs.
                $sessions.Add([pscustomobject] [ordered] @{
                    threadHash   = $threadHash
                    status       = 'running'
                    updatedAtUtc = $updated.ToString('o')
                })
            }
            $projectMap[$projectKey] = [pscustomobject] [ordered] @{
                name          = Get-CodexFinishProjectName -Event $lifecycleEvent
                status        = 'running'
                projectKey    = $projectKey
                projectPath   = Get-CodexFinishProjectPath -Event $lifecycleEvent
                updatedAtUtc  = $updated.ToString('o')
                sessions      = [object[]]$sessions.ToArray()
            }
        }
    }

    $monitor = New-CodexFinishProjectMonitorStateFromProjects `
        -Projects @($projectMap.Values) `
        -NowUtc $NowUtc `
        -MaximumStoredProjects $MaximumStoredProjects
    return Add-CodexFinishProjectMonitorAgentDetails -MonitorState $monitor -StateDirectory $StateDirectory
}

function Sync-CodexFinishProjectMonitorWithWorkspaceLeases {
    [CmdletBinding()]
    param(
        [string] $StateDirectory,
        [ValidateRange(1, 3600)]
        [int] $LeaseTtlSeconds = 20,
        [DateTime] $NowUtc = ([DateTime]::UtcNow),
        [ValidateRange(50, 60000)]
        [int] $MonitorLockTimeoutMilliseconds = 1000,
        [ValidateRange(1, 168)]
        [int] $RetentionHours = 24,
        [ValidateRange(1, 24)]
        [int] $RunningStaleHours = 6,
        [ValidateRange(1, 500)]
        [int] $MaximumStoredProjects = 50
    )

    if ($NowUtc.Kind -ne [DateTimeKind]::Utc) {
        $NowUtc = $NowUtc.ToUniversalTime()
    }
    $resolvedState = Resolve-CodexFinishStateDirectory -StateDirectory $StateDirectory
    $null = [IO.Directory]::CreateDirectory($resolvedState)
    $leaseState = Get-CodexFinishWorkspaceLeaseState `
        -StateDirectory $resolvedState `
        -LeaseTtlSeconds $LeaseTtlSeconds `
        -NowUtc $NowUtc
    $leaseCleanup = $null
    if ($leaseState.Enabled) {
        # Cleanup is deliberately confined to the periodic reconciliation
        # path; synchronous Hooks only perform read-only lease checks.
        $leaseCleanup = Remove-CodexFinishExpiredWorkspaceLeases `
            -StateDirectory $resolvedState `
            -LeaseTtlSeconds $LeaseTtlSeconds `
            -NowUtc $NowUtc
        $leaseState = Get-CodexFinishWorkspaceLeaseState `
            -StateDirectory $resolvedState `
            -LeaseTtlSeconds $LeaseTtlSeconds `
            -NowUtc $NowUtc
    }
    $monitorPath = Join-Path $resolvedState 'project-monitor.json'
    if (-not $leaseState.Enabled) {
        return [pscustomobject] [ordered] @{
            Updated       = $false
            Changed       = $false
            Reason        = $leaseState.Reason
            State         = Get-CodexFinishProjectMonitorState -StateDirectory $resolvedState
            HistoryState  = $null
            LeaseState    = $leaseState
            LeaseCleanup  = $leaseCleanup
            Path          = $monitorPath
        }
    }

    $lockPath = Join-Path $resolvedState 'project-monitor.lock'
    $lockStream = Open-CodexFinishStateLock `
        -Path $lockPath `
        -TimeoutMilliseconds $MonitorLockTimeoutMilliseconds
    if ($null -eq $lockStream) {
        return [pscustomobject] [ordered] @{
            Updated       = $false
            Changed       = $false
            Reason        = 'project-monitor-lock-unavailable'
            State         = Get-CodexFinishProjectMonitorState -StateDirectory $resolvedState
            HistoryState  = $null
            LeaseState    = $leaseState
            LeaseCleanup  = $leaseCleanup
            Path          = $monitorPath
        }
    }

    try {
        # Refresh after taking the aggregate lock so a lease heartbeat that
        # raced this cycle is reflected in the committed live view.
        $leaseState = Get-CodexFinishWorkspaceLeaseState `
            -StateDirectory $resolvedState `
            -LeaseTtlSeconds $LeaseTtlSeconds `
            -NowUtc $NowUtc
        $historyPath = Join-Path $resolvedState 'project-monitor-history.json'
        $history = Read-CodexFinishProjectMonitorFile -Path $historyPath
        if ($null -eq $history) {
            $history = Get-CodexFinishProjectMonitorState -StateDirectory $resolvedState
        }
        $history = Merge-CodexFinishLifecycleProjectMonitorState `
            -MonitorState $history `
            -StateDirectory $resolvedState `
            -NowUtc $NowUtc `
            -RetentionHours $RetentionHours `
            -RunningStaleHours $RunningStaleHours `
            -MaximumStoredProjects $MaximumStoredProjects
        $live = Select-CodexFinishProjectMonitorForWorkspaces `
            -MonitorState $history `
            -WorkspacePaths $leaseState.WorkspacePaths `
            -NowUtc $NowUtc
        $existingLive = Get-CodexFinishProjectMonitorState -StateDirectory $resolvedState
        $existingFingerprint = @(
            Get-CodexFinishProperty -InputObject $existingLive -Name 'projects' -DefaultValue @()
        ) | ConvertTo-Json -Depth 8 -Compress
        $liveFingerprint = @($live.projects) | ConvertTo-Json -Depth 8 -Compress
        $changed = $existingFingerprint -cne $liveFingerprint

        Write-CodexFinishUtf8File `
            -Path $historyPath `
            -Content (($history | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
        if ($changed -or -not [IO.File]::Exists($monitorPath)) {
            Write-CodexFinishUtf8File `
                -Path $monitorPath `
                -Content (($live | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
        }
        else {
            $live = $existingLive
        }

        return [pscustomobject] [ordered] @{
            Updated       = $true
            Changed       = $changed
            Reason        = if ($changed) { 'workspace-monitor-reconciled' } else { 'workspace-monitor-unchanged' }
            State         = $live
            HistoryState  = $history
            LeaseState    = $leaseState
            LeaseCleanup  = $leaseCleanup
            Path          = $monitorPath
        }
    }
    catch {
        return [pscustomobject] [ordered] @{
            Updated       = $false
            Changed       = $false
            Reason        = 'workspace-monitor-sync-failed'
            State         = Get-CodexFinishProjectMonitorState -StateDirectory $resolvedState
            HistoryState  = $null
            LeaseState    = $leaseState
            LeaseCleanup  = $leaseCleanup
            Path          = $monitorPath
            Error         = $_.Exception.Message
        }
    }
    finally {
        $lockStream.Dispose()
    }
}

function Invoke-CodexFinishProjectMonitorSync {
    [CmdletBinding()]
    param(
        [string] $StateDirectory,
        [string] $ConfigPath,
        [ValidateRange(1, 3600)]
        [int] $LeaseTtlSeconds = 20,
        [ValidateRange(1, 3600)]
        [int] $SnapshotIntervalSeconds = 30,
        [DateTime] $LastSnapshotUtc = ([DateTime]::MinValue),
        [DateTime] $NowUtc = ([DateTime]::UtcNow),
        [switch] $ForceSnapshot,
        [switch] $SkipBoard
    )

    if ($NowUtc.Kind -ne [DateTimeKind]::Utc) {
        $NowUtc = $NowUtc.ToUniversalTime()
    }
    $sync = Sync-CodexFinishProjectMonitorWithWorkspaceLeases `
        -StateDirectory $StateDirectory `
        -LeaseTtlSeconds $LeaseTtlSeconds `
        -NowUtc $NowUtc
    $snapshotDue = $sync.Updated -and (
        $ForceSnapshot -or
        $sync.Changed -or
        $LastSnapshotUtc -eq [DateTime]::MinValue -or
        ($NowUtc - $LastSnapshotUtc.ToUniversalTime()).TotalSeconds -ge $SnapshotIntervalSeconds
    )
    $boardResult = $null
    $snapshotAttempted = $false
    $hardwareEnabled = $null
    if ($snapshotDue -and -not $SkipBoard) {
        try {
            $settings = Get-CodexFinishSettings -ConfigPath $ConfigPath
            $hardwareEnabled = [bool]$settings.hardware.enabled
            if ($settings.hardware.enabled) {
                $snapshotAttempted = $true
                $boardResult = Send-CodexFinishBoardSnapshot `
                    -HardwareSettings $settings.hardware `
                    -MonitorState $sync.State `
                    -MaximumProjects $settings.projectMonitor.maximumProjects `
                    -StateDirectory (Resolve-CodexFinishStateDirectory -StateDirectory $StateDirectory)
            }
        }
        catch {
            $boardResult = [pscustomobject]@{
                Sent = $false; Reason = 'snapshot-sync-failed'; Error = $_.Exception.Message
            }
        }
    }

    return [pscustomobject] [ordered] @{
        Updated            = [bool]$sync.Updated
        Changed            = [bool]$sync.Changed
        Reason             = [string]$sync.Reason
        State              = $sync.State
        HistoryState       = $sync.HistoryState
        LeaseState         = $sync.LeaseState
        SnapshotDue        = [bool]$snapshotDue
        SnapshotAttempted  = [bool]$snapshotAttempted
        SnapshotSent       = [bool]($null -ne $boardResult -and $boardResult.Sent)
        HardwareEnabled    = $hardwareEnabled
        BoardResult        = $boardResult
        SnapshotObservedUtc = if ($null -ne $boardResult -and $boardResult.Sent) { $NowUtc.ToString('o') } else { $null }
    }
}

function Start-CodexFinishMonitorSyncWorker {
    [CmdletBinding()]
    param(
        [string] $StateDirectory,
        [string] $ConfigPath,
        [ValidateRange(1, 3600)]
        [int] $LeaseTtlSeconds = 20,
        [ValidateRange(1, 300)]
        [int] $PollSeconds = 5,
        [ValidateRange(1, 3600)]
        [int] $SnapshotIntervalSeconds = 30,
        [ValidateRange(20, 3600)]
        [int] $ResumeGraceSeconds = 20
    )

    try {
        if (
            [string]::IsNullOrWhiteSpace($script:CodexFinishModulePath) -or
            -not [IO.File]::Exists($script:CodexFinishModulePath)
        ) {
            return [pscustomobject]@{ Started = $false; ProcessId = $null; Reason = 'module-path-missing' }
        }
        $workerPath = Join-Path ([IO.Path]::GetDirectoryName($script:CodexFinishModulePath)) 'monitor-sync-worker.ps1'
        if (-not [IO.File]::Exists($workerPath)) {
            return [pscustomobject]@{ Started = $false; ProcessId = $null; Reason = 'worker-script-missing' }
        }
        $resolvedState = Resolve-CodexFinishStateDirectory -StateDirectory $StateDirectory
        $escapedWorker = $workerPath.Replace("'", "''")
        $escapedState = $resolvedState.Replace("'", "''")
        $command = "& '$escapedWorker' -StateDirectory '$escapedState'" +
            " -LeaseTtlSeconds $LeaseTtlSeconds -PollSeconds $PollSeconds" +
            " -SnapshotIntervalSeconds $SnapshotIntervalSeconds -ResumeGraceSeconds $ResumeGraceSeconds"
        if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
            $escapedConfig = ([IO.Path]::GetFullPath($ConfigPath)).Replace("'", "''")
            $command += " -ConfigPath '$escapedConfig'"
        }
        $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $powerShellPath = (Get-Command powershell.exe -ErrorAction Stop).Source
        $process = Start-Process `
            -FilePath $powerShellPath `
            -ArgumentList @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy',
                'Bypass', '-EncodedCommand', $encodedCommand
            ) `
            -WindowStyle Hidden `
            -PassThru
        return [pscustomobject]@{
            Started = $true; ProcessId = $process.Id; Reason = 'started'; ScriptPath = $workerPath
        }
    }
    catch {
        return [pscustomobject]@{
            Started = $false; ProcessId = $null; Reason = 'worker-start-failed'; Error = $_.Exception.Message
        }
    }
}

function ConvertFrom-CodexFinishUtcText {
    param(
        [object] $Value
    )

    try {
        return [DateTimeOffset]::Parse(
            [string]$Value,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal
        ).UtcDateTime
    }
    catch {
        return [DateTime]::MinValue
    }
}

function Remove-CodexFinishProjectSessionFromOtherProjects {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $ProjectMap,
        [Parameter(Mandatory = $true)]
        [string] $ThreadHash,
        [Parameter(Mandatory = $true)]
        [string] $ExceptProjectKey,
        [Parameter(Mandatory = $true)]
        [DateTime] $ObservedUtc
    )

    $latestExistingUtc = [DateTime]::MinValue
    foreach ($mapKey in @($ProjectMap.Keys)) {
        foreach ($session in @($ProjectMap[$mapKey].sessions)) {
            if ([string]$session.threadHash -ceq $ThreadHash) {
                $sessionUtc = ConvertFrom-CodexFinishUtcText $session.updatedAtUtc
                if ($sessionUtc -gt $latestExistingUtc) {
                    $latestExistingUtc = $sessionUtc
                }
            }
        }
    }
    if ($latestExistingUtc -gt $ObservedUtc) {
        return $false
    }

    foreach ($mapKey in @($ProjectMap.Keys)) {
        if ([string]$mapKey -ceq $ExceptProjectKey) {
            continue
        }
        $remaining = @($ProjectMap[$mapKey].sessions | Where-Object {
            [string]$_.threadHash -cne $ThreadHash
        })
        if ($remaining.Count -eq 0) {
            $null = $ProjectMap.Remove($mapKey)
        }
        else {
            $ProjectMap[$mapKey].sessions = [object[]]$remaining
        }
    }
    return $true
}

function Invoke-CodexFinishProjectMonitorDirtyReplay {
    param(
        [Parameter(Mandatory = $true)]
        [string] $StateDirectory
    )

    $replayed = 0
    try {
        $dirtyPaths = @([IO.Directory]::EnumerateFiles(
            $StateDirectory,
            'project-monitor.dirty.*.json'
        ))
    }
    catch {
        return 0
    }
    foreach ($dirtyPath in $dirtyPaths) {
        try {
            $dirty = [IO.File]::ReadAllText($dirtyPath) | ConvertFrom-Json -ErrorAction Stop
            $status = [string](Get-CodexFinishProperty -InputObject $dirty -Name 'status')
            $event = Get-CodexFinishProperty -InputObject $dirty -Name 'event'
            $observed = ConvertFrom-CodexFinishUtcText (
                Get-CodexFinishProperty -InputObject $dirty -Name 'observedUtc'
            )
            if (
                $null -eq $event -or
                $status -notin @('running', 'completed') -or
                $observed -eq [DateTime]::MinValue
            ) {
                continue
            }
            $result = Update-CodexFinishProjectMonitorState `
                -Event $event `
                -Status $status `
                -StateDirectory $StateDirectory `
                -NowUtc $observed `
                -MonitorLockTimeoutMilliseconds 5000 `
                -DisableRetry `
                -SkipDirtyReplay
            if ($result.Updated) {
                [IO.File]::Delete($dirtyPath)
                $replayed++
            }
        }
        catch {
            # A partial/corrupt marker remains durable for later inspection or
            # replacement; one bad record must not block the live Hook update.
        }
    }
    return $replayed
}

function Start-CodexFinishProjectMonitorRetry {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Event,
        [Parameter(Mandatory = $true)]
        [ValidateSet('running', 'completed')]
        [string] $Status,
        [Parameter(Mandatory = $true)]
        [string] $StateDirectory,
        [Parameter(Mandatory = $true)]
        [DateTime] $ObservedUtc,
        [Parameter(Mandatory = $true)]
        [string] $DirtyPath
    )

    if (
        [string]::IsNullOrWhiteSpace($script:CodexFinishModulePath) -or
        -not [IO.File]::Exists($script:CodexFinishModulePath)
    ) {
        return $false
    }

    try {
        # Persist only lifecycle identity and project path; never prompt text,
        # tool input, transcript content, or assistant output.
        $retryEvent = [ordered]@{
            cwd         = [string](Get-CodexFinishProperty -InputObject $Event -Name 'cwd')
            session_id  = [string](Get-CodexFinishProperty -InputObject $Event -Name 'session_id')
            'thread-id' = [string](Get-CodexFinishProperty -InputObject $Event -Name 'thread-id')
            turn_id     = [string](Get-CodexFinishProperty -InputObject $Event -Name 'turn_id')
            'turn-id'   = [string](Get-CodexFinishProperty -InputObject $Event -Name 'turn-id')
        }
        $envelope = [ordered]@{
            event         = $retryEvent
            status        = $Status
            stateDirectory = $StateDirectory
            observedUtc   = $ObservedUtc.ToUniversalTime().ToString('o')
            dirtyPath     = $DirtyPath
        }
        Write-CodexFinishUtf8File `
            -Path $DirtyPath `
            -Content (($envelope | ConvertTo-Json -Depth 6) + [Environment]::NewLine)

        $envelopeBase64 = [Convert]::ToBase64String(
            [Text.Encoding]::UTF8.GetBytes(($envelope | ConvertTo-Json -Depth 6 -Compress))
        )
        $escapedModule = $script:CodexFinishModulePath.Replace("'", "''")
        $command = @"
`$ErrorActionPreference = 'SilentlyContinue'
`$json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$envelopeBase64'))
`$retry = `$json | ConvertFrom-Json
Import-Module '$escapedModule' -Force
`$observed = [DateTime]::Parse([string]`$retry.observedUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
for (`$attempt = 0; `$attempt -lt 30; `$attempt++) {
    `$result = Update-CodexFinishProjectMonitorState -Event `$retry.event -Status ([string]`$retry.status) -StateDirectory ([string]`$retry.stateDirectory) -NowUtc `$observed -MonitorLockTimeoutMilliseconds 5000 -DisableRetry -SkipDirtyReplay
    if (`$result.Updated) {
        [IO.File]::Delete([string]`$retry.dirtyPath)
        break
    }
    Start-Sleep -Seconds 1
}
"@
        $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $powerShellPath = (Get-Command powershell.exe -ErrorAction Stop).Source
        $null = Start-Process `
            -FilePath $powerShellPath `
            -ArgumentList @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy',
                'Bypass', '-EncodedCommand', $encodedCommand
            ) `
            -WindowStyle Hidden
        return $true
    }
    catch {
        return $false
    }
}

function Update-CodexFinishProjectMonitorState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Event,
        [Parameter(Mandatory = $true)]
        [ValidateSet('running', 'completed')]
        [string] $Status,
        [string] $StateDirectory,
        [ValidateRange(1, 168)]
        [int] $RetentionHours = 24,
        [ValidateRange(1, 24)]
        [int] $RunningStaleHours = 6,
        [ValidateRange(1, 500)]
        [int] $MaximumStoredProjects = 50,
        [DateTime] $NowUtc = ([DateTime]::UtcNow),
        [ValidateRange(50, 60000)]
        [int] $MonitorLockTimeoutMilliseconds = 1000,
        [switch] $CompleteProject,
        [switch] $DisableRetry,
        [switch] $SkipDirtyReplay
    )

    try {
        $projectKey = Get-CodexFinishProjectKey -Event $Event
        $threadHash = Get-CodexFinishThreadHash -Event $Event
        if (
            [string]::IsNullOrWhiteSpace($projectKey) -or
            [string]::IsNullOrWhiteSpace($threadHash)
        ) {
            return [pscustomobject]@{
                Updated = $false; Reason = 'invalid-project-identity'; Path = $null; State = $null
            }
        }

        if ($NowUtc.Kind -ne [DateTimeKind]::Utc) {
            $NowUtc = $NowUtc.ToUniversalTime()
        }
        $nowText = $NowUtc.ToString('o')
        $cutoff = $NowUtc.AddHours(-1 * $RetentionHours)
        $runningCutoff = $NowUtc.AddHours(-1 * $RunningStaleHours)
        $resolvedState = Resolve-CodexFinishStateDirectory -StateDirectory $StateDirectory
        $null = [IO.Directory]::CreateDirectory($resolvedState)
        if (-not $SkipDirtyReplay) {
            $null = Invoke-CodexFinishProjectMonitorDirtyReplay -StateDirectory $resolvedState
        }
        $monitorPath = Join-Path $resolvedState 'project-monitor.json'
        $lockPath = Join-Path $resolvedState 'project-monitor.lock'
        $lockStream = Open-CodexFinishStateLock `
            -Path $lockPath `
            -TimeoutMilliseconds $MonitorLockTimeoutMilliseconds
        if ($null -eq $lockStream) {
            $dirtyPath = Join-Path $resolvedState (
                'project-monitor.dirty.' + [Guid]::NewGuid().ToString('N') + '.json'
            )
            $retryScheduled = $false
            if (-not $DisableRetry) {
                $retryScheduled = Start-CodexFinishProjectMonitorRetry `
                    -Event $Event `
                    -Status $Status `
                    -StateDirectory $resolvedState `
                    -ObservedUtc $NowUtc `
                    -DirtyPath $dirtyPath
            }
            return [pscustomobject]@{
                Updated = $false
                Reason = 'project-monitor-lock-unavailable'
                Path = $monitorPath
                State = $null
                RetryScheduled = $retryScheduled
                DirtyPath = if ($retryScheduled -or [IO.File]::Exists($dirtyPath)) { $dirtyPath } else { $null }
            }
        }

        try {
            $leaseState = Get-CodexFinishWorkspaceLeaseState `
                -StateDirectory $resolvedState `
                -NowUtc $NowUtc
            $historyPath = Join-Path $resolvedState 'project-monitor-history.json'
            $existing = $null
            if ($leaseState.Enabled) {
                $existing = Read-CodexFinishProjectMonitorFile -Path $historyPath
            }
            if ($null -eq $existing) {
                $existing = Get-CodexFinishProjectMonitorState -StateDirectory $resolvedState
            }
            $projectMap = @{}
            $endedThreadHashes = @{}
            foreach ($endedPath in @([IO.Directory]::EnumerateFiles($resolvedState, '*.lifecycle.json'))) {
                $endedLifecycle = Read-CodexFinishLifecycleState -Path $endedPath
                if (
                    $null -eq $endedLifecycle -or
                    [string](Get-CodexFinishProperty -InputObject $endedLifecycle -Name 'rootStatus') -cne 'ended'
                ) { continue }
                $endedHash = [string](Get-CodexFinishProperty `
                    -InputObject $endedLifecycle -Name 'threadHash')
                if (-not [string]::IsNullOrWhiteSpace($endedHash)) {
                    $endedThreadHashes[$endedHash] = $true
                }
            }

            foreach ($existingProject in @(
                Get-CodexFinishProperty -InputObject $existing -Name 'projects' -DefaultValue @()
            )) {
                $existingPath = ConvertTo-CodexFinishNormalizedDirectoryPath -Path (
                    Get-CodexFinishProperty -InputObject $existingProject -Name 'projectPath'
                )
                if ([string]::IsNullOrWhiteSpace($existingPath)) {
                    continue
                }
                $existingEvent = [pscustomobject]@{ cwd = $existingPath }
                $existingKey = Get-CodexFinishProjectKey -Event $existingEvent

                $sessions = New-Object Collections.Generic.List[object]
                foreach ($existingSession in @(
                    Get-CodexFinishProperty -InputObject $existingProject -Name 'sessions' -DefaultValue @()
                )) {
                    $sessionUpdated = ConvertFrom-CodexFinishUtcText (
                        Get-CodexFinishProperty -InputObject $existingSession -Name 'updatedAtUtc'
                    )
                    $existingThreadHash = [string] (
                        Get-CodexFinishProperty -InputObject $existingSession -Name 'threadHash'
                    )
                    $existingStatus = [string] (
                        Get-CodexFinishProperty -InputObject $existingSession -Name 'status'
                    )
                    if (
                        ($existingStatus -ceq 'running' -and $sessionUpdated -lt $runningCutoff) -or
                        ($existingStatus -cne 'running' -and $sessionUpdated -lt $cutoff)
                    ) {
                        continue
                    }
                    if (
                        [string]::IsNullOrWhiteSpace($existingThreadHash) -or
                        $existingStatus -notin @('running', 'completed') -or
                        $endedThreadHashes.ContainsKey($existingThreadHash)
                    ) {
                        continue
                    }
                    $sessions.Add([pscustomobject] [ordered] @{
                        threadHash   = $existingThreadHash
                        status       = $existingStatus
                        updatedAtUtc = $sessionUpdated.ToString('o')
                    })
                }
                if ($sessions.Count -eq 0) {
                    continue
                }

                $projectMap[$existingKey] = [pscustomobject] [ordered] @{
                    name          = Get-CodexFinishProjectName -Event $existingEvent
                    status        = 'completed'
                    projectKey    = $existingKey
                    projectPath   = $existingPath
                    updatedAtUtc  = [string] (Get-CodexFinishProperty -InputObject $existingProject -Name 'updatedAtUtc')
                    sessions      = [object[]] $sessions.ToArray()
                }
            }

            # Bootstrap/repair the aggregate from per-thread lifecycle files.
            # This makes already-running projects visible immediately after an
            # upgrade instead of waiting for every Codex window to emit another
            # event. Newer monitor entries always win over older lifecycle data.
            foreach ($lifecyclePath in @([IO.Directory]::EnumerateFiles($resolvedState, '*.lifecycle.json'))) {
                $lifecycle = Read-CodexFinishLifecycleState -Path $lifecyclePath
                if ($null -eq $lifecycle) {
                    continue
                }
                if ([string](Get-CodexFinishProperty -InputObject $lifecycle -Name 'rootStatus') -ceq 'ended') {
                    continue
                }
                $lifecycleEvent = [pscustomobject]@{
                    cwd        = [string](Get-CodexFinishProperty -InputObject $lifecycle -Name 'cwd')
                    session_id = [string](Get-CodexFinishProperty -InputObject $lifecycle -Name 'sessionId')
                }
                $lifecycleProjectKey = Get-CodexFinishProjectKey -Event $lifecycleEvent
                $lifecycleThreadHash = [string](
                    Get-CodexFinishProperty -InputObject $lifecycle -Name 'threadHash'
                )
                if ([string]::IsNullOrWhiteSpace($lifecycleThreadHash)) {
                    $lifecycleThreadHash = Get-CodexFinishThreadHash -Event $lifecycleEvent
                }
                if (
                    [string]::IsNullOrWhiteSpace($lifecycleProjectKey) -or
                    [string]::IsNullOrWhiteSpace($lifecycleThreadHash)
                ) {
                    continue
                }
                # Lifecycle Stop is only a completion candidate. Rebuilding
                # the aggregate must remain fail-closed/red until the project
                # quiet-window confirmation publishes the sole completed
                # transition.
                $lifecycleStatus = 'running'
                $lifecycleUpdatedText = [string](
                    Get-CodexFinishProperty -InputObject $lifecycle -Name 'updatedUtc'
                )
                $lifecycleUpdated = ConvertFrom-CodexFinishUtcText $lifecycleUpdatedText
                if (
                    ($lifecycleStatus -ceq 'running' -and $lifecycleUpdated -lt $runningCutoff) -or
                    ($lifecycleStatus -ceq 'completed' -and $lifecycleUpdated -lt $cutoff)
                ) {
                    continue
                }

                $canImportLifecycle = Remove-CodexFinishProjectSessionFromOtherProjects `
                    -ProjectMap $projectMap `
                    -ThreadHash $lifecycleThreadHash `
                    -ExceptProjectKey $lifecycleProjectKey `
                    -ObservedUtc $lifecycleUpdated
                if (-not $canImportLifecycle) {
                    continue
                }

                $lifecycleSessions = New-Object Collections.Generic.List[object]
                $hasNewerSession = $false
                if ($projectMap.ContainsKey($lifecycleProjectKey)) {
                    foreach ($session in @($projectMap[$lifecycleProjectKey].sessions)) {
                        if ([string]$session.threadHash -ceq $lifecycleThreadHash) {
                            if ((ConvertFrom-CodexFinishUtcText $session.updatedAtUtc) -ge $lifecycleUpdated) {
                                $hasNewerSession = $true
                                $lifecycleSessions.Add($session)
                            }
                        }
                        else {
                            $lifecycleSessions.Add($session)
                        }
                    }
                }
                if (-not $hasNewerSession) {
                    $lifecycleSessions.Add([pscustomobject] [ordered] @{
                        threadHash   = $lifecycleThreadHash
                        status       = $lifecycleStatus
                        updatedAtUtc = $lifecycleUpdated.ToString('o')
                    })
                }
                $projectMap[$lifecycleProjectKey] = [pscustomobject] [ordered] @{
                    name          = Get-CodexFinishProjectName -Event $lifecycleEvent
                    status        = $lifecycleStatus
                    projectKey    = $lifecycleProjectKey
                    projectPath   = Get-CodexFinishProjectPath -Event $lifecycleEvent
                    updatedAtUtc  = $lifecycleUpdated.ToString('o')
                    sessions      = [object[]]$lifecycleSessions.ToArray()
                }
            }

            $canApplyTarget = Remove-CodexFinishProjectSessionFromOtherProjects `
                -ProjectMap $projectMap `
                -ThreadHash $threadHash `
                -ExceptProjectKey $projectKey `
                -ObservedUtc $NowUtc
            if ($canApplyTarget) {
                $targetSessions = New-Object Collections.Generic.List[object]
                $targetHasNewerSession = $false
                if ($projectMap.ContainsKey($projectKey)) {
                    foreach ($session in @($projectMap[$projectKey].sessions)) {
                        if ([string]$session.threadHash -ceq $threadHash) {
                            if ((ConvertFrom-CodexFinishUtcText $session.updatedAtUtc) -gt $NowUtc) {
                                $targetHasNewerSession = $true
                                $targetSessions.Add($session)
                            }
                        }
                        else {
                            $targetSessions.Add($session)
                        }
                    }
                }
                if (-not $targetHasNewerSession) {
                    $targetSessions.Add([pscustomobject] [ordered] @{
                        threadHash   = $threadHash
                        status       = $Status
                        updatedAtUtc = $nowText
                    })
                }
                $projectMap[$projectKey] = [pscustomobject] [ordered] @{
                    name          = Get-CodexFinishProjectName -Event $Event
                    status        = $Status
                    projectKey    = $projectKey
                    projectPath   = Get-CodexFinishProjectPath -Event $Event
                    updatedAtUtc  = $nowText
                    sessions      = [object[]] $targetSessions.ToArray()
                }
            }

            if ($CompleteProject -and $projectMap.ContainsKey($projectKey)) {
                # Every lifecycle session was verified idle while the caller
                # held the project settle lock. Clear all red settling rows in
                # one aggregate update so near-simultaneous session finishes
                # become one project completion rather than several alerts.
                $completedSessions = New-Object Collections.Generic.List[object]
                foreach ($session in @($projectMap[$projectKey].sessions)) {
                    $completedSessions.Add([pscustomobject] [ordered] @{
                        threadHash   = [string]$session.threadHash
                        status       = 'completed'
                        updatedAtUtc = $nowText
                    })
                }
                $projectMap[$projectKey].status = 'completed'
                $projectMap[$projectKey].updatedAtUtc = $nowText
                $projectMap[$projectKey].sessions = [object[]]$completedSessions.ToArray()
            }

            $projects = New-Object Collections.Generic.List[object]
            foreach ($project in @($projectMap.Values)) {
                $projectSessions = @($project.sessions)
                $projectStatus = if (@($projectSessions | Where-Object { $_.status -ceq 'running' }).Count -gt 0) {
                    'running'
                }
                else {
                    'completed'
                }
                $latestSession = $projectSessions |
                    Sort-Object @{ Expression = { ConvertFrom-CodexFinishUtcText $_.updatedAtUtc }; Descending = $true } |
                    Select-Object -First 1
                $projects.Add([pscustomobject] [ordered] @{
                    name          = [string]$project.name
                    status        = $projectStatus
                    projectKey    = [string]$project.projectKey
                    projectPath   = [string]$project.projectPath
                    updatedAtUtc  = [string]$latestSession.updatedAtUtc
                    sessions      = [object[]]$projectSessions
                })
            }

            $orderedProjects = @($projects.ToArray() | Sort-Object `
                @{ Expression = { if ($_.status -ceq 'running') { 0 } else { 1 } }; Ascending = $true }, `
                @{ Expression = { ConvertFrom-CodexFinishUtcText $_.updatedAtUtc }; Descending = $true } |
                Select-Object -First $MaximumStoredProjects)
            $runningCount = @($orderedProjects | Where-Object { $_.status -ceq 'running' }).Count
            $monitor = [pscustomobject] [ordered] @{
                schemaVersion = 1
                updatedAtUtc  = $nowText
                total         = $orderedProjects.Count
                running       = $runningCount
                completed     = $orderedProjects.Count - $runningCount
                projects      = [object[]]$orderedProjects
            }
            $monitor = Add-CodexFinishProjectMonitorAgentDetails -MonitorState $monitor -StateDirectory $resolvedState
            $publishedMonitor = $monitor
            if ($leaseState.Enabled) {
                # Keep the unfiltered aggregate for fast reopen recovery.  The
                # public snapshot remains strictly scoped to live VS Code
                # workspace leases, so a Hook cannot resurrect a closed row.
                Write-CodexFinishUtf8File `
                    -Path $historyPath `
                    -Content (($monitor | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
                $leaseState = Get-CodexFinishWorkspaceLeaseState `
                    -StateDirectory $resolvedState `
                    -NowUtc $NowUtc
                $publishedMonitor = Select-CodexFinishProjectMonitorForWorkspaces `
                    -MonitorState $monitor `
                    -WorkspacePaths $leaseState.WorkspacePaths `
                    -NowUtc $NowUtc
            }
            Write-CodexFinishUtf8File `
                -Path $monitorPath `
                -Content (($publishedMonitor | ConvertTo-Json -Depth 8) + [Environment]::NewLine)

            return [pscustomobject]@{
                Updated = $true
                Reason = 'updated'
                Path = $monitorPath
                State = $publishedMonitor
                HistoryState = if ($leaseState.Enabled) { $monitor } else { $null }
                WorkspaceLeaseState = $leaseState
            }
        }
        finally {
            $lockStream.Dispose()
        }
    }
    catch {
        return [pscustomobject]@{
            Updated = $false; Reason = 'project-monitor-write-failed'; Path = $null; State = $null
        }
    }
}

function Remove-CodexFinishProjectMonitorSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Event,
        [string] $StateDirectory,
        [DateTime] $NowUtc = ([DateTime]::UtcNow),
        [ValidateRange(50, 60000)]
        [int] $MonitorLockTimeoutMilliseconds = 1000
    )

    $threadHash = Get-CodexFinishThreadHash -Event $Event
    if ([string]::IsNullOrWhiteSpace($threadHash)) {
        return [pscustomobject]@{ Updated = $false; Reason = 'invalid-thread-state'; State = $null }
    }
    if ($NowUtc.Kind -ne [DateTimeKind]::Utc) {
        $NowUtc = $NowUtc.ToUniversalTime()
    }
    $resolvedState = Resolve-CodexFinishStateDirectory -StateDirectory $StateDirectory
    $null = [IO.Directory]::CreateDirectory($resolvedState)
    $monitorPath = Join-Path $resolvedState 'project-monitor.json'
    $historyPath = Join-Path $resolvedState 'project-monitor-history.json'
    $lockStream = Open-CodexFinishStateLock `
        -Path (Join-Path $resolvedState 'project-monitor.lock') `
        -TimeoutMilliseconds $MonitorLockTimeoutMilliseconds
    if ($null -eq $lockStream) {
        return [pscustomobject]@{
            Updated = $false; Reason = 'project-monitor-lock-unavailable'
            State = Get-CodexFinishProjectMonitorState -StateDirectory $resolvedState
        }
    }

    try {
        $leaseState = Get-CodexFinishWorkspaceLeaseState -StateDirectory $resolvedState -NowUtc $NowUtc
        $source = if ($leaseState.Enabled) {
            Read-CodexFinishProjectMonitorFile -Path $historyPath
        }
        else {
            $null
        }
        if ($null -eq $source) {
            $source = Get-CodexFinishProjectMonitorState -StateDirectory $resolvedState
        }
        # Normalizes legacy mojibake keys and restores any other live sessions;
        # the caller has already marked this lifecycle ended, so it is not
        # reintroduced by the bootstrap.
        $source = Merge-CodexFinishLifecycleProjectMonitorState `
            -MonitorState $source `
            -StateDirectory $resolvedState `
            -NowUtc $NowUtc
        $projects = New-Object Collections.Generic.List[object]
        foreach ($project in @($source.projects)) {
            $remaining = @($project.sessions | Where-Object {
                [string]$_.threadHash -cne $threadHash
            })
            if ($remaining.Count -eq 0) {
                continue
            }
            $project.sessions = [object[]]$remaining
            $projects.Add($project)
        }
        $history = New-CodexFinishProjectMonitorStateFromProjects `
            -Projects @($projects.ToArray()) `
            -NowUtc $NowUtc
        $published = $history
        if ($leaseState.Enabled) {
            Write-CodexFinishUtf8File `
                -Path $historyPath `
                -Content (($history | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
            $leaseState = Get-CodexFinishWorkspaceLeaseState -StateDirectory $resolvedState -NowUtc $NowUtc
            $published = Select-CodexFinishProjectMonitorForWorkspaces `
                -MonitorState $history `
                -WorkspacePaths $leaseState.WorkspacePaths `
                -NowUtc $NowUtc
        }
        Write-CodexFinishUtf8File `
            -Path $monitorPath `
            -Content (($published | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
        return [pscustomobject]@{
            Updated = $true; Reason = 'session-ended'; State = $published
            HistoryState = if ($leaseState.Enabled) { $history } else { $null }
        }
    }
    catch {
        return [pscustomobject]@{
            Updated = $false; Reason = 'project-monitor-session-remove-failed'
            State = Get-CodexFinishProjectMonitorState -StateDirectory $resolvedState
            Error = $_.Exception.Message
        }
    }
    finally {
        $lockStream.Dispose()
    }
}

function Start-CodexFinishProjectMonitorSessionRemovalRetry {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Event,
        [string] $StateDirectory
    )

    if (
        [string]::IsNullOrWhiteSpace($script:CodexFinishModulePath) -or
        -not [IO.File]::Exists($script:CodexFinishModulePath)
    ) {
        return $false
    }
    try {
        $resolvedState = Resolve-CodexFinishStateDirectory -StateDirectory $StateDirectory
        $retryEvent = [ordered]@{
            session_id = [string](Get-CodexFinishProperty -InputObject $Event -Name 'session_id')
            cwd        = [string](Get-CodexFinishProperty -InputObject $Event -Name 'cwd')
        }
        $envelope = [ordered]@{ event = $retryEvent; stateDirectory = $resolvedState }
        $base64 = [Convert]::ToBase64String(
            [Text.Encoding]::UTF8.GetBytes(($envelope | ConvertTo-Json -Depth 4 -Compress))
        )
        $escapedModule = $script:CodexFinishModulePath.Replace("'", "''")
        $command = @"
`$ErrorActionPreference = 'SilentlyContinue'
`$json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$base64'))
`$work = `$json | ConvertFrom-Json
Import-Module '$escapedModule' -Force
for (`$attempt = 0; `$attempt -lt 30; `$attempt++) {
    `$removed = Remove-CodexFinishProjectMonitorSession -Event `$work.event -StateDirectory ([string]`$work.stateDirectory) -MonitorLockTimeoutMilliseconds 1000
    if (`$removed.Updated) { break }
    Start-Sleep -Milliseconds 250
}
"@
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $null = Start-Process `
            -FilePath (Get-Command powershell.exe -ErrorAction Stop).Source `
            -ArgumentList @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy',
                'Bypass', '-EncodedCommand', $encoded
            ) `
            -WindowStyle Hidden
        return $true
    }
    catch {
        return $false
    }
}

function Get-CodexFinishStoppedProjectRecoveryEvent {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Event,
        [string] $StateDirectory
    )

    $projectKey = Get-CodexFinishProjectKey -Event $Event
    if ([string]::IsNullOrWhiteSpace($projectKey)) {
        return $null
    }
    $resolvedState = Resolve-CodexFinishStateDirectory -StateDirectory $StateDirectory
    $stopped = New-Object Collections.Generic.List[object]
    foreach ($lifecyclePath in @([IO.Directory]::EnumerateFiles($resolvedState, '*.lifecycle.json'))) {
        $lifecycle = Read-CodexFinishLifecycleState -Path $lifecyclePath
        if ($null -eq $lifecycle) { continue }
        if ([string](Get-CodexFinishProperty -InputObject $lifecycle -Name 'rootStatus') -ceq 'ended') {
            continue
        }
        $lifecycleEvent = [pscustomobject]@{
            cwd        = [string](Get-CodexFinishProperty -InputObject $lifecycle -Name 'cwd')
            session_id = [string](Get-CodexFinishProperty -InputObject $lifecycle -Name 'sessionId')
        }
        if ((Get-CodexFinishProjectKey -Event $lifecycleEvent) -cne $projectKey) {
            continue
        }
        if (
            [string](Get-CodexFinishProperty -InputObject $lifecycle -Name 'rootStatus') -cne 'stopped' -or
            @(Get-CodexFinishActiveSubagentIds -LifecycleState $lifecycle).Count -gt 0
        ) {
            # Recovery is safe only when every remaining session in this
            # project is already idle.  A later Stop will create its own
            # authoritative candidate for any running session.
            return $null
        }
        $turnId = [string](Get-CodexFinishProperty -InputObject $lifecycle -Name 'lastStopTurnId')
        if ([string]::IsNullOrWhiteSpace($turnId)) {
            $turnId = [string](Get-CodexFinishProperty -InputObject $lifecycle -Name 'currentTurnId')
        }
        if ([string]::IsNullOrWhiteSpace($turnId)) {
            return $null
        }
        $stopped.Add([pscustomobject]@{
            session_id     = [string](Get-CodexFinishProperty -InputObject $lifecycle -Name 'sessionId')
            turn_id        = $turnId
            cwd            = [string](Get-CodexFinishProperty -InputObject $lifecycle -Name 'cwd')
            hook_event_name = 'Stop'
            observedUtc    = [string](Get-CodexFinishProperty -InputObject $lifecycle -Name 'updatedUtc')
        })
    }
    if ($stopped.Count -eq 0) {
        return $null
    }
    return $stopped.ToArray() |
        Sort-Object @{ Expression = { ConvertFrom-CodexFinishUtcText $_.observedUtc }; Descending = $true } |
        Select-Object -First 1
}

function ConvertTo-CodexFinishAgentTitle {
    param([string] $Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    # These blocks describe the host, not the current user task. Never persist
    # their contents as a task title. Limit work even for very large prompts.
    $textWindow = $Text.Substring(0, [Math]::Min($Text.Length, 65536))
    if ($textWindow -match '^\s*#\s*(AGENTS\.md instructions|Skill instructions)') { return '' }
    $textWindow = [regex]::Replace($textWindow,
        '(?is)<(environment_context|recommended_plugins|skills_instructions|permissions|permissions_instructions|INSTRUCTIONS|collaboration_mode|user_instructions|system_instructions)\b[^>]*>.*?(</\1\s*>|$)', '')
    foreach ($line in @($textWindow -split '\r?\n')) {
        $candidate = [regex]::Replace($line, '<[^>]*>', '').Trim()
        $candidate = [regex]::Replace($candidate, '^[#>*\-\s]+', '')
        $candidate = [regex]::Replace($candidate, '[\p{Cc}\p{Cf}]', ' ')
        $candidate = [regex]::Replace($candidate, '\s+', ' ').Trim()
        if ([string]::IsNullOrWhiteSpace($candidate) -or $candidate -match '^`{3}') { continue }
        $offset = 0
        $characters = 0
        $lastOffset = 0
        while ($offset -lt $candidate.Length -and $characters -lt 80) {
            $lastOffset = $offset
            if ([char]::IsHighSurrogate($candidate[$offset]) -and
                ($offset + 1) -lt $candidate.Length -and
                [char]::IsLowSurrogate($candidate[$offset + 1])) { $offset += 2 }
            else { $offset++ }
            $characters++
        }
        if ($offset -lt $candidate.Length) { return $candidate.Substring(0, $lastOffset) + '…' }
        return $candidate
    }
    return ''
}

function New-CodexFinishAgentDetail {
    param([string] $AgentId, [string] $SessionId, [string] $Role,
        [string] $Status = 'unknown', [string] $UpdatedAtUtc = '')

    return [pscustomobject][ordered]@{
        agentId = $AgentId
        parentAgentId = if ($Role -ceq 'main') { '' } else { $SessionId }
        role = $Role
        agentType = ''
        taskTitle = ''
        titleSource = ''
        status = $Status
        turnId = ''
        startedAtUtc = ''
        updatedAtUtc = $UpdatedAtUtc
        transcriptPath = ''
    }
}

function Select-CodexFinishRetainedAgentDetails {
    param([object[]] $Details = @())

    $retained = New-Object Collections.Generic.List[object]
    $ordered = @($Details | Sort-Object `
        @{ Expression = { if ($_.role -ceq 'main') { 0 } elseif ($_.status -ceq 'running') { 1 } else { 2 } }; Ascending = $true }, `
        @{ Expression = { ConvertFrom-CodexFinishUtcText $_.updatedAtUtc }; Descending = $true })
    foreach ($detail in $ordered) {
        # The history budget must never hide observed running work. Main and
        # running agents may exceed 100; older history fills only spare slots.
        if ($detail.role -ceq 'main' -or $detail.status -ceq 'running' -or $retained.Count -lt 100) {
            $retained.Add($detail)
        }
    }
    return [object[]]$retained.ToArray()
}

function Get-CodexFinishLifecycleAgentDetails {
    param([object] $LifecycleState)

    $sessionId = [string](Get-CodexFinishProperty -InputObject $LifecycleState -Name 'sessionId')
    if ([string]::IsNullOrWhiteSpace($sessionId)) { return @() }
    $details = New-Object Collections.Generic.List[object]
    $seen = @{}
    foreach ($source in @(Get-CodexFinishProperty -InputObject $LifecycleState -Name 'agentDetails' -DefaultValue @())) {
        $id = [string](Get-CodexFinishProperty -InputObject $source -Name 'agentId')
        if ([string]::IsNullOrWhiteSpace($id) -or $seen.ContainsKey($id)) { continue }
        $role = if ($id -ceq $sessionId) { 'main' } else { 'subagent' }
        $detail = New-CodexFinishAgentDetail -AgentId $id -SessionId $sessionId -Role $role
        foreach ($name in @('agentType', 'turnId', 'startedAtUtc', 'updatedAtUtc', 'transcriptPath')) {
            $detail.$name = [string](Get-CodexFinishProperty -InputObject $source -Name $name)
        }
        $status = [string](Get-CodexFinishProperty -InputObject $source -Name 'status')
        if ($status -in @('running', 'stopped', 'ended', 'unknown')) { $detail.status = $status }
        $detail.taskTitle = ConvertTo-CodexFinishAgentTitle -Text ([string](Get-CodexFinishProperty -InputObject $source -Name 'taskTitle'))
        $titleSource = [string](Get-CodexFinishProperty -InputObject $source -Name 'titleSource')
        if ($detail.taskTitle -and $titleSource -in @('prompt', 'explicit')) { $detail.titleSource = $titleSource }
        $details.Add($detail)
        $seen[$id] = $true
    }
    $updated = [string](Get-CodexFinishProperty -InputObject $LifecycleState -Name 'updatedUtc')
    if (-not $seen.ContainsKey($sessionId)) {
        $root = New-CodexFinishAgentDetail -AgentId $sessionId -SessionId $sessionId -Role main -UpdatedAtUtc $updated
        $rootStatus = [string](Get-CodexFinishProperty -InputObject $LifecycleState -Name 'rootStatus')
        if ($rootStatus -in @('stopped', 'ended')) { $root.status = $rootStatus }
        elseif ([string](Get-CodexFinishProperty -InputObject $LifecycleState -Name 'lastEventName') -ceq 'UserPromptSubmit') {
            $root.status = 'running'
        }
        $root.turnId = [string](Get-CodexFinishProperty -InputObject $LifecycleState -Name 'currentTurnId')
        $root.transcriptPath = [string](Get-CodexFinishProperty -InputObject $LifecycleState -Name 'transcriptPath')
        $details.Insert(0, $root)
        $seen[$sessionId] = $true
    }
    # Legacy active IDs prove an observed identity, not that it is still running.
    foreach ($id in @(Get-CodexFinishActiveSubagentIds -LifecycleState $LifecycleState)) {
        if (-not $seen.ContainsKey($id)) {
            $details.Add((New-CodexFinishAgentDetail -AgentId $id -SessionId $sessionId -Role subagent -UpdatedAtUtc $updated))
            $seen[$id] = $true
        }
    }
    return Select-CodexFinishRetainedAgentDetails -Details $details.ToArray()
}

function Update-CodexFinishAgentDetails {
    param([object] $LifecycleState, [object] $HookEvent, [string] $NowUtc)

    $eventName = [string](Get-CodexFinishProperty -InputObject $HookEvent -Name 'hook_event_name')
    $sessionId = [string](Get-CodexFinishProperty -InputObject $HookEvent -Name 'session_id')
    $agentId = [string](Get-CodexFinishProperty -InputObject $HookEvent -Name 'agent_id')
    $turnId = [string](Get-CodexFinishProperty -InputObject $HookEvent -Name 'turn_id')
    $details = New-Object Collections.Generic.List[object]
    foreach ($detail in @(Get-CodexFinishLifecycleAgentDetails -LifecycleState $LifecycleState)) { $details.Add($detail) }
    $root = @($details | Where-Object { $_.agentId -ceq $sessionId }) | Select-Object -First 1
    if ($null -eq $root) {
        $root = New-CodexFinishAgentDetail -AgentId $sessionId -SessionId $sessionId -Role main
        $details.Insert(0, $root)
    }
    $transcript = [string](Get-CodexFinishProperty -InputObject $HookEvent -Name 'transcript_path')
    if ($eventName -notin @('SubagentStart', 'SubagentStop') -and
        -not [string]::IsNullOrWhiteSpace($transcript)) { $root.transcriptPath = $transcript }

    if ($eventName -ceq 'SessionEnd') {
        foreach ($detail in $details) { $detail.status = 'ended'; $detail.updatedAtUtc = $NowUtc }
    }
    elseif ($eventName -ceq 'SessionStart') {
        $source = [string](Get-CodexFinishProperty -InputObject $HookEvent -Name 'source')
        if ($source -cne 'compact') {
            foreach ($detail in $details) {
                if ($detail.status -ceq 'running') { $detail.status = 'unknown'; $detail.updatedAtUtc = $NowUtc }
            }
            $root.status = 'unknown'
            $root.updatedAtUtc = $NowUtc
        }
    }
    elseif ($eventName -in @('SubagentStart', 'SubagentStop')) {
        if (-not [string]::IsNullOrWhiteSpace($agentId) -and $agentId -cne $sessionId) {
            $child = @($details | Where-Object { $_.agentId -ceq $agentId }) | Select-Object -First 1
            if ($null -eq $child) {
                $child = New-CodexFinishAgentDetail -AgentId $agentId -SessionId $sessionId -Role subagent
                $details.Add($child)
            }
            if ($eventName -ceq 'SubagentStart') {
                $child.startedAtUtc = $NowUtc
                $child.taskTitle = ''
                $child.titleSource = ''
                $child.status = 'running'
            }
            else { $child.status = 'stopped' }
            $child.updatedAtUtc = $NowUtc
            if ($turnId) { $child.turnId = $turnId }
            $agentType = [string](Get-CodexFinishProperty -InputObject $HookEvent -Name 'agent_type')
            if ($agentType) { $child.agentType = $agentType }
            $childTranscript = [string](Get-CodexFinishProperty -InputObject $HookEvent -Name 'agent_transcript_path')
            if (-not $childTranscript) { $childTranscript = $transcript }
            if ($childTranscript) { $child.transcriptPath = $childTranscript }
            foreach ($field in @('task_title', 'title')) {
                $title = ConvertTo-CodexFinishAgentTitle -Text ([string](Get-CodexFinishProperty -InputObject $HookEvent -Name $field))
                if ($title) { $child.taskTitle = $title; $child.titleSource = 'explicit'; break }
            }
        }
    }
    else {
        $root.updatedAtUtc = $NowUtc
        if ($turnId) { $root.turnId = $turnId }
        if ($eventName -ceq 'Stop') { $root.status = 'stopped' }
        elseif ($eventName -ceq 'UserPromptSubmit') {
            $root.status = 'running'
            # Older Hook producers may omit turn_id. A new task must not
            # inherit the previous turn's identity or transcript title lookup.
            $root.turnId = $turnId
            $root.startedAtUtc = $NowUtc
            $root.taskTitle = ''
            $root.titleSource = ''
            foreach ($field in @('task_title', 'title', 'prompt')) {
                $title = ConvertTo-CodexFinishAgentTitle -Text ([string](Get-CodexFinishProperty -InputObject $HookEvent -Name $field))
                if ($title) {
                    $root.taskTitle = $title
                    $root.titleSource = if ($field -ceq 'prompt') { 'prompt' } else { 'explicit' }
                    break
                }
            }
        }
    }
    # Display history never feeds the completion guard.
    return Select-CodexFinishRetainedAgentDetails -Details $details.ToArray()
}

function Add-CodexFinishProjectMonitorAgentDetails {
    param([object] $MonitorState, [string] $StateDirectory)

    # Enrich only the published display model. Session/project completion stays
    # authoritative for reminders and is never inferred from these agent rows.
    foreach ($project in @(Get-CodexFinishProperty -InputObject $MonitorState -Name 'projects' -DefaultValue @())) {
        foreach ($session in @(Get-CodexFinishProperty -InputObject $project -Name 'sessions' -DefaultValue @())) {
            $hash = [string](Get-CodexFinishProperty -InputObject $session -Name 'threadHash')
            if ($hash -notmatch '^[0-9a-fA-F]{64}$') { continue }
            $lifecycle = Read-CodexFinishLifecycleState -Path (Join-Path $StateDirectory ($hash + '.lifecycle.json'))
            if ($null -eq $lifecycle) { continue }
            Set-CodexFinishProperty -InputObject $session -Name 'sessionId' -Value ([string](Get-CodexFinishProperty -InputObject $lifecycle -Name 'sessionId'))
            Set-CodexFinishProperty -InputObject $session -Name 'transcriptPath' -Value ([string](Get-CodexFinishProperty -InputObject $lifecycle -Name 'transcriptPath'))
            Set-CodexFinishProperty -InputObject $session -Name 'agents' -Value ([object[]]@(Get-CodexFinishLifecycleAgentDetails -LifecycleState $lifecycle))
        }
    }
    return $MonitorState
}

function Get-CodexFinishActiveSubagentIds {
    param(
        [object] $LifecycleState
    )

    $ids = New-Object Collections.Generic.List[string]
    foreach ($value in @(
        Get-CodexFinishProperty `
            -InputObject $LifecycleState `
            -Name 'activeSubagentIds' `
            -DefaultValue @()
    )) {
        $id = [string] $value
        if (-not [string]::IsNullOrWhiteSpace($id) -and -not $ids.Contains($id)) {
            $ids.Add($id)
        }
    }
    return [string[]] $ids.ToArray()
}

function Update-CodexFinishLifecycleState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object] $HookEvent,
        [string] $StateDirectory,
        [ValidateRange(50, 60000)]
        [int] $LockTimeoutMilliseconds = 10000,
        [switch] $SkipDirtyReplay
    )

    $eventName = [string] (
        Get-CodexFinishProperty -InputObject $HookEvent -Name 'hook_event_name'
    )
    if ($eventName -notin @(
        'SessionStart',
        'UserPromptSubmit',
        'SubagentStart',
        'SubagentStop',
        'Stop',
        'SessionEnd'
    )) {
        return [pscustomobject]@{ Updated = $false; Reason = 'unsupported-hook-event' }
    }

    $projectActivityResult = $null
    if ($eventName -in @('SessionStart', 'UserPromptSubmit', 'SubagentStart', 'SubagentStop', 'SessionEnd')) {
        # Invalidate at project scope before updating this thread. This ordering
        # closes the cross-session race where a short task could both start and
        # stop inside another session's quiet window.
        $projectActivityResult = Invalidate-CodexFinishProjectPendingCandidate `
            -Event $HookEvent `
            -ActivityName $eventName `
            -StateDirectory $StateDirectory `
            -LockTimeoutMilliseconds $LockTimeoutMilliseconds
    }

    $paths = Resolve-CodexFinishThreadStatePaths `
        -Event $HookEvent `
        -StateDirectory $StateDirectory
    if ($null -eq $paths) {
        return [pscustomobject]@{ Updated = $false; Reason = 'invalid-session-id' }
    }

    $lockStream = Open-CodexFinishStateLock `
        -Path $paths.LockPath `
        -TimeoutMilliseconds $LockTimeoutMilliseconds
    if ($null -eq $lockStream) {
        return [pscustomobject]@{ Updated = $false; Reason = 'state-lock-unavailable' }
    }

    $lifecycleResult = $null
    try {
        $existing = Read-CodexFinishLifecycleState -Path $paths.LifecyclePath
        $revision = 0
        if ($null -ne $existing) {
            try { $revision = [Math]::Max(0, [int]$existing.revision) } catch { $revision = 0 }
        }

        $sessionId = [string] (
            Get-CodexFinishProperty -InputObject $HookEvent -Name 'session_id'
        )
        $turnId = [string] (
            Get-CodexFinishProperty -InputObject $HookEvent -Name 'turn_id'
        )
        $agentId = [string] (
            Get-CodexFinishProperty -InputObject $HookEvent -Name 'agent_id'
        )
        $now = [DateTime]::UtcNow.ToString('o')
        $activeIds = New-Object Collections.Generic.List[string]
        foreach ($id in @(Get-CodexFinishActiveSubagentIds -LifecycleState $existing)) {
            $activeIds.Add($id)
        }

        $rootStatus = [string] (
            Get-CodexFinishProperty -InputObject $existing -Name 'rootStatus' -DefaultValue 'unknown'
        )
        $currentTurnId = [string] (
            Get-CodexFinishProperty -InputObject $existing -Name 'currentTurnId'
        )
        $lastStopTurnId = [string] (
            Get-CodexFinishProperty -InputObject $existing -Name 'lastStopTurnId'
        )
        $lastStopUtc = [string] (
            Get-CodexFinishProperty -InputObject $existing -Name 'lastStopUtc'
        )
        $lastActivityUtc = [string] (
            Get-CodexFinishProperty -InputObject $existing -Name 'lastActivityUtc'
        )

        switch ($eventName) {
            'Stop' {
                # Stop is evidence for one root turn. It does not announce and
                # it does not erase child agents that are still observable.
                $rootStatus = 'stopped'
                $currentTurnId = $turnId
                $lastStopTurnId = $turnId
                $lastStopUtc = $now
            }
            'SubagentStart' {
                $rootStatus = 'running'
                $currentTurnId = $turnId
                if (-not [string]::IsNullOrWhiteSpace($agentId) -and -not $activeIds.Contains($agentId)) {
                    $activeIds.Add($agentId)
                }
                $revision++
                $lastActivityUtc = $now
            }
            'SubagentStop' {
                # A child finishing after root Stop must not resurrect the root.
                # Preserve stopped until a real resume/prompt event arrives.
                if ($rootStatus -cne 'stopped') {
                    $rootStatus = 'running'
                }
                $currentTurnId = $turnId
                if (-not [string]::IsNullOrWhiteSpace($agentId)) {
                    $null = $activeIds.Remove($agentId)
                }
                $revision++
                $lastActivityUtc = $now
            }
            'SessionStart' {
                # A resumed/new session invalidates stale candidates and child
                # bookkeeping left by a process that did not shut down cleanly.
                # Compact is different: it can run mid-turn, so live child
                # identities must survive into the immediate continuation.
                $rootStatus = 'running'
                $currentTurnId = $turnId
                $sessionSource = [string] (
                    Get-CodexFinishProperty -InputObject $HookEvent -Name 'source'
                )
                if ($sessionSource -cne 'compact') {
                    $activeIds.Clear()
                }
                $revision++
                $lastActivityUtc = $now
            }
            'SessionEnd' {
                # SessionEnd is terminal for this thread.  Incrementing the
                # revision and clearing children makes every detached notify
                # or Stop-only worker fail closed, even if it already woke up.
                $rootStatus = 'ended'
                $activeIds.Clear()
                $revision++
                $lastActivityUtc = $now
            }
            default {
                # UserPromptSubmit is the stable turn-start signal. It catches
                # the short pause where a previous notify is already sleeping.
                $rootStatus = 'running'
                $currentTurnId = $turnId
                $revision++
                $lastActivityUtc = $now
            }
        }

        $agentDetails = @(Update-CodexFinishAgentDetails -LifecycleState $existing -HookEvent $HookEvent -NowUtc $now)
        $transcriptPath = if ($eventName -in @('SubagentStart', 'SubagentStop')) { '' }
        else { [string](Get-CodexFinishProperty -InputObject $HookEvent -Name 'transcript_path') }
        if ([string]::IsNullOrWhiteSpace($transcriptPath)) {
            $transcriptPath = [string](Get-CodexFinishProperty -InputObject $existing -Name 'transcriptPath')
        }
        $record = [ordered] @{
            schemaVersion      = 2
            threadHash         = $paths.ThreadHash
            sessionId          = $sessionId
            hookSeen           = $true
            revision           = $revision
            rootStatus         = $rootStatus
            currentTurnId      = $currentTurnId
            lastEventName      = $eventName
            lastActivityUtc    = $lastActivityUtc
            lastStopTurnId     = $lastStopTurnId
            lastStopUtc        = $lastStopUtc
            activeSubagentIds  = [string[]] $activeIds.ToArray()
            agentDetails       = [object[]] $agentDetails
            cwd                = [string] (
                Get-CodexFinishProperty -InputObject $HookEvent -Name 'cwd'
            )
            transcriptPath     = $transcriptPath
            endedUtc           = if ($eventName -ceq 'SessionEnd') { $now } else { $null }
            endReason          = if ($eventName -ceq 'SessionEnd') {
                [string](Get-CodexFinishProperty -InputObject $HookEvent -Name 'reason')
            }
            else { $null }
            updatedUtc         = $now
        }
        Write-CodexFinishUtf8File `
            -Path $paths.LifecyclePath `
            -Content (($record | ConvertTo-Json -Depth 6) + [Environment]::NewLine)

        if ($eventName -ceq 'SessionEnd') {
            # A pending notify worker holds no lock while sleeping.  Removing
            # its record under the thread lock prevents a later claim/audio.
            try { [IO.File]::Delete($paths.PendingPath) } catch { }
        }

        $lifecycleResult = [pscustomobject]@{
            Updated           = $true
            Reason            = 'updated'
            Revision          = $revision
            RootStatus        = $rootStatus
            ActiveSubagents   = $activeIds.Count
        }
    }
    catch {
        $lifecycleResult = [pscustomobject]@{ Updated = $false; Reason = 'lifecycle-state-write-failed' }
    }
    finally {
        $lockStream.Dispose()
    }

    # The cross-project lock is deliberately acquired only after releasing the
    # per-thread lock. Serial delivery is also performed by the caller after
    # this function returns, so no filesystem lock is held during I/O.
    if ($lifecycleResult.Updated) {
        if ($eventName -ceq 'SessionEnd') {
            $monitorResult = Remove-CodexFinishProjectMonitorSession `
                -Event $HookEvent `
                -StateDirectory $StateDirectory `
                -NowUtc ([DateTime]::Parse(
                    $now,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind
                )) `
                -MonitorLockTimeoutMilliseconds $LockTimeoutMilliseconds
            $removalRetryScheduled = $false
            if (-not $monitorResult.Updated) {
                $removalRetryScheduled = Start-CodexFinishProjectMonitorSessionRemovalRetry `
                    -Event $HookEvent `
                    -StateDirectory $StateDirectory
            }
            $lifecycleResult | Add-Member -NotePropertyName ProjectMonitorUpdated -NotePropertyValue ([bool]$monitorResult.Updated)
            $lifecycleResult | Add-Member -NotePropertyName ProjectMonitorReason -NotePropertyValue ([string]$monitorResult.Reason)
            $lifecycleResult | Add-Member -NotePropertyName ProjectMonitorState -NotePropertyValue $monitorResult.State
            $lifecycleResult | Add-Member -NotePropertyName ProjectSettling -NotePropertyValue $false
            $lifecycleResult | Add-Member -NotePropertyName ProjectAlreadyClaimed -NotePropertyValue $false
            $lifecycleResult | Add-Member `
                -NotePropertyName ProjectMonitorRemovalRetryScheduled `
                -NotePropertyValue ([bool]$removalRetryScheduled)
            $recoveryEvent = $null
            $endedProjectKey = Get-CodexFinishProjectKey -Event $HookEvent
            $remainingProject = @(
                @(Get-CodexFinishProperty `
                    -InputObject $monitorResult.State -Name 'projects' -DefaultValue @()) |
                    Where-Object { [string]$_.projectKey -ceq $endedProjectKey }
            ) | Select-Object -First 1
            if ($null -ne $remainingProject -and [string]$remainingProject.status -ceq 'running') {
                $recoveryEvent = Get-CodexFinishStoppedProjectRecoveryEvent `
                    -Event $HookEvent `
                    -StateDirectory $StateDirectory
            }
            $lifecycleResult | Add-Member `
                -NotePropertyName RecoverySettlementEvent `
                -NotePropertyValue $recoveryEvent
            if ($null -ne $projectActivityResult) {
                $lifecycleResult | Add-Member `
                    -NotePropertyName ProjectCandidateInvalidated `
                    -NotePropertyValue ([bool]$projectActivityResult.CandidateInvalidated)
                $lifecycleResult | Add-Member `
                    -NotePropertyName ProjectActivityReason `
                    -NotePropertyValue ([string]$projectActivityResult.Reason)
            }
            return $lifecycleResult
        }
        $logicallyCompleted = (
            [string]$lifecycleResult.RootStatus -ceq 'stopped' -and
            [int]$lifecycleResult.ActiveSubagents -eq 0
        )
        # Hooks never publish green directly. Stop may arrive before or after
        # notify; either way the project stays externally running/red until a
        # project-scoped candidate survives the full quiet window.
        $projectSettling = $logicallyCompleted
        $claimedCheck = $null
        if ($eventName -ceq 'Stop' -and $logicallyCompleted) {
            $claimedCheck = Test-CodexFinishProjectTurnAlreadyClaimed `
                -Event $HookEvent `
                -StateDirectory $StateDirectory `
                -LockTimeoutMilliseconds $LockTimeoutMilliseconds
        }
        $projectStatus = if ($null -ne $claimedCheck -and $claimedCheck.Matched) {
            # A Stop Hook can trail the authoritative notify callback. Preserve
            # that same session/turn's durable completion instead of painting
            # its monitor row red with no candidate left to recover it.
            'completed'
        }
        else {
            'running'
        }
        if ($null -ne $claimedCheck -and -not $claimedCheck.LockAcquired) {
            # Confirmation may currently own the settle lock. Do not race its
            # final green write with a later unconditional red write; the
            # detached Stop settlement re-evaluates this state after quiet.
            $monitorResult = [pscustomobject]@{
                Updated = $false
                Reason = $claimedCheck.Reason
                State = Get-CodexFinishProjectMonitorState -StateDirectory $StateDirectory
            }
        }
        else {
            $monitorResult = Update-CodexFinishProjectMonitorState `
                -Event $HookEvent `
                -Status $projectStatus `
                -StateDirectory $StateDirectory `
                -NowUtc ([DateTime]::Parse(
                    $now,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind
                )) `
                -MonitorLockTimeoutMilliseconds $LockTimeoutMilliseconds `
                -SkipDirtyReplay:$SkipDirtyReplay
        }
        $lifecycleResult | Add-Member -NotePropertyName ProjectMonitorUpdated -NotePropertyValue ([bool]$monitorResult.Updated)
        $lifecycleResult | Add-Member -NotePropertyName ProjectMonitorReason -NotePropertyValue ([string]$monitorResult.Reason)
        $lifecycleResult | Add-Member -NotePropertyName ProjectMonitorState -NotePropertyValue $monitorResult.State
        $lifecycleResult | Add-Member -NotePropertyName ProjectSettling -NotePropertyValue $projectSettling
        $lifecycleResult | Add-Member `
            -NotePropertyName ProjectAlreadyClaimed `
            -NotePropertyValue ([bool]($null -ne $claimedCheck -and $claimedCheck.Matched))
        if ($null -ne $projectActivityResult) {
            $lifecycleResult | Add-Member `
                -NotePropertyName ProjectCandidateInvalidated `
                -NotePropertyValue ([bool]$projectActivityResult.CandidateInvalidated)
            $lifecycleResult | Add-Member `
                -NotePropertyName ProjectActivityReason `
                -NotePropertyValue ([string]$projectActivityResult.Reason)
        }
    }

    return $lifecycleResult
}

function Register-CodexFinishPendingTurn {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Event,
        [string] $StateDirectory,
        [ValidateSet('require', 'prefer', 'off')]
        [string] $LifecycleMode = 'require',
        [switch] $StopOnly,
        [switch] $OnlyIfVacant,
        [string] $ObservedUtc
    )

    $paths = Resolve-CodexFinishThreadStatePaths -Event $Event -StateDirectory $StateDirectory
    if ($null -eq $paths) {
        return [pscustomobject]@{
            Recorded                = $false
            Reason                  = 'invalid-thread-state'
            AuthoritativeRootNotify = $false
        }
    }

    $lockStream = Open-CodexFinishStateLock -Path $paths.LockPath
    if ($null -eq $lockStream) {
        return [pscustomobject]@{
            Recorded                = $false
            Reason                  = 'state-lock-unavailable'
            AuthoritativeRootNotify = $false
        }
    }

    try {
        if ($StopOnly) {
            # Stop-only fallback is never allowed to weaken lifecycle
            # validation from user settings or replace an official notify.
            $LifecycleMode = 'require'
            $OnlyIfVacant = $true
        }
        $turnId = [string] (Get-CodexFinishProperty -InputObject $Event -Name 'turn-id')
        $turnHash = Get-CodexFinishTurnHash -Event $Event
        if (
            -not [string]::IsNullOrWhiteSpace($turnHash) -and
            [IO.File]::Exists((Join-Path $paths.StateDirectory ($turnHash + '.done')))
        ) {
            return [pscustomobject]@{
                Recorded                = $false
                Reason                  = 'duplicate-turn'
                AuthoritativeRootNotify = $false
            }
        }
        if ($StopOnly -and [string]::IsNullOrWhiteSpace($ObservedUtc)) {
            return [pscustomobject]@{
                Recorded = $false; Reason = 'candidate-time-invalid'; AuthoritativeRootNotify = $false
            }
        }
        $candidateObserved = if ([string]::IsNullOrWhiteSpace($ObservedUtc)) {
            [DateTime]::UtcNow
        }
        else {
            ConvertFrom-CodexFinishUtcText $ObservedUtc
        }
        if ($candidateObserved -eq [DateTime]::MinValue) {
            return [pscustomobject]@{
                Recorded = $false; Reason = 'candidate-time-invalid'; AuthoritativeRootNotify = $false
            }
        }
        $candidateObservedText = $candidateObserved.ToUniversalTime().ToString('o')

        if ($OnlyIfVacant -and [IO.File]::Exists($paths.PendingPath)) {
            try {
                $existingPending = [IO.File]::ReadAllText($paths.PendingPath) | ConvertFrom-Json -ErrorAction Stop
                $existingCandidateId = [string](Get-CodexFinishProperty `
                    -InputObject $existingPending -Name 'candidateId')
                $existingObserved = ConvertFrom-CodexFinishUtcText (
                    Get-CodexFinishProperty -InputObject $existingPending -Name 'observedUtc'
                )
                if (
                    -not [string]::IsNullOrWhiteSpace($existingCandidateId) -and
                    $existingObserved -ge [DateTime]::UtcNow.AddMinutes(-5)
                ) {
                    return [pscustomobject]@{
                        Recorded = $false
                        Reason = 'thread-candidate-already-pending'
                        AuthoritativeRootNotify = $false
                    }
                }
            }
            catch {
                # An invalid legacy pending record is replaced only after the
                # strict lifecycle checks below succeed.
            }
        }
        $lifecycle = Read-CodexFinishLifecycleState -Path $paths.LifecyclePath
        $guardUsed = $false
        $authoritativeRootNotify = $false
        if ($LifecycleMode -ne 'off') {
            if ($null -eq $lifecycle) {
                if ($LifecycleMode -eq 'require') {
                    return [pscustomobject]@{
                        Recorded                = $false
                        Reason                  = 'lifecycle-state-missing'
                        AuthoritativeRootNotify = $false
                    }
                }
            }
            else {
                $guardUsed = $true
                $notifyThreadId = [string] (
                    Get-CodexFinishProperty -InputObject $Event -Name 'thread-id'
                )
                $lifecycleSessionId = [string] (
                    Get-CodexFinishProperty -InputObject $lifecycle -Name 'sessionId'
                )
                $rootSessionMatches = (
                    -not [string]::IsNullOrWhiteSpace($notifyThreadId) -and
                    -not [string]::IsNullOrWhiteSpace($lifecycleSessionId) -and
                    $notifyThreadId -ceq $lifecycleSessionId
                )
                if (-not $rootSessionMatches) {
                    return [pscustomobject]@{
                        Recorded                = $false
                        Reason                  = 'non-root-notify'
                        AuthoritativeRootNotify = $false
                    }
                }
                if ($StopOnly) {
                    if (@(Get-CodexFinishActiveSubagentIds -LifecycleState $lifecycle).Count -gt 0) {
                        return [pscustomobject]@{
                            Recorded = $false; Reason = 'subagent-still-active'
                            AuthoritativeRootNotify = $false
                        }
                    }
                    if (
                        [string](Get-CodexFinishProperty -InputObject $lifecycle -Name 'rootStatus') -cne 'stopped' -or
                        [string](Get-CodexFinishProperty -InputObject $lifecycle -Name 'lastStopTurnId') -cne $turnId
                    ) {
                        return [pscustomobject]@{
                            Recorded = $false; Reason = 'root-turn-still-running'
                            AuthoritativeRootNotify = $false
                        }
                    }

                    # The detached wrapper observed Stop before it slept.  A
                    # newer lifecycle boundary in any same-project session
                    # owns the quiet window; running/child activity must not
                    # leave a stop-only pending record that blocks that owner.
                    $candidateProjectKey = Get-CodexFinishProjectKey -Event $Event
                    foreach ($otherLifecyclePath in @(
                        [IO.Directory]::EnumerateFiles($paths.StateDirectory, '*.lifecycle.json')
                    )) {
                        $otherLifecycle = Read-CodexFinishLifecycleState -Path $otherLifecyclePath
                        if ($null -eq $otherLifecycle) { continue }
                        if ([string](Get-CodexFinishProperty `
                            -InputObject $otherLifecycle -Name 'rootStatus') -ceq 'ended') { continue }
                        $otherEvent = [pscustomobject]@{
                            cwd = [string](Get-CodexFinishProperty -InputObject $otherLifecycle -Name 'cwd')
                            session_id = [string](Get-CodexFinishProperty -InputObject $otherLifecycle -Name 'sessionId')
                        }
                        if ((Get-CodexFinishProjectKey -Event $otherEvent) -cne $candidateProjectKey) { continue }
                        if (@(Get-CodexFinishActiveSubagentIds -LifecycleState $otherLifecycle).Count -gt 0) {
                            return [pscustomobject]@{
                                Recorded = $false; Reason = 'project-subagent-still-active'
                                AuthoritativeRootNotify = $false
                            }
                        }
                        if ([string](Get-CodexFinishProperty `
                            -InputObject $otherLifecycle -Name 'rootStatus') -cne 'stopped') {
                            return [pscustomobject]@{
                                Recorded = $false; Reason = 'project-session-still-running'
                                AuthoritativeRootNotify = $false
                            }
                        }
                        $otherUpdated = ConvertFrom-CodexFinishUtcText (
                            Get-CodexFinishProperty -InputObject $otherLifecycle -Name 'updatedUtc'
                        )
                        if ($otherUpdated -gt $candidateObserved) {
                            return [pscustomobject]@{
                                Recorded = $false; Reason = 'project-lifecycle-after-stop-candidate'
                                AuthoritativeRootNotify = $false
                            }
                        }
                    }
                    $authoritativeRootNotify = $false
                }
                else {
                    $lifecycleTurnId = [string] (
                        Get-CodexFinishProperty -InputObject $lifecycle -Name 'currentTurnId'
                    )
                    $authoritativeRootNotify = (
                        [string]::IsNullOrWhiteSpace($lifecycleTurnId) -or
                        $lifecycleTurnId -ceq $turnId
                    )
                    if (-not $authoritativeRootNotify) {
                        return [pscustomobject]@{
                            Recorded                = $false
                            Reason                  = 'root-turn-still-running'
                            AuthoritativeRootNotify = $false
                        }
                    }
                    # Persist the matching root notify as this session's idle
                    # boundary. This lets a later same-project candidate see
                    # that an earlier session is already finished even when
                    # Codex never emits its Stop Hook (or retains reusable
                    # subagent identities). A later activity Hook increments
                    # revision and restores running before confirmation.
                    $notifyCompletedUtc = [DateTime]::UtcNow.ToString('o')
                    Set-CodexFinishProperty -InputObject $lifecycle -Name 'rootStatus' -Value 'stopped'
                    Set-CodexFinishProperty -InputObject $lifecycle -Name 'currentTurnId' -Value $turnId
                    Set-CodexFinishProperty -InputObject $lifecycle -Name 'lastStopTurnId' -Value $turnId
                    Set-CodexFinishProperty -InputObject $lifecycle -Name 'lastStopUtc' -Value $notifyCompletedUtc
                    Set-CodexFinishProperty -InputObject $lifecycle -Name 'lastEventName' -Value 'RootNotifyComplete'
                    # This validated same-session/turn notify is direct root
                    # stop evidence. It says nothing about each reusable child.
                    $notifyAgentDetails = @(Update-CodexFinishAgentDetails `
                        -LifecycleState $lifecycle `
                        -HookEvent ([pscustomobject]@{
                            hook_event_name = 'Stop'
                            session_id = [string](Get-CodexFinishProperty -InputObject $lifecycle -Name 'sessionId')
                            turn_id = $turnId
                        }) `
                        -NowUtc $notifyCompletedUtc)
                    Set-CodexFinishProperty -InputObject $lifecycle -Name 'agentDetails' -Value ([object[]]$notifyAgentDetails)
                    Set-CodexFinishProperty -InputObject $lifecycle -Name 'activeSubagentIds' -Value ([string[]]@())
                    Set-CodexFinishProperty -InputObject $lifecycle -Name 'updatedUtc' -Value $notifyCompletedUtc
                    Write-CodexFinishUtf8File `
                        -Path $paths.LifecyclePath `
                        -Content (($lifecycle | ConvertTo-Json -Depth 6) + [Environment]::NewLine)
                }
            }
        }

        # candidateId, rather than turnHash, is the debounce generation. A
        # repeated callback for the same turn therefore restarts the window.
        $candidateId = [Guid]::NewGuid().ToString('N')
        $record = [ordered] @{
            schemaVersion     = 2
            candidateId       = $candidateId
            threadHash        = $paths.ThreadHash
            threadId          = [string] (Get-CodexFinishProperty -InputObject $Event -Name 'thread-id')
            client            = [string] (Get-CodexFinishProperty -InputObject $Event -Name 'client')
            cwd               = [string] (Get-CodexFinishProperty -InputObject $Event -Name 'cwd')
            turnId            = $turnId
            turnHash          = $turnHash
            lifecycleMode     = $LifecycleMode
            lifecycleGuardUsed = $guardUsed
            authoritativeRootNotify = $authoritativeRootNotify
            stopOnlyCandidate = [bool]$StopOnly
            lifecycleRevision = if ($guardUsed) { [int]$lifecycle.revision } else { -1 }
            observedUtc       = $candidateObservedText
        }
        $json = ($record | ConvertTo-Json -Depth 4) + [Environment]::NewLine
        Write-CodexFinishUtf8File -Path $paths.PendingPath -Content $json
        $projectPending = Register-CodexFinishProjectPendingCandidate `
            -Event $Event `
            -CandidateId $candidateId `
            -ObservedUtc $record.observedUtc `
            -LifecycleGuardUsed $guardUsed `
            -AuthoritativeRootNotify $authoritativeRootNotify `
            -StateDirectory $paths.StateDirectory `
            -OnlyIfVacant:$OnlyIfVacant
        if (-not $projectPending.Recorded) {
            try {
                [IO.File]::Delete($paths.PendingPath)
            }
            catch {
                # A later candidate safely replaces the stale thread record.
            }
            return [pscustomobject]@{
                Recorded                = $false
                Reason                  = $projectPending.Reason
                AuthoritativeRootNotify = $authoritativeRootNotify
            }
        }
        return [pscustomobject]@{
            Recorded                = $true
            Reason                  = 'recorded'
            TurnId                  = $record.turnId
            CandidateId             = $candidateId
            ObservedUtc              = $record.observedUtc
            LifecycleGuardUsed      = $guardUsed
            ProjectActivityRevision = $projectPending.ActivityRevision
            AuthoritativeRootNotify = $authoritativeRootNotify
        }
    }
    catch {
        return [pscustomobject]@{
            Recorded                = $false
            Reason                  = 'pending-state-write-failed'
            Error                   = $_.Exception.Message
            AuthoritativeRootNotify = $false
        }
    }
    finally {
        $lockStream.Dispose()
    }
}

function Confirm-CodexFinishPendingTurn {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Event,
        [Parameter(Mandatory = $true)]
        [string] $CandidateId,
        [string] $StateDirectory
    )

    $paths = Resolve-CodexFinishThreadStatePaths -Event $Event -StateDirectory $StateDirectory
    if ($null -eq $paths) {
        return [pscustomobject]@{
            Claimed                 = $false
            Reason                  = 'invalid-thread-state'
            NewerTurnId             = $null
            AuthoritativeRootNotify = $false
        }
    }

    $lockStream = Open-CodexFinishStateLock -Path $paths.LockPath
    if ($null -eq $lockStream) {
        return [pscustomobject]@{
            Claimed                 = $false
            Reason                  = 'state-lock-unavailable'
            NewerTurnId             = $null
            AuthoritativeRootNotify = $false
        }
    }

    try {
        if (-not [IO.File]::Exists($paths.PendingPath)) {
            return [pscustomobject]@{
                Claimed                 = $false
                Reason                  = 'pending-state-missing'
                NewerTurnId             = $null
                AuthoritativeRootNotify = $false
            }
        }

        try {
            $pending = [IO.File]::ReadAllText($paths.PendingPath) | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            return [pscustomobject]@{
                Claimed                 = $false
                Reason                  = 'pending-state-invalid'
                NewerTurnId             = $null
                AuthoritativeRootNotify = $false
            }
        }

        # Pending records written before the root-notify compatibility update
        # have no authoritativeRootNotify field and retain the strict checks.
        $authoritativeRootNotify = ConvertTo-CodexFinishBoolean `
            -Value (Get-CodexFinishProperty `
                -InputObject $pending `
                -Name 'authoritativeRootNotify' `
                -DefaultValue $false) `
            -DefaultValue $false

        if ([string]$pending.candidateId -cne $CandidateId) {
            return [pscustomobject]@{
                Claimed                 = $false
                Reason                  = 'superseded-by-newer-candidate'
                NewerTurnId             = [string]$pending.turnId
                AuthoritativeRootNotify = $authoritativeRootNotify
            }
        }

        $turnHash = Get-CodexFinishTurnHash -Event $Event
        if ([string]$pending.turnHash -cne $turnHash) {
            return [pscustomobject]@{
                Claimed                 = $false
                Reason                  = 'superseded-by-newer-turn'
                NewerTurnId             = [string]$pending.turnId
                AuthoritativeRootNotify = $authoritativeRootNotify
            }
        }

        $mode = [string] (
            Get-CodexFinishProperty -InputObject $pending -Name 'lifecycleMode' -DefaultValue 'require'
        )
        $guardUsed = [bool] (
            Get-CodexFinishProperty -InputObject $pending -Name 'lifecycleGuardUsed' -DefaultValue $false
        )
        if ($mode -ne 'off' -and $guardUsed) {
            $lifecycle = Read-CodexFinishLifecycleState -Path $paths.LifecyclePath
            if ($null -eq $lifecycle) {
                return [pscustomobject]@{
                    Claimed = $false; Reason = 'lifecycle-state-missing'; NewerTurnId = $null
                    AuthoritativeRootNotify = $authoritativeRootNotify
                }
            }
            if ([int]$lifecycle.revision -ne [int]$pending.lifecycleRevision) {
                return [pscustomobject]@{
                    Claimed = $false; Reason = 'activity-after-candidate'; NewerTurnId = [string]$lifecycle.currentTurnId
                    AuthoritativeRootNotify = $authoritativeRootNotify
                }
            }
            if ($authoritativeRootNotify) {
                $notifyThreadId = [string] (
                    Get-CodexFinishProperty -InputObject $Event -Name 'thread-id'
                )
                $notifyTurnId = [string] (
                    Get-CodexFinishProperty -InputObject $Event -Name 'turn-id'
                )
                $lifecycleSessionId = [string] (
                    Get-CodexFinishProperty -InputObject $lifecycle -Name 'sessionId'
                )
                if (
                    [string]::IsNullOrWhiteSpace($notifyThreadId) -or
                    [string]::IsNullOrWhiteSpace($lifecycleSessionId) -or
                    $notifyThreadId -cne $lifecycleSessionId
                ) {
                    return [pscustomobject]@{
                        Claimed = $false; Reason = 'root-session-mismatch'; NewerTurnId = $null
                        AuthoritativeRootNotify = $true
                    }
                }
                $lifecycleTurnId = [string] (
                    Get-CodexFinishProperty -InputObject $lifecycle -Name 'currentTurnId'
                )
                if (
                    -not [string]::IsNullOrWhiteSpace($lifecycleTurnId) -and
                    $lifecycleTurnId -cne $notifyTurnId
                ) {
                    return [pscustomobject]@{
                        Claimed = $false; Reason = 'root-turn-mismatch'; NewerTurnId = $lifecycleTurnId
                        AuthoritativeRootNotify = $true
                    }
                }
            }
            if (-not $authoritativeRootNotify) {
                if (
                    [string]$lifecycle.rootStatus -cne 'stopped' -or
                    [string]$lifecycle.lastStopTurnId -cne [string]$pending.turnId
                ) {
                    return [pscustomobject]@{
                        Claimed = $false; Reason = 'root-turn-resumed'; NewerTurnId = [string]$lifecycle.currentTurnId
                        AuthoritativeRootNotify = $false
                    }
                }
                if (@(Get-CodexFinishActiveSubagentIds -LifecycleState $lifecycle).Count -gt 0) {
                    return [pscustomobject]@{
                        Claimed = $false; Reason = 'subagent-still-active'; NewerTurnId = $null
                        AuthoritativeRootNotify = $false
                    }
                }
            }
        }
        elseif ($mode -eq 'require') {
            return [pscustomobject]@{
                Claimed = $false; Reason = 'lifecycle-state-missing'; NewerTurnId = $null
                AuthoritativeRootNotify = $authoritativeRootNotify
            }
        }

        $projectClaim = Confirm-CodexFinishProjectPendingCandidate `
            -Event $Event `
            -CandidateId $CandidateId `
            -StateDirectory $paths.StateDirectory
        if (-not $projectClaim.Claimed) {
            if ([string]$projectClaim.Reason -ceq 'project-not-present') {
                try { [IO.File]::Delete($paths.PendingPath) } catch { }
            }
            return [pscustomobject]@{
                Claimed                 = $false
                Reason                  = $projectClaim.Reason
                NewerTurnId             = $null
                AuthoritativeRootNotify = $authoritativeRootNotify
                ProjectMonitorState     = $null
                MonitorRollbackUpdated  = [bool](Get-CodexFinishProperty `
                    -InputObject $projectClaim -Name 'MonitorRollbackUpdated' -DefaultValue $false)
                MonitorRollbackRetryScheduled = [bool](Get-CodexFinishProperty `
                    -InputObject $projectClaim -Name 'MonitorRollbackRetryScheduled' -DefaultValue $false)
            }
        }

        if (-not (Register-CodexFinishTurn -Event $Event -StateDirectory $paths.StateDirectory)) {
            return [pscustomobject]@{
                Claimed                 = $false
                Reason                  = 'duplicate-turn'
                NewerTurnId             = $null
                AuthoritativeRootNotify = $authoritativeRootNotify
                ProjectMonitorState     = $projectClaim.ProjectMonitorState
            }
        }

        try {
            [IO.File]::Delete($paths.PendingPath)
        }
        catch {
            # The marker is authoritative; stale pending data will be replaced
            # by the next event for this thread.
        }

        return [pscustomobject]@{
            Claimed                 = $true
            Reason                  = 'claimed'
            NewerTurnId             = $null
            AuthoritativeRootNotify = $authoritativeRootNotify
            ProjectMonitorState     = $projectClaim.ProjectMonitorState
        }
    }
    finally {
        $lockStream.Dispose()
    }
}

function Register-CodexFinishTurn {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Event,
        [string] $StateDirectory,
        [ValidateRange(1, 8760)]
        [int] $MarkerRetentionHours = 168
    )

    $turnHash = Get-CodexFinishTurnHash -Event $Event
    if ([string]::IsNullOrWhiteSpace($turnHash)) {
        return $true
    }

    try {
        $statePath = Resolve-CodexFinishStateDirectory -StateDirectory $StateDirectory
        $null = [IO.Directory]::CreateDirectory($statePath)
        $cutoff = [DateTime]::UtcNow.AddHours(-1 * $MarkerRetentionHours)

        try {
            foreach ($marker in [IO.Directory]::EnumerateFiles($statePath, '*.done')) {
                try {
                    if ([IO.File]::GetLastWriteTimeUtc($marker) -lt $cutoff) {
                        [IO.File]::Delete($marker)
                    }
                }
                catch {
                    # Cleanup is best effort.
                }
            }
        }
        catch {
            # Cleanup is best effort.
        }

        $markerPath = Join-Path $statePath ($turnHash + '.done')
        $stream = $null
        try {
            $stream = [IO.File]::Open(
                $markerPath,
                [IO.FileMode]::CreateNew,
                [IO.FileAccess]::Write,
                [IO.FileShare]::None
            )
            $timestamp = [Text.Encoding]::ASCII.GetBytes([DateTime]::UtcNow.ToString('o'))
            $stream.Write($timestamp, 0, $timestamp.Length)
            return $true
        }
        catch [IO.IOException] {
            if ([IO.File]::Exists($markerPath)) {
                return $false
            }
            # An I/O failure that did not create the marker cannot prove this
            # turn is unique. Fail closed instead of permitting duplicate output.
            return $false
        }
        finally {
            if ($null -ne $stream) {
                $stream.Dispose()
            }
        }
    }
    catch {
        return $false
    }
}

function ConvertTo-CodexFinishMinutes {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Value
    )

    if (-not (Test-CodexFinishTimeText -Value $Value)) {
        throw "Invalid time value: $Value"
    }

    $parts = $Value.Split(':')
    return ([int] $parts[0] * 60) + [int] $parts[1]
}

function Test-CodexFinishQuietHours {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Settings,
        [DateTime] $Now = (Get-Date)
    )

    $quiet = Get-CodexFinishProperty -InputObject $Settings -Name 'quietHours'
    if ($null -eq $quiet) {
        return $false
    }
    if (-not (ConvertTo-CodexFinishBoolean -Value (Get-CodexFinishProperty -InputObject $quiet -Name 'enabled') -DefaultValue $false)) {
        return $false
    }

    $start = ConvertTo-CodexFinishMinutes -Value ([string] (Get-CodexFinishProperty -InputObject $quiet -Name 'start'))
    $end = ConvertTo-CodexFinishMinutes -Value ([string] (Get-CodexFinishProperty -InputObject $quiet -Name 'end'))
    $current = ($Now.Hour * 60) + $Now.Minute

    if ($start -eq $end) {
        return $true
    }
    if ($start -lt $end) {
        return $current -ge $start -and $current -lt $end
    }

    return $current -ge $start -or $current -lt $end
}

function Resolve-CodexFinishAudioFile {
    param(
        [string] $AudioFile,
        [string] $ConfigPath
    )

    if ([string]::IsNullOrWhiteSpace($AudioFile)) {
        return $null
    }
    if ($AudioFile -like 'builtin:*') {
        $trackId = $AudioFile.Substring(8)
        if ($trackId -notin @('soft-chime', 'bright-finish', 'gentle-rise')) {
            return $null
        }
        # Runtime installs keep assets beside the scripts. Source/plugin use
        # keeps assets one directory above scripts. Never search user paths.
        $installedAsset = Join-Path $PSScriptRoot ('assets\music\' + $trackId + '.mp3')
        if ([IO.File]::Exists($installedAsset)) { return $installedAsset }
        return Join-Path ([IO.Path]::GetDirectoryName($PSScriptRoot)) ('assets\music\' + $trackId + '.mp3')
    }
    if ($AudioFile -match '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
        return $null
    }

    $expanded = [Environment]::ExpandEnvironmentVariables($AudioFile)
    $userProfilePath = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    $legacyDefault = Join-Path (Join-Path $userProfilePath 'Music') (Get-CodexFinishSongFileName)
    if (
        [IO.Path]::IsPathRooted($expanded) -and
        [IO.Path]::GetFullPath($expanded) -ieq $legacyDefault -and
        -not [IO.File]::Exists($expanded)
    ) {
        return Resolve-CodexFinishAudioFile -AudioFile 'builtin:soft-chime' -ConfigPath $ConfigPath
    }
    if ([IO.Path]::IsPathRooted($expanded)) {
        return [IO.Path]::GetFullPath($expanded)
    }

    $baseDirectory = [Environment]::CurrentDirectory
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        $baseDirectory = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ConfigPath))
    }
    return [IO.Path]::GetFullPath((Join-Path $baseDirectory $expanded))
}

function Test-CodexFinishAudioFileSupported {
    param(
        [string] $AudioFile
    )

    if ([string]::IsNullOrWhiteSpace($AudioFile) -or -not [IO.File]::Exists($AudioFile)) {
        return $false
    }

    return ([IO.Path]::GetExtension($AudioFile).ToLowerInvariant()) -in @(
        '.wav', '.mp3', '.wma', '.m4a', '.aac'
    )
}

function Invoke-CodexFinishSpeech {
    [CmdletBinding()]
    param(
        [string] $Message = (Get-CodexFinishDefaultMessage),
        [ValidateRange(0, 100)]
        [int] $Volume = 100,
        [ValidateRange(-10, 10)]
        [int] $Rate = 0,
        [string] $VoiceName
    )

    $speaker = $null
    try {
        Add-Type -AssemblyName System.Speech -ErrorAction Stop
        $speaker = [System.Speech.Synthesis.SpeechSynthesizer]::new()
        $speaker.Volume = $Volume
        $speaker.Rate = $Rate

        $installedVoices = @($speaker.GetInstalledVoices() | Where-Object { $_.Enabled })
        $selected = $null
        if (-not [string]::IsNullOrWhiteSpace($VoiceName)) {
            $selected = $installedVoices |
                ForEach-Object { $_.VoiceInfo } |
                Where-Object { $_.Name -ceq $VoiceName } |
                Select-Object -First 1
        }
        if ($null -eq $selected) {
            $selected = $installedVoices |
                ForEach-Object { $_.VoiceInfo } |
                Where-Object { $_.Culture.Name -eq 'zh-CN' } |
                Select-Object -First 1
        }
        if ($null -ne $selected) {
            $speaker.SelectVoice($selected.Name)
        }

        $selectedVoice = $speaker.Voice.Name
        $speaker.Speak($Message)
        return $selectedVoice
    }
    finally {
        if ($null -ne $speaker) {
            $speaker.Dispose()
        }
    }
}

function Start-CodexFinishAudioFile {
    param(
        [Parameter(Mandatory = $true)]
        [string] $AudioFile,
        [ValidateRange(0, 100)]
        [int] $Volume,
        [string] $StateDirectory,
        [string] $ProjectName = '当前项目',
        [string] $ProjectPath,
        [string] $ProjectKey,
        [ValidateSet('once', 'loop', 'seconds')]
        [string] $PlaybackMode = 'once',
        [ValidateRange(1, 86400)]
        [int] $PlaybackSeconds = 30,
        [ValidateRange(1, 86400)]
        [int] $MaximumPlaybackSeconds = 3600
    )

    $playerScript = Join-Path $PSScriptRoot 'play-audio.ps1'
    if (-not [IO.File]::Exists($playerScript)) {
        throw "Missing audio player: $playerScript"
    }

    $resolvedState = Resolve-CodexFinishStateDirectory -StateDirectory $StateDirectory
    $sessionId = [Guid]::NewGuid().ToString('N')
    $escapedPlayer = $playerScript.Replace("'", "''")
    $escapedAudio = $AudioFile.Replace("'", "''")
    $escapedState = $resolvedState.Replace("'", "''")
    $escapedProject = ([string]$ProjectName).Replace("'", "''")
    $escapedProjectPath = ([string]$ProjectPath).Replace("'", "''")
    $escapedProjectKey = ([string]$ProjectKey).Replace("'", "''")
    $command = "& '$escapedPlayer' -AudioFile '$escapedAudio' -Volume $Volume -StateDirectory '$escapedState' -SessionId '$sessionId' -ProjectName '$escapedProject' -ProjectPath '$escapedProjectPath' -ProjectKey '$escapedProjectKey' -PlaybackMode '$PlaybackMode' -PlaybackSeconds $PlaybackSeconds -MaximumPlaybackSeconds $MaximumPlaybackSeconds"
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $powerShellPath = (Get-Command powershell.exe -ErrorAction Stop).Source

    $null = Start-Process `
        -FilePath $powerShellPath `
        -ArgumentList @(
            '-NoLogo',
            '-NoProfile',
            '-NonInteractive',
            '-STA',
            '-ExecutionPolicy',
            'Bypass',
            '-EncodedCommand',
            $encodedCommand
        ) `
        -WindowStyle Hidden

    return $sessionId
}

function Start-CodexFinishOverlay {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectName,
        [ValidateRange(1000, 2000)]
        [int] $DurationMilliseconds = 2000
    )

    $overlayScript = Join-Path $PSScriptRoot 'show-completion-overlay.ps1'
    if (-not [IO.File]::Exists($overlayScript)) {
        throw "Missing completion overlay: $overlayScript"
    }

    $escapedScript = $overlayScript.Replace("'", "''")
    $escapedProject = ([string]$ProjectName).Replace("'", "''")
    $command = "& '$escapedScript' -ProjectName '$escapedProject' -DurationMilliseconds $DurationMilliseconds"
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $powerShellPath = (Get-Command powershell.exe -ErrorAction Stop).Source
    $process = Start-Process `
        -FilePath $powerShellPath `
        -ArgumentList @(
            '-NoLogo',
            '-NoProfile',
            '-NonInteractive',
            '-STA',
            '-ExecutionPolicy',
            'Bypass',
            '-EncodedCommand',
            $encodedCommand
        ) `
        -WindowStyle Hidden `
        -PassThru

    return $process.Id
}

function Invoke-CodexFinishNotification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Event,
        [string] $ConfigPath,
        [string] $StateDirectory,
        [DateTime] $Now = (Get-Date),
        [int] $CompletionGraceSeconds = -1,
        [Alias('StopOnly')]
        [switch] $StopOnlyCandidate,
        [Alias('CandidateObservedUtc')]
        [string] $ObservedUtc,
        [switch] $SkipAudio,
        [switch] $SkipOverlay
    )

    $result = [ordered] @{
        Eligible         = $false
        Claimed          = $false
        WouldNotify      = $false
        Notified         = $false
        SelectedMode     = $null
        SuppressedReason = $null
        FallbackReason   = $null
        AudioFile        = $null
        ProjectName      = $null
        ProjectPath      = $null
        ProjectKey       = $null
        PlaybackMode     = $null
        PlaybackSeconds  = $null
        AnnouncementMessage = $null
        AnnouncementVoice = $null
        AnnouncementError = $null
        SessionId        = $null
        Voice            = $null
        SettingsError    = $null
        BoardNotified    = $false
        BoardPort        = $null
        BoardReason      = $null
        BoardError       = $null
        BoardCompletionSent = $false
        BoardSnapshotSent = $false
        PresentationRoute = $null
        DesktopFallbackUsed = $false
        DesktopFallbackReason = $null
        OverlayWouldNotify = $false
        OverlayNotified  = $false
        OverlayDurationMilliseconds = $null
        OverlayProcessId = $null
        OverlayError     = $null
        StopOnlyCandidate = [bool]$StopOnlyCandidate
    }

    $resolvedConfig = Resolve-CodexFinishConfigPath -ConfigPath $ConfigPath
    try {
        $settings = Get-CodexFinishSettings -ConfigPath $resolvedConfig
    }
    catch {
        $settings = Get-CodexFinishDefaultSettings
        $result.SettingsError = $_.Exception.Message
    }

    if (-not (Test-CodexFinishNotifyEvent -Event $Event -RequiredClient $settings.requiredClient)) {
        $result.SuppressedReason = 'not-vscode-turn-complete'
        return [pscustomobject] $result
    }
    $result.Eligible = $true

    # Presentation controls must not disable the always-on project monitor.
    # Settle and commit the completion first, then suppress audio/overlay/board.
    $presentationSuppressedReason = $null
    if (-not $settings.enabled) {
        $presentationSuppressedReason = 'disabled'
    }
    elseif (Test-CodexFinishQuietHours -Settings $settings -Now $Now) {
        $presentationSuppressedReason = 'quiet-hours'
    }

    $pendingParameters = @{
        Event          = $Event
        StateDirectory = $StateDirectory
        LifecycleMode  = if ($StopOnlyCandidate) { 'require' } else { $settings.completionGuard.lifecycleMode }
    }
    if ($StopOnlyCandidate) {
        $pendingParameters.StopOnly = $true
        $pendingParameters.OnlyIfVacant = $true
        $pendingParameters.ObservedUtc = $ObservedUtc
    }
    $pendingResult = Register-CodexFinishPendingTurn @pendingParameters
    if (-not $pendingResult.Recorded) {
        $result.SuppressedReason = $pendingResult.Reason
        return [pscustomobject] $result
    }

    # Publish the settling state before waiting. Stop Hooks also stay red, but
    # this update covers notify-before-Stop and prefer/off lifecycle modes.
    $result.ProjectName = Get-CodexFinishProjectName -Event $Event
    $result.ProjectPath = Get-CodexFinishProjectPath -Event $Event
    $result.ProjectKey = Get-CodexFinishProjectKey -Event $Event
    $candidateObservedUtc = [DateTime]::UtcNow
    try {
        $candidateObservedUtc = [DateTime]::Parse(
            [string]$pendingResult.ObservedUtc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        )
    }
    catch {
        # Legacy pending results have no observation timestamp.
    }
    $null = Update-CodexFinishProjectMonitorState `
        -Event $Event `
        -Status running `
        -StateDirectory $StateDirectory `
        -NowUtc $candidateObservedUtc

    if ($settings.completionGuard.enabled -and -not $StopOnlyCandidate) {
        $graceSeconds = $settings.completionGuard.graceSeconds
        if ($CompletionGraceSeconds -ge 0) {
            $graceSeconds = [Math]::Min(120, $CompletionGraceSeconds)
        }
        Wait-CodexFinishCompletionGracePeriod -Seconds $graceSeconds
    }

    $claimResult = Confirm-CodexFinishPendingTurn `
        -Event $Event `
        -CandidateId $pendingResult.CandidateId `
        -StateDirectory $StateDirectory
    if (-not $claimResult.Claimed) {
        $result.SuppressedReason = $claimResult.Reason
        return [pscustomobject] $result
    }
    $result.Claimed = $true

    if (-not [string]::IsNullOrWhiteSpace($presentationSuppressedReason)) {
        $result.SuppressedReason = $presentationSuppressedReason
        return [pscustomobject] $result
    }

    # Try the board first. A successful serial delivery is the primary
    # presentation; desktop overlay/audio are a fallback for a missing, busy,
    # or disconnected board.
    $monitorState = $claimResult.ProjectMonitorState
    if ($null -eq $monitorState) {
        $monitorState = Get-CodexFinishProjectMonitorState -StateDirectory $StateDirectory
    }
    $completionPayload = New-CodexFinishBoardPayload `
        -HardwareSettings $settings.hardware `
        -ProjectName $result.ProjectName `
        -ProjectPath $result.ProjectPath `
        -ProjectKey $result.ProjectKey `
        -TurnId ([string](Get-CodexFinishProperty -InputObject $Event -Name 'turn-id'))
    $snapshotPayload = New-CodexFinishBoardSnapshotPayload `
        -MonitorState $monitorState `
        -MaximumProjects $settings.projectMonitor.maximumProjects
    $snapshotStateDirectory = $StateDirectory
    if ([string]::IsNullOrWhiteSpace($snapshotStateDirectory)) {
        $snapshotStateDirectory = Resolve-CodexFinishStateDirectory
    }
    $boardResult = Send-CodexFinishBoardPayloads `
        -HardwareSettings $settings.hardware `
        -Payloads @($completionPayload, $snapshotPayload) `
        -SnapshotStateDirectory $snapshotStateDirectory `
        -MaximumProjects $settings.projectMonitor.maximumProjects
    $result.BoardNotified = [bool] $boardResult.Sent
    $result.BoardPort = $boardResult.Port
    $result.BoardReason = $boardResult.Reason
    $result.BoardError = $boardResult.Error
    $result.BoardCompletionSent = [bool]$boardResult.CompletionSent
    $result.BoardSnapshotSent = [bool]$boardResult.SnapshotSent

    $result.PresentationRoute = Get-CodexFinishPresentationRoute -BoardResult $boardResult
    if ($result.PresentationRoute -ceq 'hardware') {
        $result.SelectedMode = 'hardware'
        $result.WouldNotify = $true
        $result.Notified = $true
        return [pscustomobject] $result
    }

    $result.DesktopFallbackUsed = $true
    $result.DesktopFallbackReason = [string]$boardResult.Reason
    $result.OverlayWouldNotify = [bool]$settings.visual.enabled
    $result.OverlayDurationMilliseconds = [int]$settings.visual.durationMilliseconds
    if ($settings.visual.enabled -and -not $SkipOverlay) {
        try {
            $result.OverlayProcessId = Start-CodexFinishOverlay `
                -ProjectName $result.ProjectName `
                -DurationMilliseconds $settings.visual.durationMilliseconds
            $result.OverlayNotified = $true
        }
        catch {
            # A rendering failure must never suppress the audio fallback.
            $result.OverlayError = $_.Exception.Message
        }
    }

    $selectedMode = $settings.mode
    if ($selectedMode -eq 'audioFile') {
        $resolvedAudio = Resolve-CodexFinishAudioFile -AudioFile $settings.audioFile -ConfigPath $resolvedConfig
        $result.AudioFile = $resolvedAudio
        if (-not (Test-CodexFinishAudioFileSupported -AudioFile $resolvedAudio)) {
            $selectedMode = $settings.fallbackMode
            $result.FallbackReason = 'audio-file-missing-or-unsupported'
        }
    }

    if ($selectedMode -eq 'none') {
        $result.SuppressedReason = 'no-fallback'
        return [pscustomobject] $result
    }

    $result.SelectedMode = $selectedMode
    $result.WouldNotify = $true
    $result.PlaybackMode = $settings.playback.mode
    $result.PlaybackSeconds = $settings.playback.seconds
    if ($SkipAudio) {
        return [pscustomobject] $result
    }

    try {
        switch ($selectedMode) {
            'audioFile' {
                $result.AnnouncementMessage = Get-CodexFinishAnnouncementMessage `
                    -Event $Event `
                    -Settings $settings
                if (-not [string]::IsNullOrWhiteSpace($result.AnnouncementMessage)) {
                    try {
                        $result.AnnouncementVoice = Invoke-CodexFinishSpeech `
                            -Message $result.AnnouncementMessage `
                            -Volume $settings.volume `
                            -Rate $settings.rate `
                            -VoiceName $settings.voiceName
                    }
                    catch {
                        $result.AnnouncementError = $_.Exception.Message
                    }
                }

                $result.SessionId = Start-CodexFinishAudioFile `
                    -AudioFile $result.AudioFile `
                    -Volume $settings.volume `
                    -StateDirectory $StateDirectory `
                    -ProjectName $result.ProjectName `
                    -ProjectPath $result.ProjectPath `
                    -ProjectKey $result.ProjectKey `
                    -PlaybackMode $settings.playback.mode `
                    -PlaybackSeconds $settings.playback.seconds `
                    -MaximumPlaybackSeconds $settings.playback.maximumSeconds
            }
            'tts' {
                $result.Voice = Invoke-CodexFinishSpeech `
                    -Message $settings.message `
                    -Volume $settings.volume `
                    -Rate $settings.rate `
                    -VoiceName $settings.voiceName
            }
            'beep' {
                [Console]::Beep(1200, 500)
            }
        }
        $result.Notified = $true
    }
    catch {
        if ($selectedMode -eq 'audioFile' -and $settings.fallbackMode -in @('tts', 'beep')) {
            $result.FallbackReason = 'audio-launch-failed'
            $result.SelectedMode = $settings.fallbackMode
            if ($settings.fallbackMode -eq 'tts') {
                $result.Voice = Invoke-CodexFinishSpeech `
                    -Message $settings.message `
                    -Volume $settings.volume `
                    -Rate $settings.rate `
                    -VoiceName $settings.voiceName
            }
            else {
                [Console]::Beep(1200, 500)
            }
            $result.Notified = $true
        }
        else {
            throw
        }
    }

    return [pscustomobject] $result
}

Export-ModuleMember -Function @(
    'Get-CodexFinishDefaultMessage',
    'Get-CodexFinishDefaultHardwareMessage',
    'Get-CodexFinishDefaultAnnouncementTemplate',
    'Get-CodexFinishSongFileName',
    'Wait-CodexFinishCompletionGracePeriod',
    'Get-CodexFinishDefaultConfigPath',
    'Resolve-CodexFinishConfigPath',
    'Get-CodexFinishDefaultSettings',
    'ConvertTo-CodexFinishSettings',
    'Get-CodexFinishSettings',
    'Write-CodexFinishSettings',
    'Test-CodexFinishNotifyEvent',
    'Get-CodexFinishProjectPath',
    'Get-CodexFinishProjectName',
    'Get-CodexFinishProjectKey',
    'Get-CodexFinishBoardPortCandidates',
    'New-CodexFinishBoardPayload',
    'New-CodexFinishBoardSnapshotPayload',
    'Send-CodexFinishBoardPayloads',
    'Send-CodexFinishBoardCompletion',
    'Get-CodexFinishPresentationRoute',
    'Send-CodexFinishBoardSnapshot',
    'Start-CodexFinishBoardSnapshotDelivery',
    'Get-CodexFinishAnnouncementMessage',
    'Get-CodexFinishProjectMonitorState',
    'Get-CodexFinishWorkspaceLeaseState',
    'Select-CodexFinishProjectMonitorForWorkspaces',
    'Sync-CodexFinishProjectMonitorWithWorkspaceLeases',
    'Invoke-CodexFinishProjectMonitorSync',
    'Start-CodexFinishMonitorSyncWorker',
    'Update-CodexFinishProjectMonitorState',
    'Remove-CodexFinishProjectMonitorSession',
    'Update-CodexFinishLifecycleState',
    'Invoke-CodexFinishStoppedProjectSettlement',
    'Start-CodexFinishStoppedProjectSettlement',
    'Register-CodexFinishPendingTurn',
    'Confirm-CodexFinishPendingTurn',
    'Register-CodexFinishTurn',
    'Test-CodexFinishQuietHours',
    'Resolve-CodexFinishAudioFile',
    'Test-CodexFinishAudioFileSupported',
    'Invoke-CodexFinishSpeech',
    'Start-CodexFinishOverlay',
    'Invoke-CodexFinishNotification'
)
