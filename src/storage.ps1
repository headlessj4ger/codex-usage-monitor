function Get-MonitorStorage([string]$BaseDirectory,[string]$DataRoot='') {
    if(-not $DataRoot){$DataRoot=$env:CODEX_MONITOR_DATA}
    if($DataRoot){
        if(-not [IO.Path]::IsPathRooted($DataRoot)){throw 'CODEX_MONITOR_DATA must be an absolute directory path.'}
        $resolved=[IO.Path]::GetFullPath($DataRoot)
        return [pscustomobject]@{Data=$resolved;Settings=(Join-Path $resolved 'settings.json');External=$true}
    }
    return [pscustomobject]@{Data=(Join-Path $BaseDirectory 'data');Settings=(Join-Path $BaseDirectory 'settings.json');External=$false}
}
