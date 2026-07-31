# Keep a transcript of everything the layer says.
#
# The bridge is one file rewritten per utterance (E6), so what was spoken a second ago is
# already gone - fine for a listener, useless for checking a screen's wording from outside
# the game. The Script Extender console is no substitute: it renders Russian as question
# marks on the way out, and on a busy screen SE's own property warnings push every line out
# of the buffer within a second.
#
# This tails the same file and appends each new utterance to a UTF-8 log, which is the only
# channel where the exact spoken text can be read back.
#
# ASCII only: PS 5.1 reads .ps1 as ANSI and the Write tool emits UTF-8 without a BOM.
#
# Usage: powershell -File speech-log.ps1
#        powershell -File speech-log.ps1 -Reset

param(
    [string]$BridgeFile = (Join-Path $env:LOCALAPPDATA "Larian Studios\Baldur's Gate 3\Script Extender\A11y\speech.txt"),
    [string]$LogFile    = (Join-Path $env:LOCALAPPDATA "Larian Studios\Baldur's Gate 3\Script Extender\A11y\speech-log.txt"),
    [int]$PollMs = 25,
    [switch]$Reset
)

$ErrorActionPreference = "Continue"

if ($Reset -and (Test-Path $LogFile)) { Remove-Item $LogFile -Force }

$lastSeq = ""
while ($true) {
    try {
        if (Test-Path $BridgeFile) {
            # Shared read: the game rewrites this file whole and an exclusive open collides
            # with it often enough at this poll rate to lose utterances (see speak.ps1).
            $fs = [System.IO.File]::Open($BridgeFile,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
            try {
                $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
                $raw = $sr.ReadToEnd()
            } finally { $fs.Dispose() }

            $parts = $raw.Split([char]'|', 3)
            if ($parts.Count -eq 3 -and $parts[0] -ne $lastSeq) {
                $lastSeq = $parts[0]
                $body = $parts[2].Trim()
                if ($body) {
                    $stamp = (Get-Date).ToString("HH:mm:ss")
                    $line = "[$stamp #$lastSeq] " + ($body -replace "`r?`n", " / ")
                    [System.IO.File]::AppendAllText($LogFile, $line + "`r`n",
                                                    [System.Text.Encoding]::UTF8)
                }
            }
        }
    } catch { }
    Start-Sleep -Milliseconds $PollMs
}
