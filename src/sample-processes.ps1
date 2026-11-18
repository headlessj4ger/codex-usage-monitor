$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$rows = @(Get-CimInstance Win32_Process | ForEach-Object {
    [ordered]@{
        pid = $_.ProcessId
        ppid = $_.ParentProcessId
        name = $_.Name
        created = $(if ($_.CreationDate) { $_.CreationDate.ToUniversalTime().ToString('o') })
        memory = [double]$_.WorkingSetSize
        cpu = ([double]$_.KernelModeTime + [double]$_.UserModeTime) / 10000000
        command = $_.CommandLine
    }
})
ConvertTo-Json -InputObject $rows -Compress
