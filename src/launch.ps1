param([switch]$Mini,[switch]$Tray,[switch]$Main,[switch]$Check,[switch]$Quiet,[string]$DataRoot)
$ErrorActionPreference='Stop'
$launchLock=$null;$readySignal=$null;$acquired=$false
try {
    if(@($Mini,$Tray,$Main|Where-Object {$_}).Count -gt 1){throw 'Choose one view: -Mini, -Main or -Tray.'}
    foreach($file in @('version.json','monitor.ps1','mini.ps1','mini-motion.ps1','activity.cjs','questions.cjs','realtime.cjs','runtime-check.cjs','mini.xaml','window.xaml','theme.xaml','ui-state.ps1','collector.cjs','speed.cjs','calibration.cjs','assets\app.ico')){
        if(-not [IO.File]::Exists((Join-Path $PSScriptRoot $file))){throw ('Missing package file: '+$file+'. Extract the complete ZIP before starting.')}
    }
    . (Join-Path $PSScriptRoot 'storage.ps1')
    $storage=Get-MonitorStorage $PSScriptRoot $DataRoot
    $dataFolder=$storage.Data;[void][IO.Directory]::CreateDirectory($dataFolder)
    $probe=Join-Path $dataFolder ([Guid]::NewGuid().ToString('N')+'.tmp')
    try{[IO.File]::WriteAllText($probe,'startup check')}finally{if([IO.File]::Exists($probe)){[IO.File]::Delete($probe)}}
    $nodePath=Join-Path $PSScriptRoot 'runtime\node.exe'
    if(-not [IO.File]::Exists($nodePath)){$nodePath=(Get-Command node.exe -ErrorAction Stop).Source}
    $nodeCheck=& $nodePath --no-warnings (Join-Path $PSScriptRoot 'runtime-check.cjs') 2>&1
    if($LASTEXITCODE -ne 0){throw ('Node runtime check failed: '+($nodeCheck -join ' '))}
    Add-Type -AssemblyName PresentationFramework,System.Data,System.Windows.Forms
    if($Check){Write-Output ('Ready: Windows WPF; Node '+$nodeCheck+'; writable data folder.');exit 0}
    $launchLock=New-Object Threading.Mutex($false,'Local\CodexUsageMonitor.Launch')
    try{$acquired=$launchLock.WaitOne(15000)}catch [Threading.AbandonedMutexException]{$acquired=$true}
    if(-not $acquired){throw 'Another launch is still starting. Try again in a few seconds.'}
    $view=if($Mini){'Mini'}elseif($Tray){'Tray'}elseif($Main){'Main'}else{'Last'}
    $existing=$null
    try{$existing=[Threading.EventWaitHandle]::OpenExisting('Local\CodexUsageMonitor.Show'+$(if($view -eq 'Last'){''}else{'.'+$view}))}catch [Threading.WaitHandleCannotBeOpenedException]{}
    if($existing){try{[void]$existing.Set()}finally{$existing.Dispose()};Write-Output 'Opened the running monitor.';exit 0}
    $readyName='Local\CodexUsageMonitor.Startup.'+[Guid]::NewGuid().ToString('N')
    $readySignal=New-Object Threading.EventWaitHandle($false,[Threading.EventResetMode]::ManualReset,$readyName)
    $outLog=Join-Path $dataFolder 'startup.log';$errorLog=Join-Path $dataFolder 'startup-error.log'
    $arguments='-NoLogo -NoProfile -STA -WindowStyle Hidden -File "'+(Join-Path $PSScriptRoot 'monitor.ps1')+'" -ReadyEvent "'+$readyName+'"'
    if($view -ne 'Last'){$arguments+=' -'+$view}
    if($storage.External){$arguments+=' -DataRoot "'+$storage.Data+'"'}
    $hostExe=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $child=Start-Process -FilePath $hostExe -ArgumentList $arguments -WorkingDirectory $PSScriptRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput $outLog -RedirectStandardError $errorLog
    $deadline=[DateTime]::UtcNow.AddSeconds(40)
    while([DateTime]::UtcNow -lt $deadline){
        if($readySignal.WaitOne(200)){Write-Output 'Codex Usage Monitor started.';exit 0}
        if($child.HasExited){$detail=if([IO.File]::Exists($errorLog)){[IO.File]::ReadAllText($errorLog)}else{''};throw ('Monitor exited during startup. '+$detail)}
    }
    throw ('Startup has not confirmed readiness. Check '+$errorLog+'. The existing process has been left running.')
} catch {
    $message=$_.Exception.Message
    if($Quiet){try{Add-Type -AssemblyName PresentationFramework;[void][Windows.MessageBox]::Show($message,'Codex Usage Monitor')}catch{}}
    [Console]::Error.WriteLine($message);exit 1
} finally {
    if($readySignal){$readySignal.Dispose()};if($launchLock){if($acquired){$launchLock.ReleaseMutex()};$launchLock.Dispose()}
}
