param([string]$DiagnosticDir)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Data
. (Join-Path $PSScriptRoot '..\src\ui-state.ps1')
. (Join-Path $PSScriptRoot '..\src\mini.ps1')
$script:assertions=0;$script:speedRows=@{}
function Assert-Mini([bool]$condition,[string]$message){if(-not $condition){throw $message};$script:assertions++}
function Test-Row($id,$parent,$state='running',$started=1){
    return [pscustomobject]@{id=$id;title=$id;model='model';effort='high';parent_id=$parent;source='user';is_open=($state -notin @('completed','failed','interrupted'));state=$state;long_stale=$false;started_ms=$started;available=$true;one=@{output_tps=20};trend=@(@{at=100000;output_tps=10},@{at=130000;output_tps=20})}
}
$main=Test-Row 'main' '';$child=Test-Row 'child' 'main' 'running' 3;$other=Test-Row 'other' '' 'running' 2
$quiet=Test-Row 'quiet' '' 'quiet';$done=Test-Row 'done' '' 'completed';$guardian=Test-Row 'guard' ''; $guardian.source='guardian_review'
$old=Test-Row 'old' '';$old.long_stale=$true
$rows=@(Get-MiniEntries @($child,$main,$other,$quiet,$done,$guardian,$old))
Assert-Mini ($rows.Count -eq 3) 'Active list included completed, quiet, stale or guardian sessions'
Assert-Mini (($rows.Row.id -join ',') -eq 'other,main,child') 'Active child must follow parent'
Assert-Mini ($rows[2].Depth -eq 1) 'Child depth lost'
$stable=@(Get-MiniEntries @($other,$child,$main) @('main','child','other'))
Assert-Mini (($stable.Row.id -join ',') -eq 'main,child,other') 'Rate refresh reordered existing sessions'
$orphan=@(Get-MiniEntries @($child))
Assert-Mini ($orphan.Count -eq 1 -and $orphan[0].Row.id -eq 'child') 'Active orphan disappeared'
$main.parent_id='child';$cycle=@(Get-MiniEntries @($main,$child))
Assert-Mini ($cycle.Count -eq 2 -and @($cycle.Row.id|Sort-Object -Unique).Count -eq 2) 'Cyclic relationship duplicated or hid rows'
$main.parent_id=''
Assert-Mini (@(Get-MiniEntries @()).Count -eq 0) 'Empty active list'
$scale=Get-MiniScale $rows
Assert-Mini ($scale -eq 20) 'Shared chart scale is wrong'
$display=@(Get-MiniDisplayRows @(@{Row=$main;Depth=0}) $true $scale)
Assert-Mini ($display[0].Rate -eq '20.0') 'Own rate was aggregated with child'
Assert-Mini ([double]$display[0].H0 -eq 16 -and [double]$display[0].H1 -eq 32) 'Chart heights do not share a linear scale'
Assert-Mini ([double]$display[0].H9 -eq 0) 'Missing chart bins invented activity'
$fractional=Test-Row 'fractional' '';$fractional.trend=@(@{at=100000;output_tps=0.01},@{at=130000;output_tps=0.02})
$fractionalEntries=@(@{Row=$fractional;Depth=0});$fractionalScale=Get-MiniScale $fractionalEntries
$fractionalDisplay=@(Get-MiniDisplayRows $fractionalEntries $true $fractionalScale)
Assert-Mini ($fractionalScale -eq 0.02 -and [double]$fractionalDisplay[0].H0 -eq 16 -and [double]$fractionalDisplay[0].H1 -eq 32) 'Sub-token-per-second chart scaling is wrong'
$unfresh=@(Get-MiniDisplayRows @(@{Row=$main;Depth=0}) $false $scale)
Assert-Mini ($unfresh[0].Rate -eq '—' -and $unfresh[0].ChartOpacity -eq '0.3') 'Stale rate masquerades as live'
$main.available=$false
$unknown=@(Get-MiniDisplayRows @(@{Row=$main;Depth=0}) $true $scale)
Assert-Mini ($unknown[0].Rate -eq '—' -and [double]$unknown[0].H1 -eq 0) 'Unknown usage shows numeric speed'
Assert-Mini ((Format-MiniRate 0) -eq '0.0' -and (Format-MiniRate 0.03) -eq '<0.1') 'Zero and low positive rates must differ'
Assert-Mini ((Format-MiniRate $null) -eq '—' -and (Format-MiniRate ([double]::NaN)) -eq '—') 'Invalid rate shown as zero'
Assert-Mini ((Format-MiniRate 12345) -eq '12.3k') 'Large rate does not fit column'
$script:refreshSeconds=30;$script:miniRefreshSeconds=5
Assert-Mini ((Get-EffectiveInterval) -eq 30) 'Main interval should apply without mini'
$script:miniWindow=[pscustomobject]@{IsVisible=$true}
Assert-Mini ((Get-EffectiveInterval) -eq 5) 'Mini interval not applied'
$script:miniRefreshSeconds=0
Assert-Mini ((Get-EffectiveInterval) -eq 0) 'Manual mode not retained'
$miniWindow.IsVisible=$false
Assert-Mini ((Get-EffectiveInterval) -eq 30) 'Hiding mini did not restore main interval'
$script:snapshot=@{at=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()-120000};$script:backend=[pscustomobject]@{HasExited=$false};$script:miniRefreshSeconds=5
Assert-Mini (-not (Get-MiniFreshness).Fresh) 'Expired snapshot stayed fresh'
$script:miniRefreshSeconds=0
Assert-Mini ((Get-MiniFreshness).Fresh -and (Get-MiniFreshness).Status -match '快照') 'Manual data must identify its age'
$backend.HasExited=$true
Assert-Mini (-not (Get-MiniFreshness).Fresh) 'Stopped collector stayed fresh in manual mode'
if($DiagnosticDir){
    [void][IO.Directory]::CreateDirectory($DiagnosticDir);$script:settingsPath=Join-Path $DiagnosticDir 'mini-unit-settings.json'
    $script:settings=@{refreshSeconds=30;miniRefreshSeconds=10;miniTopmost=$false;existing='preserve'}
    Save-MonitorSettings;$settings.refreshSeconds=60;Save-MonitorSettings
    $saved=Get-Content -LiteralPath $settingsPath -Raw|ConvertFrom-Json
    Assert-Mini ($saved.existing -eq 'preserve' -and $saved.miniRefreshSeconds -eq 10 -and -not $saved.miniTopmost -and $saved.refreshSeconds -eq 60) 'Settings overwritten'
}
'PASS: '+$assertions+' active-list, chart, freshness and persistence checks'
