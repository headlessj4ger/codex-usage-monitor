. (Join-Path $PSScriptRoot '..\src\storage.ps1')
$previous=$env:CODEX_MONITOR_DATA
try {
    $base=Join-Path $PSScriptRoot '..\src'
    $env:CODEX_MONITOR_DATA=''
    $portable=Get-MonitorStorage $base
    if($portable.External -or $portable.Settings -ne (Join-Path $base 'settings.json') -or $portable.Data -ne (Join-Path $base 'data')){throw 'Portable storage layout changed'}
    $env:CODEX_MONITOR_DATA=Join-Path $PSScriptRoot '..\.build\user state'
    $external=Get-MonitorStorage $base
    if(-not $external.External -or $external.Settings -ne (Join-Path ([IO.Path]::GetFullPath($env:CODEX_MONITOR_DATA)) 'settings.json')){throw 'External storage did not apply'}
    $explicit=Get-MonitorStorage $base ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\.build\explicit')))
    if($explicit.Data -eq $external.Data){throw 'Explicit DataRoot should take precedence'}
    $failed=$false;try{Get-MonitorStorage $base 'relative'|Out-Null}catch{$failed=$true}
    if(-not $failed){throw 'Relative external storage was accepted'}
    'Storage: 4 checks passed'
}finally{$env:CODEX_MONITOR_DATA=$previous}
