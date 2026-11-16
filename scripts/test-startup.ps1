param([switch]$Npm)
. (Join-Path $PSScriptRoot 'common.ps1')
$existing=$null
try{$existing=[Threading.EventWaitHandle]::OpenExisting('Local\CodexUsageMonitor.Show')}catch [Threading.WaitHandleCannotBeOpenedException]{}
if($existing){$existing.Dispose();throw 'Exit the running monitor before startup testing.'}
$version=[IO.File]::ReadAllText((Join-Path $ProjectRoot 'src\version.json'))|ConvertFrom-Json
$zip=Join-Path $ProjectRoot ('outputs\CodexUsageMonitor-'+$version.version+'-'+$version.platform+'.zip')
$testRoot=Join-Path $ProjectRoot $(if($Npm){'.build\npm startup check'}else{'.build\startup check'});Remove-ProjectTree $testRoot;[void][IO.Directory]::CreateDirectory($testRoot)
[void][IO.Directory]::CreateDirectory((Join-Path $ProjectRoot '.build\verification'))
Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
$previousData=$env:CODEX_MONITOR_DATA
if($Npm){$app=Join-Path $ProjectRoot '.build\npm install test\node_modules\codex-usage-monitor\src';$env:CODEX_MONITOR_DATA=Join-Path $testRoot 'persistent data'}
else{[IO.Compression.ZipFile]::ExtractToDirectory($zip,$testRoot);$app=Join-Path $testRoot 'CodexUsageMonitor';$env:CODEX_MONITOR_DATA=''}
$scriptPath=Join-Path $app 'monitor.ps1'
function Get-TestHosts { @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'"|Where-Object {$_.CommandLine -and $_.CommandLine.Contains('"'+$scriptPath+'"')}) }
function Start-TestEntry([string]$logName) {
    $entry=if($Npm){'"'+(Join-Path $ProjectRoot '.build\npm install test\codex-usage-monitor.cmd')+'" tray'}else{'"'+$app+'\Start.cmd" -Tray'}
    $child=Start-Process -FilePath $env:ComSpec -ArgumentList ('/d /c "'+$entry+'"') -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $testRoot ($logName+'.out')) -RedirectStandardError (Join-Path $testRoot ($logName+'.err'))
    $childHandle=$child.Handle
    if(-not $child.WaitForExit(45000) -or $child.ExitCode -ne 0){throw ('CMD startup failed: '+$logName)}
}
try {
    Start-TestEntry 'first'
    $first=@(Get-TestHosts);if($first.Count -ne 1){throw 'First launch did not produce one monitor'}
    $settings=Join-Path $(if($Npm){$env:CODEX_MONITOR_DATA}else{$app}) 'settings.json'
    $cache=Join-Path $(if($Npm){$env:CODEX_MONITOR_DATA}else{Join-Path $app 'data'}) 'usage-v2.sqlite'
    if(-not (Test-Path -LiteralPath $cache)){throw 'First launch did not initialize its cache'}
    $settingsHash=(Get-FileHash -LiteralPath $settings -Algorithm SHA256).Hash
    Start-TestEntry 'second'
    $second=@(Get-TestHosts)
    if($second.Count -ne 1 -or $second[0].ProcessId -ne $first[0].ProcessId){throw 'Second launch did not reuse the monitor'}
    $nodes=@(Get-CimInstance Win32_Process -Filter "Name='node.exe'"|Where-Object {$_.ParentProcessId -eq $first[0].ProcessId -and $_.CommandLine -and $_.CommandLine.Contains((Join-Path $app 'collector.cjs'))})
    if($nodes.Count -ne 1){throw 'Expected one collector'}
    if((Get-FileHash -LiteralPath $settings -Algorithm SHA256).Hash -cne $settingsHash){throw 'Subsequent launch changed settings'}
    $report=[ordered]@{version=$version.version;at=(Get-Date -Format o);passed=$true;first_start=$true;subsequent_reuses_process=$true;single_collector=$true;settings_preserved=$true;path_with_spaces=$true;cache_initialized=$true}
    $report.npm=[bool]$Npm
    if($Npm -and ((Test-Path -LiteralPath (Join-Path $app 'data')) -or (Test-Path -LiteralPath (Join-Path $app 'settings.json')))){throw 'npm startup wrote user state into the package'}
    Write-Utf8 (Join-Path $ProjectRoot $(if($Npm){'.build\verification\npm-startup.json'}else{'.build\verification\startup.json'})) ($report|ConvertTo-Json)
    $report|ConvertTo-Json
} finally {
    $hosts=@(Get-TestHosts);$ids=@($hosts.ProcessId)
    $nodes=@(Get-CimInstance Win32_Process -Filter "Name='node.exe'"|Where-Object {$_.ParentProcessId -in $ids -and $_.CommandLine -and $_.CommandLine.Contains((Join-Path $app 'collector.cjs'))})
    foreach($hostProcess in $hosts){Stop-Process -Id $hostProcess.ProcessId -Force}
    foreach($nodeProcess in $nodes){$child=Get-Process -Id $nodeProcess.ProcessId -ErrorAction SilentlyContinue;if($child -and -not $child.WaitForExit(3000)){$child.Kill()}}
    $env:CODEX_MONITOR_DATA=$previousData
}
