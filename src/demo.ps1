param([switch]$SelfTest,[string]$DiagnosticDir,[ValidateRange(0,14)][int]$StartStage=0,[switch]$Paused)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Data,System.Windows.Forms,System.Drawing
$script:baseDir=$PSScriptRoot
$demoCreated=$false;$demoName=if($SelfTest){'Local\CodexUsageMonitor.Demo.Test.'+$PID}else{'Local\CodexUsageMonitor.Demo'}
$demoMutex=New-Object Threading.Mutex($true,$demoName,[ref]$demoCreated)
$script:demoShow=New-Object Threading.EventWaitHandle($false,[Threading.EventResetMode]::AutoReset,($demoName+'.Show'))
if(-not $demoCreated){[void]$demoShow.Set();$demoShow.Dispose();$demoMutex.Dispose();exit}
. (Join-Path $PSScriptRoot 'storage.ps1')
if(-not $DiagnosticDir){$DiagnosticDir=Join-Path (Get-MonitorStorage $baseDir).Data 'demo'}
[void][IO.Directory]::CreateDirectory($DiagnosticDir)
$script:settingsPath=Join-Path $DiagnosticDir 'settings.json';$script:settings=@{miniTopmost=$true;reduceMotion=$false}
$script:refreshSeconds=30;$script:changes=@{added=0;removed=0;cells=0};$script:speedRows=@{};$script:closing=$false
$script:snapshot=@{at=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()};$script:backend=@{HasExited=$false}
. (Join-Path $baseDir 'ui-state.ps1');. (Join-Path $baseDir 'mini.ps1');. (Join-Path $baseDir 'mini-motion.ps1')
$script:window=New-Object Windows.Window;$window.Icon=New-Object Windows.Media.Imaging.BitmapImage([Uri](Join-Path $baseDir 'assets\app.ico'))
$reader=[Xml.XmlReader]::Create((Join-Path $baseDir 'demo.xaml'));try{$script:demoWindow=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Close()}
$themeReader=[Xml.XmlReader]::Create((Join-Path $baseDir 'window.xaml'));try{$themeWindow=[Windows.Markup.XamlReader]::Load($themeReader);$demoWindow.Resources=$themeWindow.Resources;$themeWindow.Close()}finally{$themeReader.Close()}
$demoWindow.Icon=$window.Icon;$script:demoUi=@{}
foreach($name in @('DemoStep','DemoIndex','DemoHint','DemoScene','DemoSpeed','DemoPause','DemoNext','DemoReplay')){$demoUi[$name]=$demoWindow.FindName($name)}
function Send-Request {} function Refresh-Monitor {} function Hide-Monitor {} function Show-Monitor {}
function Write-UiError($err){$err.ToString()+[Environment]::NewLine+$err.ScriptStackTrace|Add-Content -LiteralPath (Join-Path $DiagnosticDir 'demo-errors.log') -Encoding UTF8;$demoUi.DemoHint.Text='演示出现错误，请查看日志';$script:demoFailed=$true}
function Close-Demo {if($script:closing){return};$script:closing=$true;if($script:demoTimer){$demoTimer.Stop()};$miniWindow.Close();$demoWindow.Close()}
function Hide-Mini {Close-Demo}
function Expand-MiniSession {[void]$demoWindow.Activate()}
function Update-MiniClock {if($miniUi.MiniStatus){Set-MiniText 'MiniStatus' '演示数据';Set-MiniText 'MiniFreshness' '模拟状态与速率。点击问号模拟回答，点击错误或完成行模拟查看并收起。'}}
function Open-MiniSession {
    $selected=$miniUi.MiniList.SelectedItem;if(-not $selected){return};$row=$speedRows[[string]$selected.Id];if(-not $row){return}
    if($row.display_state -eq 'waiting'){$row.display_state='running';$row.state='running';$row.requires_input=$false;$row.one.output_tps=18.6;$demoUi.DemoHint.Text='已模拟回答，恢复速率显示'}
    elseif($row.display_state -in @('failed','completed','interrupted')){$speedRows.Remove([string]$row.id);$demoUi.DemoHint.Text='已模拟查看，正在收起这一行'}
    else{$demoUi.DemoHint.Text='正式版点击此处会打开对应 Codex 会话'}
    Render-Mini
}
function New-DemoRow($id,$title,$state='running',$parent='') {
    $now=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    return [pscustomobject]@{id=$id;turn_id='demo';mini_visible=$true;display_state=$state;state=$state;title=$title;model='GPT-6.1';effort='high';parent_id=$parent;source=$(if($parent){'subagent'}else{'user'});is_open=($state -notin @('completed','failed','interrupted'));requires_input=($state -eq 'waiting');long_stale=$false;available=$true;started_ms=$now-1000;one=@{output_tps=$(if($state -eq 'starting'){0}else{44.8})};trend=@(for($i=0;$i -lt 10;$i++){@{at=$now-(9-$i)*30000;output_tps=$(if($state -eq 'starting'){0}else{@(8,12,10,18,23,22,28,35,31,44.8)[$i]})}})}
}
$script:demoStages=@(
    @('新会话','行高展开，名称与速率淡入'),
    @('正常输出','数字与柱形原位更新，行的位置保持稳定'),
    @('子会话加入','子会话跟在父会话下方，显示分支'),
    @('子会话输出','父子会话分别显示各自的速率'),
    @('等待回答','琥珀色点轻亮两次，右侧出现 ?；可点击模拟回答'),
    @('回答后继续','问号消失，恢复薄荷色点和速率'),
    @('会话出错','珊瑚色点和 ! 提醒；可点击模拟查看'),
    @('错误行收起','模拟点击查看：淡出并收起行高'),
    @('新任务加入','新的子会话展开进入'),
    @('任务完成','✓ 淡入，完成行保留；可点击模拟查看'),
    @('完成行收起','模拟点击查看：完成行平滑退出'),
    @('主会话完成','主会话也显示 ✓，等待查看'),
    @('全部收起','最后一行退出，显示空状态'),
    @('所有状态同屏','新建、进行中、待回答、错误、完成和中断同时展示'),
    @('被中断后置灰','标题、模型、柱形和标记一起置灰；点击后沿用退出动画')
)
$script:demoIndex=0;$script:demoPaused=$false;$script:demoRate=1.0;$script:demoElapsed=0.0;$script:demoUpdating=$false;$script:demoTick=0;$script:demoVisited=@{}
function Set-DemoStage([int]$index) {
    $script:demoIndex=($index+$demoStages.Count)%$demoStages.Count;$script:demoElapsed=0;$script:demoUpdating=$true
    try{$demoUi.DemoScene.SelectedIndex=$demoIndex}finally{$script:demoUpdating=$false}
    $demoUi.DemoStep.Text=$demoStages[$demoIndex][0];$demoUi.DemoHint.Text=$demoStages[$demoIndex][1];$demoUi.DemoIndex.Text=($demoIndex+1).ToString()+' / '+$demoStages.Count
    $script:demoVisited[$demoIndex]=$true;$script:speedRows=@{}
    if($demoIndex -ne 12){$speedRows['main']=New-DemoRow 'main' '小窗动效演示' $(if($demoIndex -eq 0){'starting'}elseif($demoIndex -eq 11){'completed'}else{'running'})}
    if($demoIndex -in @(2,3,4,5,6)){
        $state=switch($demoIndex){2{'starting'} 4{'waiting'} 6{'failed'} default{'running'}}
        $speedRows['child']=New-DemoRow 'child' '子会话测试' $state 'main';$speedRows['child'].one.output_tps=18.6
    }
    if($demoIndex -in @(8,9)){$speedRows['next-child']=New-DemoRow 'next-child' '结果校验' $(if($demoIndex -eq 8){'starting'}else{'completed'}) 'main'}
    if($demoIndex -eq 13){
        $script:speedRows=@{};$states=@('starting','running','waiting','failed','completed','interrupted');$titles=@('小窗动效实现','告警规则重构','部署脚本检查','接口测试修复','单元测试补齐','被中断的任务')
        for($i=0;$i -lt $states.Count;$i++){$id='all-'+$i;$speedRows[$id]=New-DemoRow $id $titles[$i] $states[$i];$speedRows[$id].started_ms-=$i*1000}
    }
    if($demoIndex -eq 14){$speedRows['stopped']=New-DemoRow 'stopped' '被中断的任务' 'interrupted' 'main'}
    $snapshot.at=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();Render-Mini
}
New-MiniWindow
$miniWindow.Title='Codex 动效演示 · 模拟数据'
foreach($name in @('DemoPause','DemoNext','DemoReplay')){$demoUi[$name].Style=$miniWindow.FindResource('MiniButton')}
foreach($stage in $demoStages){[void]$demoUi.DemoScene.Items.Add($stage[0])}
foreach($label in @('慢速','正常','快速')){[void]$demoUi.DemoSpeed.Items.Add($label)};$demoUi.DemoSpeed.SelectedIndex=1;$demoUi.DemoScene.SelectedIndex=0
$demoUi.DemoScene.Add_SelectionChanged({if(-not $script:demoUpdating -and $this.SelectedIndex -ge 0){Set-DemoStage $this.SelectedIndex}})
$demoUi.DemoSpeed.Add_SelectionChanged({$script:demoRate=@(0.5,1.0,2.0)[$this.SelectedIndex]})
$demoUi.DemoPause.Add_Click({$script:demoPaused=-not $demoPaused;$this.Content=if($demoPaused){'继续'}else{'暂停'}})
$demoUi.DemoNext.Add_Click({Set-DemoStage ($demoIndex+1)})
$demoUi.DemoReplay.Add_Click({$script:demoPaused=$false;$demoUi.DemoPause.Content='暂停';Set-DemoStage 0})
$demoWindow.Add_Closing({if(-not $script:closing){$script:closing=$true;if($script:demoTimer){$demoTimer.Stop()};$miniWindow.Close()}})
$area=[Windows.SystemParameters]::WorkArea;$left=$area.Left+($area.Width-400)/2;$top=[Math]::Max($area.Top+16,$area.Top+($area.Height-620)/2)
$demoWindow.Left=$left;$demoWindow.Top=$top+400
$demoWindow.Show();$miniWindow.Owner=$demoWindow;$miniWindow.Left=$left;$miniWindow.Top=$top;$miniWindow.Show();Set-DemoStage $StartStage;if($Paused){$script:demoPaused=$true;$demoUi.DemoPause.Content='继续'}
$script:demoTimer=New-Object Windows.Threading.DispatcherTimer;$demoTimer.Interval=[TimeSpan]::FromMilliseconds(50)
$script:lastDemoTick=[DateTime]::UtcNow;$script:testSteps=0
$demoTimer.Add_Tick({try{
    $now=[DateTime]::UtcNow;$delta=[Math]::Min(500,($now-$lastDemoTick).TotalMilliseconds);$script:lastDemoTick=$now;Update-MiniMotion
    if($demoShow.WaitOne(0)){$demoWindow.Show();$miniWindow.Show();[void]$demoWindow.Activate()}
    $demoWindow.Left=$miniWindow.Left;$demoWindow.Top=$miniWindow.Top+[Math]::Max(220,$miniWindow.ActualHeight)+10
    if(-not $demoPaused){$script:demoElapsed+=$delta*$demoRate}
    $duration=if($SelfTest){650}else{3500}
    if($demoElapsed -ge $duration){
        if($SelfTest -and $demoIndex -eq 0){
            $tip=New-Object Windows.Controls.ToolTip;$tip.Style=$demoWindow.FindResource([Windows.Controls.ToolTip]);$tip.PlacementTarget=$demoUi.DemoSpeed;$tip.Content=('演示提示文字 '*15)
            try{$tip.IsOpen=$true;$tip.UpdateLayout();if($tip.ActualHeight -le 0){throw 'Tooltip did not render'}}finally{$tip.IsOpen=$false}
            $demoUi.DemoScene.IsDropDownOpen=$true;$demoUi.DemoScene.UpdateLayout();$demoUi.DemoScene.IsDropDownOpen=$false
        }
        if($SelfTest -and $demoIndex -eq ($demoStages.Count-1)){
            $demoUi.DemoPause.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
            if(-not $demoPaused){throw 'Pause did not work'}
            $demoUi.DemoNext.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
            if($demoIndex -ne 0){throw 'Next did not wrap'}
            $demoUi.DemoReplay.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
            if($demoPaused -or $demoIndex -ne 0 -or $demoVisited.Count -ne $demoStages.Count){throw 'Replay or stage coverage failed'}
            @{passed=(-not $script:demoFailed);stages=$demoVisited.Count;pause_next_replay=$true;tooltip_and_dropdown=$true;material=$miniGlass}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $DiagnosticDir 'demo-checks.json') -Encoding UTF8
            Close-Demo;return
        }
        Set-DemoStage ($demoIndex+1)
    }
    $script:demoTick++
    if($demoTick%20 -eq 0 -and -not $demoPaused){
        foreach($row in $speedRows.Values){if($row.display_state -eq 'running'){$rate=[Math]::Round(26+15*[Math]::Sin($demoTick/23.0)+$(if($row.parent_id){-12}else{0}),1);$row.one.output_tps=$rate;$row.trend=@($row.trend|Select-Object -Skip 1)+@(@{at=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();output_tps=$rate})}}
        $snapshot.at=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();Render-Mini
    }
}catch{Write-UiError $_;if($SelfTest){Close-Demo}}})
$demoTimer.Start();$app=New-Object Windows.Application;$app.ShutdownMode='OnMainWindowClose'
try{[void]$app.Run($demoWindow)}finally{$script:closing=$true;$demoTimer.Stop();if($miniWindow){$miniWindow.Close()};$window.Close();$demoShow.Dispose();$demoMutex.ReleaseMutex();$demoMutex.Dispose()}
