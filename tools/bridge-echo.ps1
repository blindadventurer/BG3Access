# Minimal echo companion for probe E6.
# Polls ping.txt at 1 ms and mirrors it into pong.txt. This is the stand-in for
# the real speech companion: same code path, minus the Tolk call.

$dir  = Join-Path $env:LOCALAPPDATA "Larian Studios\Baldur's Gate 3\Script Extender\A11yDiag"
$ping = Join-Path $dir "ping.txt"
$pong = Join-Path $dir "pong.txt"
$log  = Join-Path $dir "echo.log"

New-Item -ItemType Directory -Force $dir | Out-Null
"[$(Get-Date -Format o)] echo watcher up" | Out-File $log -Encoding utf8

$last = $null
$n = 0
while ($true) {
    try {
        if (Test-Path $ping) {
            $v = [System.IO.File]::ReadAllText($ping)
            if ($v -ne $last) {
                [System.IO.File]::WriteAllText($pong, $v)
                $last = $v
                $n++
                if ($n -le 3 -or $n % 50 -eq 0) {
                    "[$(Get-Date -Format o)] echo #$n = $v" | Out-File $log -Append -Encoding utf8
                }
            }
        }
    } catch { }
    Start-Sleep -Milliseconds 1
}
