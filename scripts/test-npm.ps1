. (Join-Path $PSScriptRoot 'common.ps1')
$meta=[IO.File]::ReadAllText((Join-Path $ProjectRoot 'package.json'))|ConvertFrom-Json
$archive=Join-Path $ProjectRoot ('outputs\'+$meta.name+'-'+$meta.version+'.tgz')
$prefix=Join-Path $ProjectRoot '.build\npm install test';Remove-ProjectTree $prefix
$state=Join-Path $ProjectRoot '.build\npm persistent state';[void][IO.Directory]::CreateDirectory($state)
$cache=Join-Path $ProjectRoot '.build\npm-cache';[void][IO.Directory]::CreateDirectory($cache)
$previous=$env:CODEX_MONITOR_DATA;$env:CODEX_MONITOR_DATA=$state
try{
    # Disable lifecycle scripts and network: the release tarball must already contain its runtime.
    & npm.cmd install --global --prefix $prefix --cache $cache --offline --ignore-scripts --no-audit --no-fund $archive
    if($LASTEXITCODE -ne 0){throw 'Offline npm install failed'}
    $command=Join-Path $prefix 'codex-usage-monitor.cmd'
    if((& $command --version) -cne $meta.version){throw 'Installed CLI version mismatch'}
    $doctor=(& $command doctor|Out-String)|ConvertFrom-Json
    if($LASTEXITCODE -ne 0 -or -not $doctor.ready -or $doctor.dataDirectory -cne $state){throw 'Installed runtime or data directory check failed'}
    $sentinel=Join-Path $state 'upgrade-preserved.txt';Write-Utf8 $sentinel 'preserve me'
    & npm.cmd install --global --prefix $prefix --cache $cache --offline --ignore-scripts --no-audit --no-fund $archive
    if($LASTEXITCODE -ne 0 -or [IO.File]::ReadAllText($sentinel) -cne 'preserve me'){throw 'npm reinstall did not preserve external state'}
    $source=Join-Path $prefix ('node_modules\'+$meta.name+'\src')
    & powershell.exe -NoProfile -STA -File (Join-Path $source 'launch.ps1') -Check
    if($LASTEXITCODE -ne 0){throw 'Installed launcher check failed'}
    if((Test-Path -LiteralPath (Join-Path $source 'data')) -or (Test-Path -LiteralPath (Join-Path $source 'settings.json'))){throw 'Installed package was used for writable state'}
    $report=[ordered]@{version=$meta.version;offline_install=$true;bundled_runtime=$true;reinstall_preserves_data=$true;launch_check=$true;private_files=0}
    $dir=Join-Path $ProjectRoot '.build\verification';[void][IO.Directory]::CreateDirectory($dir)
    Write-Utf8 (Join-Path $dir 'npm.json') ($report|ConvertTo-Json)
    $report|ConvertTo-Json
}finally{$env:CODEX_MONITOR_DATA=$previous}
