param([Parameter(Mandatory=$true)][string]$DiagnosticDir,[switch]$Preview)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Data,System.Windows.Forms,System.Drawing
$script:baseDir=(Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\src')).Path;[void][IO.Directory]::CreateDirectory($DiagnosticDir)
$script:settingsPath=Join-Path $DiagnosticDir 'motion-settings.json';$script:settings=@{miniTopmost=$true}
$script:refreshSeconds=30;$script:changes=@{added=0;removed=0;cells=0};$script:speedRows=@{};$script:closing=$false
$script:snapshot=@{at=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()};$script:backend=@{HasExited=$false}
. (Join-Path $baseDir 'ui-state.ps1');. (Join-Path $baseDir 'mini.ps1');. (Join-Path $baseDir 'mini-motion.ps1')
$script:window=New-Object Windows.Window
function Send-Request {} function Refresh-Monitor {} function Hide-Monitor {} function Show-Monitor {}
function Write-UiError($err){throw $err}
function Assert-Motion($value,$message){if(-not $value){throw $message};$script:assertions++}
function Set-Fixture {
    $script:speedRows=@{};$titles=@('小窗动效实现','告警规则重构','部署脚本检查','接口测试修复','单元测试补齐');$states=@('starting','running','waiting','failed','completed')
    for($i=0;$i -lt 5;$i++){
        $id='fixture-'+$i;$state=$states[$i]
        $speedRows[$id]=[pscustomobject]@{id=$id;turn_id='turn-'+$i;mini_visible=$true;display_state=$state;state=$state;title=$titles[$i];model=$(if($i -eq 2){'GPT-6'}else{'GPT-6.1'});effort=$(if($i -eq 1){'xhigh'}elseif($i -eq 2){'medium'}else{'high'});parent_id='';source=$(if($i -eq 4){'subagent'}else{'user'});is_open=($i -lt 3);long_stale=$false;available=$true;started_ms=$snapshot.at-$i*1000;one=@{output_tps=44.8};trend=@(for($j=0;$j -lt 10;$j++){@{at=$snapshot.at-(9-$j)*30000;output_tps=$(if($i -eq 0){0}else{(@(6,10,9,14,18,17,22,30,26,28)[$j])*(1-$i/8.0)})}})}
    }
}
function Save-MotionImage {
    $miniWindow.UpdateLayout();$bitmap=New-Object Windows.Media.Imaging.RenderTargetBitmap(800,756,192,192,[Windows.Media.PixelFormats]::Pbgra32);$bitmap.Render($miniWindow)
    $encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder;$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap));$stream=[IO.File]::Create((Join-Path $DiagnosticDir 'minimal-states-render.png'));try{$encoder.Save($stream)}finally{$stream.Dispose()}
}
$script:phase=0;$script:phaseAt=[DateTime]::UtcNow;$script:assertions=0;$script:motionResults=@{}
Set-Fixture;Show-Mini
$miniWindow.Left=420;$miniWindow.Top=220
$script:motionTimer=New-Object Windows.Threading.DispatcherTimer;$motionTimer.Interval=[TimeSpan]::FromMilliseconds(60)
$motionTimer.Add_Tick({try{
    Update-MiniMotion;$elapsed=([DateTime]::UtcNow-$script:phaseAt).TotalMilliseconds
    if($script:phase -eq 0 -and $elapsed -gt 400){
        $miniWindow.UpdateLayout();Assert-Motion ($miniTable.Rows.Count -eq 5) 'five state rows missing';Assert-Motion ($miniWindow.ActualHeight -eq 378) 'fixed density changed'
        Assert-Motion ($miniTable.Rows.Find('fixture-1').Rate -eq '44.8' -and $miniTable.Rows.Find('fixture-1').Mark -eq '') 'normal row has extra icon'
        Assert-Motion ($miniTable.Rows.Find('fixture-2').Mark -eq '?' -and $miniTable.Rows.Find('fixture-3').Mark -eq '!' -and $miniTable.Rows.Find('fixture-4').Mark -eq '✓') 'state symbols incorrect'
        $script:sameRow=$miniTable.Rows.Find('fixture-1');$script:sameContainer=$miniUi.MiniList.ItemContainerGenerator.ContainerFromIndex(1)
        $speedRows['fixture-1'].one.output_tps=31.2;Render-Mini
        Assert-Motion ([object]::ReferenceEquals($sameRow,$miniTable.Rows.Find('fixture-1')) -and [object]::ReferenceEquals($sameContainer,$miniUi.MiniList.ItemContainerGenerator.ContainerFromIndex(1))) 'refresh replaced a row or container'
        $script:motionResults.os_motion_enabled=Test-MiniMotion
        $speedRows.Remove('fixture-0');Render-Mini
        if(Test-MiniMotion){Assert-Motion ($miniTable.Rows.Find('fixture-0').Phase -eq 'exit') 'exit did not retain row'}
        $script:phase=1;$script:phaseAt=[DateTime]::UtcNow;return
    }
    if($script:phase -eq 1 -and $elapsed -gt 500){
        Assert-Motion ($null -eq $miniTable.Rows.Find('fixture-0') -and $miniTable.Rows.Count -eq 4) 'exit did not remove row after animation'
        Set-Fixture;Render-Mini;$script:phase=2;$script:phaseAt=[DateTime]::UtcNow;return
    }
    if($script:phase -eq 2 -and $elapsed -gt 400){
        $script:restoring=$speedRows['fixture-0'];$speedRows.Remove('fixture-0');Render-Mini
        $script:phase=3;$script:phaseAt=[DateTime]::UtcNow;return
    }
    if($script:phase -eq 3 -and $elapsed -gt 65){
        $speedRows['fixture-0']=$restoring;Render-Mini;$script:phase=4;$script:phaseAt=[DateTime]::UtcNow;return
    }
    if($script:phase -eq 4 -and $elapsed -gt 400){
        $miniWindow.UpdateLayout();$container=$miniUi.MiniList.ItemContainerGenerator.ContainerFromItem(($miniTable.DefaultView|Where-Object Id -eq 'fixture-0'))
        Assert-Motion ($miniTable.Rows.Count -eq 5 -and $miniTable.Rows.Find('fixture-0').Phase -eq 'stable') 'reappearing row disappeared'
        Assert-Motion ($container.ActualHeight -eq 52 -and $container.Opacity -eq 1) 'cancelled exit left invisible container'
        $settings.reduceMotion=$true;$script:speedRows=@{};Render-Mini;Assert-Motion ($miniTable.Rows.Count -eq 0) 'reduced motion retained outgoing row'
        Set-Fixture;$script:miniOrder=@();Render-Mini;Assert-Motion (@($miniTable.Rows|Where-Object Phase -ne 'stable').Count -eq 0) 'reduced motion animated rows'
        $script:phase=5;$script:phaseAt=[DateTime]::UtcNow;return
    }
    if($script:phase -eq 5 -and $elapsed -gt 400){
        Save-MotionImage;$script:motionResults.assertions=$assertions;$motionResults.passed=$true;$motionResults.completed=(Get-Date -Format o)
        $motionResults|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $DiagnosticDir 'motion-checks.json') -Encoding UTF8
        if($Preview){$script:phase=6;$script:phaseAt=[DateTime]::UtcNow;return}
        $script:closing=$true;$miniWindow.Close()
    }
    if($script:phase -eq 6 -and $elapsed -gt 180000){$script:closing=$true;$miniWindow.Close()}
}catch{$_|Out-String|Set-Content -LiteralPath (Join-Path $DiagnosticDir 'motion-errors.log');$_.ScriptStackTrace|Add-Content -LiteralPath (Join-Path $DiagnosticDir 'motion-errors.log');$script:closing=$true;$miniWindow.Close()}})
$motionTimer.Start();$app=New-Object Windows.Application;$app.ShutdownMode='OnMainWindowClose'
try{[void]$app.Run($miniWindow)}finally{$motionTimer.Stop();$window.Close()}
