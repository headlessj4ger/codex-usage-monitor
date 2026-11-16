$ErrorActionPreference='Stop'
try {
    $hostExe=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $scriptFile=Join-Path $PSScriptRoot 'demo.ps1'
    if(-not [IO.File]::Exists($scriptFile)){throw 'Missing demo.ps1. Extract the complete package.'}
    . (Join-Path $PSScriptRoot 'storage.ps1')
    $log=Join-Path (Get-MonitorStorage $PSScriptRoot).Data 'demo';[void][IO.Directory]::CreateDirectory($log)
    Start-Process -FilePath $hostExe -ArgumentList ('-NoProfile -STA -File "'+$scriptFile+'"') -WorkingDirectory $PSScriptRoot -WindowStyle Hidden -RedirectStandardOutput (Join-Path $log ('start-'+[Guid]::NewGuid().ToString('N')+'.log')) -RedirectStandardError (Join-Path $log ('error-'+[Guid]::NewGuid().ToString('N')+'.log'))
} catch {[Console]::Error.WriteLine($_.Exception.Message);exit 1}
