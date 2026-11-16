param([switch]$Npm)
. (Join-Path $PSScriptRoot 'common.ps1')
$meta=[IO.File]::ReadAllText((Join-Path $ProjectRoot 'package.json'))|ConvertFrom-Json
$testRoot=Join-Path $ProjectRoot $(if($Npm){'.build\npm startup check'}else{'.build\startup check'})
Remove-ProjectTree $testRoot
[void][IO.Directory]::CreateDirectory($testRoot)
$previousData=$env:CODEX_MONITOR_DATA
$previousHome=$env:CODEX_HOME
$env:CODEX_HOME=Join-Path $testRoot 'sample codex'
[void][IO.Directory]::CreateDirectory((Join-Path $env:CODEX_HOME 'sessions'))
if($Npm){
    $app=Join-Path $ProjectRoot '.build\npm install test\node_modules\codex-usage-monitor\native'
    $env:CODEX_MONITOR_DATA=Join-Path $testRoot 'persistent data'
    $data=$env:CODEX_MONITOR_DATA;$settings=Join-Path $data 'settings.json'
}else{
    $zip=Join-Path $ProjectRoot ('outputs\CodexUsageMonitor-'+$meta.version+'-win-x64.zip')
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($zip,$testRoot)
    $app=Join-Path $testRoot 'CodexUsageMonitor';$env:CODEX_MONITOR_DATA=''
    $data=Join-Path $app 'data';$settings=Join-Path $app 'settings.json'
}
$exe=Join-Path $app 'CodexUsageMonitor.exe'
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $settings))
Write-Utf8 $settings '{"refreshSeconds":10,"lastView":"Main","miniRefreshSeconds":5,"miniTopmost":false,"futureField":{"keep":true}}'
$first=$null;$second=$null
try {
    $first=Start-Process -FilePath $exe -ArgumentList 'tray' -PassThru -WindowStyle Hidden
    $firstHandle=$first.Handle
    $deadline=[DateTime]::UtcNow.AddSeconds(20)
    $cache=Join-Path $data 'usage-v2.sqlite'
    while(-not (Test-Path -LiteralPath $cache)){
        if($first.HasExited -or [DateTime]::UtcNow -gt $deadline){throw ('Native first launch did not create its cache in '+$data)}
        Start-Sleep -Milliseconds 200
    }
    $dbHash=(Get-FileHash -LiteralPath $settings -Algorithm SHA256).Hash
    $second=Start-Process -FilePath $exe -ArgumentList 'tray' -PassThru -WindowStyle Hidden
    $secondHandle=$second.Handle
    if(-not $second.WaitForExit(12000) -or $second.ExitCode -ne 0 -or $first.HasExited){throw 'Native repeated launch did not reuse its instance'}
    $children=@(Get-CimInstance Win32_Process | Where-Object {$_.ParentProcessId -eq $first.Id})
    $collectors=@($children|Where-Object {$_.Name -eq 'node.exe' -and $_.CommandLine -like '*collector.cjs*'})
    if($collectors.Count -ne 1){throw 'Expected a single Node collector'}
    $node=Join-Path $app 'runtime\node.exe'
    & $node -e "const {spawnSync}=require('node:child_process');const s=spawnSync(process.argv[1],['sample-processes'],{encoding:'utf8',timeout:12000});if(s.status!==0)throw Error(s.stderr||s.error||'Process sampler failed');const rows=JSON.parse(s.stdout);if(!rows.some(p=>p.ppid>0)||rows.some(p=>p.command&&!/^--thread-id [0-9a-f-]{36}$/i.test(p.command)))throw Error('Invalid process sample');" $exe
    if($LASTEXITCODE){throw 'Native process sampler check failed'}
    $sampling=@(Get-CimInstance Win32_Process | Where-Object {$_.ParentProcessId -eq $collectors[0].ProcessId})
    if(@($children+$sampling|Where-Object {$_.Name -match '^(powershell|pwsh)\.exe$'}).Count){throw 'A runtime process started PowerShell'}
    if((Get-FileHash -LiteralPath $settings -Algorithm SHA256).Hash -ne $dbHash){throw 'Legacy settings changed unexpectedly'}
    if($Npm -and (Test-Path -LiteralPath (Join-Path $app 'data'))){throw 'npm install directory was used for state'}
    @{passed=$true;version=$meta.version;npm=[bool]$Npm;cache=$true;legacy_settings_preserved=$true;single_instance=$true;single_collector=$true;no_powershell=$true}|ConvertTo-Json
}finally{
    foreach($p in @($second,$first)){if($p -and -not $p.HasExited){$p.Kill();[void]$p.WaitForExit(3000)}}
    $env:CODEX_MONITOR_DATA=$previousData;$env:CODEX_HOME=$previousHome
}
