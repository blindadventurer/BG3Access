# Companion watcher for probe E6: measures the round-trip latency of the
# Ext.IO.SaveFile <-> external process bridge that the speech layer would use.
#
# The Lua side writes A11yDiag\ping.txt with a sequence number; this script
# echoes it into pong.txt as fast as the filesystem allows; Lua measures the
# elapsed time. That number is the floor on speech latency for bridge variant A.

$dir = Join-Path $env:LOCALAPPDATA "Larian Studios\Baldur's Gate 3\Script Extender\A11yDiag"
New-Item -ItemType Directory -Force $dir | Out-Null
$ping = Join-Path $dir "ping.txt"
$pong = Join-Path $dir "pong.txt"
$log  = Join-Path $dir "watcher.log"

"[$(Get-Date -Format o)] watcher started on $dir" | Out-File $log -Encoding utf8

$fsw = New-Object System.IO.FileSystemWatcher
$fsw.Path = $dir
$fsw.Filter = "ping.txt"
$fsw.NotifyFilter = [System.IO.NotifyFilters]::LastWrite -bor [System.IO.NotifyFilters]::FileName
$fsw.EnableRaisingEvents = $true

$count = 0
while ($true) {
    $r = $fsw.WaitForChanged([System.IO.WatcherChangeTypes]::All, 1000)
    if ($r.TimedOut) { continue }
    try {
        $v = [System.IO.File]::ReadAllText($ping)
        [System.IO.File]::WriteAllText($pong, $v)
        $count++
        if ($count -le 5 -or $count % 25 -eq 0) {
            "[$(Get-Date -Format o)] echoed #$count value=$v" | Out-File $log -Append -Encoding utf8
        }
    } catch {
        # transient sharing violation while the game still holds the handle
    }
}
