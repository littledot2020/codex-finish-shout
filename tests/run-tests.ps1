# Codex Finish Shout notify test wrapper.

[CmdletBinding()]
param()

& (Join-Path $PSScriptRoot '..\codex-finish-shout\tests\run-tests.ps1')

if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
if (-not $?) {
    exit 1
}

& (Join-Path $PSScriptRoot '..\codex-finish-shout\tests\bundled-audio-tests.ps1')
if (-not $?) { exit 1 }
