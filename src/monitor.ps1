param([switch]$Mini,[switch]$Tray,[switch]$Main,[switch]$SelfTest,[string]$DiagnosticDir,[string]$ReadyEvent,[string]$DataRoot)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Data,System.Windows.Forms,System.Drawing
$script:baseDir=$PSScriptRoot
$script:appVersion=([IO.File]::ReadAllText((Join-Path $baseDir 'version.json'))|ConvertFrom-Json).version
. (Join-Path $PSScriptRoot 'ui-state.ps1')
. (Join-Path $PSScriptRoot 'storage.ps1')
$script:storage=Get-MonitorStorage $PSScriptRoot $DataRoot
$script:settingsPath=$storage.Settings
if($SelfTest){if(-not $DiagnosticDir){throw 'SelfTest requires a separate DiagnosticDir'};[void][IO.Directory]::CreateDirectory($DiagnosticDir);$script:settingsPath=Join-Path $DiagnosticDir 'settings-test.json'}
$script:settings=@{}
$script:refreshValues=@(5,10,30,60,300,0);$script:refreshSeconds=30
if(Test-Path -LiteralPath $settingsPath){try{$saved=Get-Content -Raw -LiteralPath $settingsPath|ConvertFrom-Json;foreach($property in $saved.PSObject.Properties){$script:settings[$property.Name]=$property.Value};if($saved.refreshSeconds -in $refreshValues){$script:refreshSeconds=[int]$saved.refreshSeconds}}catch{}}
$script:closing=$false;$script:syncing=$false;$script:snapshot=$null;$script:sessions=@{};$script:speedRows=@{};$script:expanded=@{};$script:processMap=@{}
$script:page='Live';$script:detailsVisible=$true;$script:selectedId='';$script:detailTarget='';$script:lastDetail=$null;$script:backend=$null;$script:reader=$null;$script:errReader=$null
$script:lastError='';$script:changes=@{added=0;removed=0;cells=0};$script:startupAt=[DateTime]::UtcNow;$script:ready=$false
$created=$false;$instanceName=if($SelfTest){'Local\CodexUsageMonitor.SelfTest.'+$PID}else{'Local\CodexUsageMonitor.Tray'}
$eventName=if($SelfTest){$instanceName+'.Show'}else{'Local\CodexUsageMonitor.Show'}
$script:mutex=New-Object Threading.Mutex($true,$instanceName,[ref]$created)
$script:showEvent=New-Object Threading.EventWaitHandle($false,[Threading.EventResetMode]::AutoReset,$eventName)
if(-not $created){[void]$showEvent.Set();$showEvent.Dispose();$mutex.Dispose();exit}
$script:showMiniEvent=New-Object Threading.EventWaitHandle($false,[Threading.EventResetMode]::AutoReset,($eventName+'.Mini'))
$script:showMainEvent=New-Object Threading.EventWaitHandle($false,[Threading.EventResetMode]::AutoReset,($eventName+'.Main'))
$script:showTrayEvent=New-Object Threading.EventWaitHandle($false,[Threading.EventResetMode]::AutoReset,($eventName+'.Tray'))
$xamlPath=Join-Path $baseDir 'window.xaml';$readerXaml=[Xml.XmlReader]::Create($xamlPath)
try{$script:window=[Windows.Markup.XamlReader]::Load($readerXaml)}finally{$readerXaml.Close()}
$script:ui=@{};$xml=[xml][IO.File]::ReadAllText($xamlPath)
foreach($element in $xml.SelectNodes('//*[@*[local-name()="Name"]]')){$name=$element.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml');$control=$window.FindName($name);if($control){$ui[$name]=$control}}
$window.Icon=New-Object Windows.Media.Imaging.BitmapImage([Uri](Join-Path $baseDir 'assets/app.ico'))
$ui.AppLogo.Source=New-Object Windows.Media.Imaging.BitmapImage([Uri](Join-Path $baseDir 'assets/logo.png'))
$area=[Windows.SystemParameters]::WorkArea;$window.Width=[Math]::Min(1440,$area.Width-60);$window.Height=[Math]::Min(900,$area.Height-60)
$script:tables=@{}
$schemas=@{Live=@('Title','Subtitle','Tooltip','State','Tone','Rate','Elapsed');Session=@('Title','Subtitle','Tooltip','Indent','Chevron','Week','Estimate');Model=@('Title','Subtitle','Week','Estimate','Samples');Process=@('Title','Subtitle','Tooltip','Indent','Pid','Memory');DetailFacts=@('Label','Value');SessionFacts=@('Label','Value');Commands=@('Title','Subtitle','Tooltip','State','Duration');SessionModels=@('Title','Subtitle','Tooltip','Total');Daily=@('Day','Total');Relations=@('Title','Subtitle','Tooltip','Other')}
foreach($key in $schemas.Keys){$tables[$key]=New-StateTable $schemas[$key];$target=if($key -like '*Facts'){$key}else{$key+'Grid'};$ui[$target].ItemsSource=$tables[$key].DefaultView}
$ui.RefreshChoice.SelectedIndex=[array]::IndexOf($refreshValues,$refreshSeconds);$ui.SessionOrder.SelectedIndex=0
$ui.RefreshChoice.ToolTip='完整统计的采样间隔。状态随本地记录变化更新；仅手动会暂停全部自动采集。'

. (Join-Path $baseDir 'mini.ps1')
. (Join-Path $baseDir 'mini-motion.ps1')
$defaults=@{refreshSeconds=30;miniRefreshSeconds=5;miniTopmost=$true;lastView='Main';reduceMotion=$false}
foreach($key in $defaults.Keys){if(-not $settings.ContainsKey($key)){$settings[$key]=$defaults[$key]}}
Save-MonitorSettings
function Confirm-MonitorReady {
    if($ReadyEvent){$signal=[Threading.EventWaitHandle]::OpenExisting($ReadyEvent);try{[void]$signal.Set();$script:ReadyEvent=''}finally{$signal.Dispose()}}
}

function Set-Visible([string]$name,[bool]$value) { $ui[$name].Visibility=if($value){'Visible'}else{'Collapsed'} }
function Write-UiError($errorRecord) {
    $script:lastError=if($errorRecord -is [Exception]){$errorRecord.Message}else{$errorRecord.Exception.Message}
    $folder=if($SelfTest){$DiagnosticDir}else{$storage.Data};[void][IO.Directory]::CreateDirectory($folder)
    Add-Content -LiteralPath (Join-Path $folder 'ui-errors.log') -Encoding UTF8 -Value ((Get-Date -Format o)+' '+$errorRecord.ToString()+"`r`n"+$errorRecord.ScriptStackTrace)
    $ui.StatusText.Text='操作未完成：'+$script:lastError;$ui.StatusText.ToolTip=$script:lastError
}
function Send-Request([string]$action,[string]$id='',[string]$turnId='') {
    if($script:backend -and -not $script:backend.HasExited){try{$backend.StandardInput.WriteLine((@{action=$action;id=$id;turn_id=$turnId;refresh_seconds=(Get-EffectiveInterval)}|ConvertTo-Json -Compress));$backend.StandardInput.Flush()}catch{Write-UiError $_}}
}
function Start-Collector {
    if($script:backend -and -not $script:backend.HasExited){return}
    $taskNode=Join-Path $baseDir 'runtime/node.exe';if(-not (Test-Path -LiteralPath $taskNode)){$taskNode=(Get-Command node.exe -ErrorAction Stop).Source}
    $dataDir=if($SelfTest){Join-Path $DiagnosticDir 'cache'}else{$storage.Data}
    $psi=New-Object Diagnostics.ProcessStartInfo;$psi.FileName=$taskNode
    $psi.Arguments='--no-warnings "'+(Join-Path $baseDir 'collector.cjs')+'" --interval '+(Get-EffectiveInterval)+' --data "'+$dataDir+'"'
    $psi.WorkingDirectory=$baseDir;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    $psi.StandardOutputEncoding=[Text.Encoding]::UTF8;$psi.StandardErrorEncoding=[Text.Encoding]::UTF8
    $script:backend=New-Object Diagnostics.Process;$backend.StartInfo=$psi;[void]$backend.Start()
    $script:reader=$backend.StandardOutput.ReadLineAsync();$script:errReader=$backend.StandardError.ReadLineAsync()
    $script:lastError='';$ui.ConnectionText.Text='正在读取本地会话';$ui.StatusText.Text='首次读取可能需要一些时间…'
}
function Refresh-Monitor {
    try{if(-not $script:backend -or $backend.HasExited){Start-Collector}else{Send-Request 'refresh'};$ui.ConnectionText.Text='正在采集…'}catch{Write-UiError $_}
}
function Stop-Collector {
    if($script:poll){$poll.Stop()};$script:reader=$null;$script:errReader=$null
    if($script:backend){try{Send-Request 'stop';if(-not $backend.WaitForExit(1800)){$backend.Kill()}}catch{};$backend.Dispose();$script:backend=$null}
}
function Set-Details([bool]$show) {
    $script:detailsVisible=$show;$ui.DetailPane.Visibility=if($show -and $script:page -ne 'Help'){'Visible'}else{'Collapsed'}
    $width=if($window.ActualWidth -lt 1220){310}else{350}
    $ui.DetailColumn.Width=New-Object Windows.GridLength($(if($ui.DetailPane.Visibility -eq 'Visible'){$width}else{0}))
}
function Update-Size {
    $ui.SidebarColumn.Width=New-Object Windows.GridLength($(if($window.ActualWidth -lt 1220){184}else{208}))
    Set-Details $script:detailsVisible
    $ui.QuotaFill.Width=[Math]::Max(0,$ui.QuotaTrack.ActualWidth*[Math]::Min(100,[Math]::Max(0,[double]$script:snapshot.quota.used_percent))/100)
    if($script:chartRow){Render-Trend $script:chartRow}
}
function Show-Page([string]$name) {
    $script:page=$name
    foreach($key in @('Live','Session','Model','Process')){Set-Visible ($key+'Grid') ($key -eq $name)}
    Set-Visible 'HelpView' ($name -eq 'Help');Set-Visible 'LiveFilters' ($name -eq 'Live');Set-Visible 'SessionFilters' ($name -eq 'Session');Set-Visible 'ContextNote' ($name -in @('Model','Process'))
    $ui.PageTitle.Text=@{Live='进行中';Session='全部会话';Model='模型与校准';Process='进程关联';Help='统计口径'}[$name]
    if($name -eq 'Help'){$ui.PageSubtitle.Text='数据来源、边界与计算方式'}
    Set-Details $script:detailsVisible
    if($script:snapshot){Render-Page}
}
function Render-Page {
    if(-not $script:snapshot){return};$d=$script:snapshot;$script:syncing=$true
    try{
        switch($script:page){
            'Live'{
                $rows=@(foreach($s in $d.speed.rows){if((-not $ui.RecentFilter.IsChecked -and -not $s.is_open) -or (-not $ui.GuardianFilter.IsChecked -and $s.source -eq 'guardian_review') -or (-not $ui.StaleFilter.IsChecked -and $s.long_stale)){continue}
                    @{Id=$s.id;Title=(Clean-Title $s.title);Subtitle=(Get-Kind $s.source)+' · '+$s.model+' / '+(Format-Effort $s.effort);Tooltip=$s.title+"`n"+$s.id;State=(Speed-State $s.state);Tone=$(switch($s.state){'running'{(Theme-Color 'Accent')} 'quiet'{(Theme-Color 'Warning')} 'failed'{(Theme-Color 'Error')} default{(Theme-Color 'TextMuted')}});Rate=(Format-Rate $s.one.output_tps);Elapsed=(Format-Duration $s.turn.elapsed_ms)}
                });Sync-StateTable $tables.Live $rows
                $ui.PageSubtitle.Text=$rows.Count.ToString()+' 个会话 · 输出含推理 token';$ui.PageSubtitle.ToolTip='每行仅计会话自身。速率按响应入账时间计算，非逐 token 生成速度。'
            }
            'Session'{Sync-StateTable $tables.Session @(Get-SessionRows);$ui.PageSubtitle.Text=$tables.Session.Rows.Count.ToString()+' 行 · '+$(if($ui.SessionOrder.SelectedIndex -eq 0){'按会话关联展开'}else{'所有会话用量排名'});$ui.PageSubtitle.ToolTip='周期 token 是已记录的本机用量；校准占比是账户周配额的估算占比。'}
            'Model'{
                Sync-StateTable $tables.Model @(foreach($g in $d.combinations){@{Id=$g.key;Title=$g.model;Subtitle=(Format-Effort $g.effort)+' 思考 · '+(Format-Tier $g.tier);Week=(Format-Count $g.week_total);Estimate=(Format-Estimate $g.quota_estimate $g.week_total);Samples=(Format-Count $g.calibration_samples)}})
                $ui.PageSubtitle.Text=$d.combinations.Count.ToString()+' 个模型组合 · '+$d.calibration.reason;$ui.ContextNote.Text=Format-CalibrationProgress $d.calibration;$ui.ContextNote.ToolTip=(Format-CalibrationProgress $d.calibration)+"`n"+(Format-CalibrationFilters $d.calibration)
            }
            'Process'{Sync-StateTable $tables.Process @(Get-ProcessRows);$ui.PageSubtitle.Text=$d.processes.Count.ToString()+' 个相关进程 · 保留系统父子关系';$ui.ContextNote.Text='采样 '+(Format-Time $d.process_at)+$(if($d.process_error){' · '+$d.process_error}else{' · 会话归属按明确标识匹配'});$ui.ContextNote.ToolTip='自动采样至少间隔 15 秒；Codex 执行编号不是 Windows PID。'+$d.process_error}
        }
        if($script:page -ne 'Help'){$grid=$ui[$script:page+'Grid'];if($grid.Items.Count -gt 0 -and $null -eq $grid.SelectedItem){$grid.SelectedIndex=0};Set-Visible 'EmptyView' ($grid.Items.Count -eq 0)}else{Set-Visible 'EmptyView' $false}
    }finally{$script:syncing=$false}
    Render-Selection
}
function Render-Snapshot($data) {
    $script:snapshot=$data;$script:sessions=@{};$script:speedRows=@{}
    foreach($s in $data.sessions){$script:sessions[$s.id]=$s};foreach($s in $data.speed.rows){$s|Add-Member -NotePropertyName mini_visible -NotePropertyValue $false -Force;$script:speedRows[$s.id]=$s}
    foreach($s in $data.speed.activity){$s|Add-Member -NotePropertyName mini_visible -NotePropertyValue $true -Force;$script:speedRows[$s.id]=$s}
    $ui.LiveCount.Text=[string]@($data.speed.rows|Where-Object {$_.is_open -and -not $_.long_stale -and $_.source -ne 'guardian_review'}).Count
    $ui.QuotaValue.Text=if($null -ne $data.quota.used_percent){('{0:0}%' -f $data.quota.used_percent)+' 已用'}else{'未知'}
    $ui.QuotaStamp.Text=if($data.quota.expired){'快照已过期'}elseif($data.quota.at_ms){'快照 '+(Format-Time $data.quota.at_ms)}else{'尚无账户快照'}
    $ui.QuotaStamp.ToolTip='账户配额快照；不等于本机所有 token 的线性换算。重置：'+(Format-Time ($data.quota.reset_at*1000))
    $ui.WeekUsage.Text='本机周期 '+(Format-Short $data.week_total)+' token';$ui.WeekUsage.ToolTip='周期 '+(Format-Time $data.period.start)+' — '+(Format-Time $data.period.end)+'（北京时间）'
    $ui.ConnectionText.Text='本地采集 · '+(Format-Time $data.last_scan).Substring(6);$ui.ConnectionDot.Fill=(Theme-Color 'Accent')
    $ui.StatusText.Text=$data.coverage.sessions.ToString()+' 个会话 · '+$data.coverage.with_logs+' 个有日志 · '+$data.coverage.metadata_only+' 个仅累计快照'+$(if($data.warnings.Count){' · '+$data.warnings.Count+' 条日志提示'})
    $ui.StatusText.ToolTip=$ui.StatusText.Text+"`n"+($data.warnings -join "`n")
    Update-Size;Render-Page;Render-Mini
}
function Render-Activity($data) {
    if(-not $script:snapshot){return}
    $script:snapshot.speed=$data.speed;$script:snapshot.at=$data.at;$script:speedRows=@{}
    foreach($s in $data.speed.rows){$s|Add-Member -NotePropertyName mini_visible -NotePropertyValue $false -Force;$script:speedRows[$s.id]=$s}
    foreach($s in $data.speed.activity){$s|Add-Member -NotePropertyName mini_visible -NotePropertyValue $true -Force;$script:speedRows[$s.id]=$s}
    $ui.LiveCount.Text=[string]@($data.speed.rows|Where-Object {$_.is_open -and -not $_.long_stale -and $_.source -ne 'guardian_review'}).Count
    if($script:page -eq 'Live' -and $window.IsVisible){Render-Page}
    Render-Mini
}
function Render-Processes($data) {
    if(-not $script:snapshot){return}
    $script:snapshot.processes=$data.processes;$script:snapshot.process_at=$data.process_at;$script:snapshot.process_error=$data.process_error
    if($script:page -eq 'Process' -and $window.IsVisible){Render-Page}
}

# Chart objects are allocated once; subsequent scans change values and bounds in place.
$script:bars=@();$script:chartLines=@();$script:chartLabels=@();$script:chartRow=$null
foreach($i in 0..2){$line=New-Object Windows.Shapes.Line;$line.Stroke=(Theme-Color 'ChartGrid');$line.StrokeThickness=1;[void]$ui.TrendCanvas.Children.Add($line);$script:chartLines+=,$line;$label=New-Object Windows.Controls.TextBlock;$label.FontSize=9;$label.Foreground=(Theme-Color 'TextMuted');[void]$ui.TrendCanvas.Children.Add($label);$script:chartLabels+=,$label}
foreach($i in 0..9){$bar=New-Object Windows.Shapes.Rectangle;$bar.Fill=(Theme-Color 'Chart');$bar.RadiusX=2;$bar.RadiusY=2;[void]$ui.TrendCanvas.Children.Add($bar);$script:bars+=,$bar}
function Render-Trend($row) {
    $script:chartRow=$row;$width=[Math]::Max(200,$ui.TrendCanvas.ActualWidth);$plotWidth=$width-32;$height=112.0
    $values=@($row.trend|ForEach-Object {[double]$_.output_tps});$maximum=($values|Measure-Object -Maximum).Maximum
    $scale=if($maximum -gt 0){$base=[Math]::Pow(10,[Math]::Floor([Math]::Log10($maximum)));[Math]::Ceiling($maximum/$base)*$base}else{1.0}
    foreach($i in 0..2){$y=10+$i*$height/2;$line=$chartLines[$i];$line.X1=0;$line.X2=$plotWidth;$line.Y1=$y;$line.Y2=$y;$label=$chartLabels[$i];$label.Text=('{0:0.#}' -f ($scale*(1-$i/2)));[Windows.Controls.Canvas]::SetLeft($label,$plotWidth+6);[Windows.Controls.Canvas]::SetTop($label,$y-6)}
    foreach($i in 0..9){$b=$row.trend[$i];$bar=$bars[$i];$value=if($b){[double]$b.output_tps}else{0};$bar.Width=$plotWidth/10-6;$bar.Height=[Math]::Max(0,$value/$scale*$height);[Windows.Controls.Canvas]::SetLeft($bar,3+$i*$plotWidth/10);[Windows.Controls.Canvas]::SetTop($bar,122-$bar.Height);$bar.ToolTip=(Format-Time $b.at)+' · '+(Format-Rate $b.output_tps)+' tok/s';$bar.Visibility=if($row.available){'Visible'}else{'Collapsed'}}
    $ui.TrendEmpty.Text=if(-not $row.available){'日志缺失，无法计算速度'}else{'本窗口尚无响应入账'};Set-Visible 'TrendEmpty' (-not $row.available -or $maximum -le 0)
    $ui.TrendStart.Text=if($row.trend.Count){(Format-Time $row.trend[0].at).Substring(6)}else{''};$ui.TrendEnd.Text=if($row.trend.Count){(Format-Time $row.trend[-1].at).Substring(6)}else{''}
}
function Set-DetailHeader($eyebrow,$title,$subtitle) { $ui.DetailEyebrow.Text=$eyebrow;$ui.DetailTitle.Text=(Clean-Title $title);$ui.DetailTitle.ToolTip=$title;$ui.DetailSubtitle.Text=$subtitle }
function Render-Selection {
    if($script:syncing -or -not $script:snapshot -or $script:page -eq 'Help'){return}
    $selected=$ui[$script:page+'Grid'].SelectedItem
    Set-Visible 'SessionDetailTabs' ($script:page -eq 'Session' -and $null -ne $selected);Set-Visible 'LiveDetails' ($script:page -ne 'Session' -or $null -eq $selected)
    Set-Visible 'SpeedMetrics' ($script:page -eq 'Live' -and $null -ne $selected);Set-Visible 'TrendSection' ($script:page -eq 'Live' -and $null -ne $selected);Set-Visible 'OpenSession' $false
    $script:detailTarget=''
    if($null -eq $selected){Set-DetailHeader '详情' '选择一条记录' '选择会话、模型或进程以查看详情';Sync-StateTable $tables.DetailFacts @();return}
    $id=[string]$selected.Id
    switch($script:page){
        'Live'{
            $row=$script:speedRows[$id];if(-not $row){return};$script:detailTarget=$id;$turn=$row.turn;$one=$row.one
            Set-DetailHeader '会话 / 实时' $row.title ((Speed-State $row.state)+' · '+$row.model+' / '+(Format-Effort $row.effort));Set-Visible 'OpenSession' $true
            $ui.RateOne.Text=Format-Rate $row.one.output_tps;$ui.RateFive.Text=Format-Rate $row.five.output_tps;Render-Trend $row
            $parent=if($row.parent_id -and $script:sessions.ContainsKey($row.parent_id)){$script:sessions[$row.parent_id].title}elseif($row.parent_id){$row.parent_id}else{'无已知父会话'}
            $waiting=if($null -ne $turn.first_record_wait_ms){Format-Duration $turn.first_record_wait_ms}elseif($row.is_open){'已等待 '+(Format-Duration $turn.elapsed_ms)}else{'未记录'}
            Sync-StateTable $tables.DetailFacts @(
                (Fact 'scope' '统计范围' ((Get-Kind $row.source)+'自身'))
                (Fact 'parent' '父会话' (Clean-Title $parent))
                (Fact 'tier' '服务档位' (Format-Tier $row.tier))
                (Fact 'average' '本轮平均输出' ((Format-Rate $turn.average_output_tps)+' tok/s'))
                (Fact 'total' '本轮 token' (Format-Count $turn.total))
                (Fact 'output' '其中输出' (Format-Count $turn.output))
                (Fact 'reasoning' '其中推理输出' (Format-Count $turn.reasoning))
                (Fact 'burn' '近 1 分钟非缓存' ((Format-Rate $one.uncached_tpm)+' token/min'))
                (Fact 'allrate' '近 1 分钟总用量' ((Format-Rate $one.total_tpm)+' token/min'))
                (Fact 'responses' '近 1 分钟响应' ((Format-Rate $one.responses_per_minute)+' 次/min'))
                (Fact 'cache' '缓存输入占比' (Format-Percent $one.cache_percent))
                (Fact 'first' '首响应入账等待' $waiting)
                (Fact 'gap' '响应间隔中位数' (Format-Duration $turn.median_response_gap_ms))
                (Fact 'command' '命令执行用时' ((Format-Duration $turn.command_ms)+' / '+(Format-Percent $turn.command_percent)))
                (Fact 'last' '最后响应' (Format-Time $turn.last_record_at))
                (Fact 'since' '距上次响应' $(if($turn.last_record_at){Format-Duration ($snapshot.speed.as_of-$turn.last_record_at)}else{'尚无记录'}))
                (Fact 'activity' '最后日志活动' (Format-Time $row.last_activity_at))
                (Fact 'coverage' '数据说明' $(if(-not $row.available){'日志缺失，速度未知。'}elseif($one.legacy_records){'含旧日志累计差值；响应频率未知。'}else{'按响应结束时记账；无入账时为 0，不代表生成停止。首响应等待不是首 token 延迟。命令耗时按区间并集计算，不含全部工具。'}))
            )
        }
        'Session'{if($script:sessions.ContainsKey($id)){Fill-Session $script:sessions[$id];if($script:selectedId -ne $id){$script:selectedId=$id;$script:lastDetail=$null;foreach($key in @('Commands','SessionModels','Daily','Relations')){Sync-StateTable $tables[$key] @()};Send-Request 'detail' $id}}}
        'Model'{Render-Model $id}
        'Process'{Render-Process $id}
    }
}
function Fill-Session($s) {
    Set-DetailHeader '会话 / 用量' $s.title ((Get-Kind $s.source)+' · '+$s.id);$ui.DetailSubtitle.ToolTip=$s.cwd
    $parents=Get-Parents;$family=@{};$family[$s.id]=$true;$changed=$true
    while($changed){$changed=$false;foreach($id in $parents.Keys){if($family.ContainsKey($parents[$id]) -and -not $family.ContainsKey($id)){$family[$id]=$true;$changed=$true}}}
    $total=0;$week=0;foreach($id in $family.Keys){$total+=$script:sessions[$id].total;$week+=$script:sessions[$id].week_total}
    $estimateNote=if($null -eq $s.quota_estimate -and $snapshot.calibration.mode -eq 'learned'){'含尚未校准的组合'}else{$snapshot.calibration.reason}
    Sync-StateTable $tables.SessionFacts @(
        (Fact 'total' '自身累计 token' (Format-Count $s.total))
        (Fact 'coverage' '数据完整性' (Get-Coverage $s.coverage))
        (Fact 'recorded' '逐条累计 token' (Format-Count $s.recorded))
        (Fact 'week' '自身周期 token' $(if($s.week_known){Format-Count $s.week_total}else{'未知：缺少带时间戳日志'}))
        (Fact 'share' '本机周期占比' $(if($s.week_known){Format-Percent $s.local_share}else{'—'}))
        (Fact 'estimate' '周配额校准占比' (Format-Estimate $s.quota_estimate $s.week_total))
        (Fact 'calstate' '校准状态' ($estimateNote+'；截至 '+(Format-Time $snapshot.calibration.as_of)))
        (Fact 'allocation' 'token 分摊参考' ((Format-Percent $s.quota_allocation)+'；原始比例，未考虑模型差异'))
        (Fact 'input' '输入 token' (Format-Count $s.input))
        (Fact 'cached' '其中缓存输入' (Format-Count $s.cached))
        (Fact 'output' '输出 token' (Format-Count $s.output))
        (Fact 'reasoning' '其中推理输出' (Format-Count $s.reasoning))
        (Fact 'familytotal' '自身 + 子树累计' ((Format-Count $total)+' / '+$family.Count+' 个会话'))
        (Fact 'familyweek' '自身 + 子树周期' ((Format-Count $week)+'（已记录部分）'))
        (Fact 'model' '最近模型' $s.model)
        (Fact 'responses' '已记录响应' (Format-Count $s.requests))
        (Fact 'commands' '已索引命令' (Format-Count $s.commands))
        (Fact 'updated' '最后活动' (Format-Time $s.updated))
        (Fact 'cwd' '工作目录' $s.cwd)
    )
}
function Apply-Detail($detail) {
    if($detail.id -ne $script:selectedId){return};if($detail.error){$ui.StatusText.Text=$detail.error;return};$script:lastDetail=$detail
    Sync-StateTable $tables.Commands @(foreach($c in $detail.commands){@{Id=$c.id;Title=$c.executable;Subtitle=(Format-Time $c.start_ms);State=$c.status;Duration=('{0:0.00}' -f ($c.duration_ms/1000));Tooltip='执行编号 '+$c.process_ref+' · 退出码 '+$c.exit_code+"`n"+$c.cwd}})
    Sync-StateTable $tables.SessionModels @(foreach($m in $detail.models){@{Id=$m.key;Title=$m.model;Subtitle=(Format-Effort $m.effort)+' · '+(Format-Tier $m.tier);Total=(Format-Count $m.total);Tooltip='未缓存输入 '+(Format-Count $m.uncached)+"`n缓存输入 "+(Format-Count $m.cached)+"`n输出 "+(Format-Count $m.output)+"`n其中推理 "+(Format-Count $m.reasoning)+"`n响应 "+(Format-Count $m.requests)}})
    Sync-StateTable $tables.Daily @(foreach($day in $detail.daily){@{Id=$day.day;Day=$day.day;Total=(Format-Count $day.total)}})
    Sync-StateTable $tables.Relations @(foreach($edge in $detail.edges){$out=$edge.parent_id -eq $detail.id;$other=if($out){$edge.child_id}else{$edge.parent_id};$title=if($script:sessions.ContainsKey($other)){$script:sessions[$other].title}else{$other};@{Id=$edge.parent_id+'|'+$edge.child_id+'|'+$edge.kind;Other=$other;Title=(Clean-Title $title);Subtitle=$(if($out){'关联到 · '}else{'来自 · '})+(Get-Kind $edge.kind);Tooltip=$edge.evidence+"`n"+$other}})
}
function Format-CalibrationProgress($c) { return '本周验证 '+(Format-Count $c.current_cycle_holdout)+' / 3 · 下一区间 '+('{0:0.#}' -f [double]$c.progress.interval_accumulated_pp)+' / 3 百分点 · 有效 '+(Format-Count $c.observations)+' 区间' }
function Format-CalibrationFilters($c) { return '缺日志区间 '+(Format-Count $c.skipped.missing)+'；上下文不全区间 '+(Format-Count $c.skipped.unknown)+'；间隔过长 '+(Format-Count $c.skipped.gap)+' 次；快照回退 '+(Format-Count $c.skipped.backwards)+' 次' }
function Render-Model([string]$id) {
    $g=$snapshot.combinations|Where-Object {$_.key -eq $id}|Select-Object -First 1;if(-not $g){return};$c=$snapshot.calibration
    Set-DetailHeader '模型 / 自动校准' $g.model ((Format-Effort $g.effort)+' 思考 · '+(Format-Tier $g.tier))
    $shown=if($g.rate){$g.rate}else{$g.historical_rate}
    $rateText=if($shown){(@($shown.rates|ForEach-Object {'{0:0.0000}' -f $_}) -join ' / ')+' 配额百分点 / 百万 token'}else{'尚无可靠系数'}
    $rateKind=if(-not $shown){'等待可识别的模型组合'}elseif($shown.channel_model){'未缓存 / 缓存 / 输出'}else{'组合总 token'}
    $rateState=if($g.rate){'当前周期验证通过'}elseif($g.calibration_warning){$g.calibration_warning}elseif($g.historical_rate){'历史系数已保留；当前周期验证中'}elseif($g.effort -eq 'unknown' -or $g.model -eq 'unknown'){'历史上下文缺失，无法回填'}elseif(-not $g.calibration_samples){'尚无符合条件的区间'}elseif($c.mode -eq 'learned'){'此组合样本不足，继续积累'}else{$c.reason}
    $facts=@(
        (Fact 'week' '本周期 token' (Format-Count $g.week_total))
        (Fact 'estimate' '周配额校准占比' (Format-Estimate $g.quota_estimate $g.week_total))
        (Fact 'ratestate' '组合校准状态' $rateState)
        (Fact 'progress' '当前学习进度' (Format-CalibrationProgress $c))
        (Fact 'samples' '组合有效区间' (Format-Count $g.calibration_samples))
        (Fact 'currentblocks' '本周校准区间' ('已收集 '+(Format-Count $c.progress.current_cycle_observations)+'；可用于验证 '+(Format-Count $c.current_cycle_holdout)))
        (Fact 'sparse' '少见组合混用' ((Format-Count $c.excluded_sparse)+' 个区间暂不用于拟合'))
        (Fact 'rate' $(if(-not $g.rate -and $g.historical_rate){'历史系数（参考）'}else{'当前采用系数'}) $rateText)
        (Fact 'ratekind' '换算口径' $rateKind)
        (Fact 'training' '全局训练 / 验证' ((Format-Count $c.train)+' / '+$c.holdout+' 个区间；近 '+$c.history_days+' 天'))
        (Fact 'error' '本次验证误差' $(if($null -ne $c.mae){'{0:0.00} 个百分点' -f $c.mae}else{'等待本周期验证'}))
        (Fact 'baseline' '统一换算误差' $(if($null -ne $c.baseline_mae){'{0:0.00} 个百分点' -f $c.baseline_mae}else{'等待本周期验证'}))
    )
    if($c.historical){$facts+=@((Fact 'historyat' '历史验证时间' (Format-Time $c.historical.as_of)),(Fact 'historyerror' '历史验证误差' ((Format-Rate $c.historical.mae)+' 个百分点；仅供参考')))}
    $facts+=@(
        (Fact 'filters' '数据过滤记录' (Format-CalibrationFilters $c))
        (Fact 'covered' '已校准 token 覆盖' $(if($c.eligible_tokens){Format-Percent (100*$c.covered_tokens/$c.eligible_tokens)}else{'—'}))
        (Fact 'asof' '配额快照时间' (Format-Time $c.as_of))
        (Fact 'total' '历史累计 token' (Format-Count $g.total))
        (Fact 'uncached' '周期未缓存输入' (Format-Count $g.week_uncached))
        (Fact 'cached' '周期缓存输入' (Format-Count $g.week_cached))
        (Fact 'output' '周期输出' (Format-Count $g.week_output))
        (Fact 'reasoning' '其中推理输出' (Format-Count $g.week_reasoning))
        (Fact 'requests' '周期 / 累计响应' ((Format-Count $g.week_requests)+' / '+(Format-Count $g.requests)))
        (Fact 'unexplained' '账户快照差值' $(if($null -ne $c.unexplained_quota){'{0:0.00} 个百分点' -f $c.unexplained_quota}else{'—'}))
        (Fact 'plan' '套餐上下文' $(if($c.plan_unknown){'日志未记录套餐；变更后需重新验证'}else{'已记录'}))
        (Fact 'limitations' '估算说明' '每个有效区间至少累计 3 个配额百分点。新周期需 3 个验证区间，并通过误差检查。历史系数保留作参考；新模型独立积累样本。')
    );Sync-StateTable $tables.DetailFacts $facts
}

function Render-Process([string]$id) {
    $p=$script:processMap[$id];if(-not $p){return};Set-DetailHeader '进程 / 系统关联' $p.name ('PID '+$p.pid+' · PPID '+$p.ppid)
    $owner=if($p.thread_id -and $script:sessions.ContainsKey($p.thread_id)){$script:detailTarget=$p.thread_id;Set-Visible 'OpenSession' $true;$script:sessions[$p.thread_id].title}else{'未知 / 共享进程'}
    $association=switch($p.association){'explicit'{'命令中的明确会话标识'} 'ancestor'{'祖先进程的明确会话标识'} default{'未发现可靠会话标识'}}
    $createdAt=if($p.created){([DateTimeOffset]::Parse($p.created)).ToOffset([TimeSpan]::FromHours(8)).ToString('yyyy-MM-dd HH:mm:ss')}else{'未知'}
    Sync-StateTable $tables.DetailFacts @((Fact 'pid' 'PID' $p.pid),(Fact 'ppid' '父进程 PID' $p.ppid),(Fact 'created' '创建时间' $createdAt),(Fact 'memory' '工作集内存' (('{0:0.0} MB' -f ($p.memory/1MB)))),(Fact 'cpu' '累计 CPU 时间' (('{0:0.00} 秒' -f $p.cpu))),(Fact 'owner' '关联会话' (Clean-Title $owner)),(Fact 'association' '关联依据' $association),(Fact 'at' '最近采样' (Format-Time $snapshot.process_at)),(Fact 'note' '匹配说明' '仅使用可核实的会话标识匹配。执行编号不是 Windows PID；共享进程可能无法归属单一会话。'))
}

function Select-Session([string]$id) {
    if(-not $script:sessions.ContainsKey($id)){return}
    # A drill-down resets filters that would otherwise conceal the requested conversation.
    $script:syncing=$true
    try{$ui.Search.Text='';$ui.SessionGuardians.IsChecked=$true;$ui.ArchivedFilter.IsChecked=$true;$ui.SessionOrder.SelectedIndex=0
        $parents=Get-Parents;$cur=$id;$seen=@{};while($parents.ContainsKey($cur) -and -not $seen.ContainsKey($cur)){$seen[$cur]=$true;$cur=$parents[$cur];$script:expanded[$cur]=$true}
        $ui.NavSessions.IsChecked=$true
    }finally{$script:syncing=$false}
    Show-Page 'Session';Set-Details $true
    foreach($view in $tables.Session.DefaultView){if([string]$view.Id -eq $id){$ui.SessionGrid.SelectedItem=$view;$ui.SessionGrid.ScrollIntoView($view);break}}
    Render-Selection
}
function Hide-Monitor { $window.Hide();$window.ShowInTaskbar=$false }
function Show-Monitor { $settings.lastView='Main';Save-MonitorSettings;Hide-Mini;$window.ShowInTaskbar=$true;$window.Show();if($window.WindowState -eq 'Minimized'){$window.WindowState='Normal'};[void]$window.Activate() }
function Export-Usage {
    if(-not $script:snapshot){return};$dialog=New-Object Microsoft.Win32.SaveFileDialog;$dialog.Filter='CSV 文件 (*.csv)|*.csv';$dialog.FileName='Codex用量-'+(Get-Date -Format yyyyMMdd)+'.csv'
    if($dialog.ShowDialog($window)){
        try{$rows=foreach($s in $snapshot.sessions){[pscustomobject][ordered]@{'会话ID'=$s.id;'标题'=(Protect-Csv $s.title);'类型'=(Get-Kind $s.source);'累计token'=$s.total;'逐条累计token'=$s.recorded;'周期token'=$(if($s.week_known){$s.week_total}else{'未知'});'缓存输入token'=$s.cached;'输出token'=$s.output;'本机周期占比'=$s.local_share;'周配额校准占比'=$s.quota_estimate;'校准状态'=$snapshot.calibration.reason;'token分摊参考'=$s.quota_allocation;'完整性'=(Get-Coverage $s.coverage);'周期开始北京时间'=(Format-Time $snapshot.period.start);'周期结束北京时间'=(Format-Time $snapshot.period.end);'配额快照北京时间'=(Format-Time $snapshot.quota.at_ms)}}
            $rows|Export-Csv -LiteralPath $dialog.FileName -NoTypeInformation -Encoding UTF8;$ui.StatusText.Text='已导出 '+$rows.Count+' 个会话：'+$dialog.FileName
        }catch{Write-UiError $_}
    }
}
function Set-Autostart([bool]$enabled) {
    $runKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if($enabled){$launch='"'+(Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe')+'" -NoProfile -STA -WindowStyle Hidden -File "'+(Join-Path $baseDir 'launch.ps1')+'" -Tray';if($storage.External){$launch+=' -DataRoot "'+$storage.Data+'"'};Set-ItemProperty -LiteralPath $runKey -Name CodexUsageMonitor -Value $launch}
    else{Remove-ItemProperty -LiteralPath $runKey -Name CodexUsageMonitor -ErrorAction SilentlyContinue}
}
function New-AppMenu {
    $menu=New-Object Windows.Controls.ContextMenu
    $menu.Style=$window.FindResource([Windows.Controls.ContextMenu])
    $menu.Add_Opened({foreach($entry in $this.Items){if($entry.Tag -eq 'startup'){$entry.IsChecked=[bool](Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name CodexUsageMonitor -ErrorAction SilentlyContinue)}}})
    foreach($entry in @(@('export','导出全部会话 CSV'),@('data','打开数据目录'),@('startup','登录 Windows 后启动'),@('mini','悬浮小窗'),@('hide','收起到托盘'),@('exit','退出程序'))){
        $item=New-Object Windows.Controls.MenuItem;$item.Tag=$entry[0];$item.Header=$entry[1]
        $item.Style=$window.FindResource([Windows.Controls.MenuItem])
        if($entry[0] -eq 'startup'){$item.IsCheckable=$true;$item.IsChecked=[bool](Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name CodexUsageMonitor -ErrorAction SilentlyContinue)}
        $item.Add_Click({try{switch([string]$this.Tag){'export'{Export-Usage} 'data'{$path=$storage.Data;[void][IO.Directory]::CreateDirectory($path);Start-Process explorer.exe -ArgumentList ('"'+$path+'"')} 'startup'{Set-Autostart $this.IsChecked} 'mini'{Show-Mini} 'hide'{Hide-Monitor} 'exit'{$script:closing=$true;$window.Close()}}}catch{Write-UiError $_}})
        [void]$menu.Items.Add($item)
    }
    return ,$menu
}
$ui.MoreButton.ContextMenu=New-AppMenu;$ui.SettingsButton.ContextMenu=New-AppMenu
foreach($key in @('MoreButton','SettingsButton')){$ui[$key].Add_Click({$this.ContextMenu.PlacementTarget=$this;$this.ContextMenu.Placement='Bottom';$this.ContextMenu.IsOpen=$true})}
$ui.MethodText.Text=@'
本机用量
程序读取 Codex 的本地数据库与会话日志，不修改 Codex 源数据。只显示能够找到的用量；已清理的日志可能只留下累计快照，无法还原周期、模型或速度。

配额与自动学习
账户周配额来自日志里的账户快照，可能包含其他设备或云端使用。不能直接把 token 等同于订阅配额。本程序自动积累“模型 × 思考深度 × 服务档位”的用量与配额区间，使用时间留出验证比较换算效果，验证通过后才启用该组合的系数。新模型自动分组；样本不足时保持“待校准”。

每个有效区间至少累计 3 个配额百分点。新周期至少需要 3 个验证区间，并通过误差检查。模型页展示累计区间数和等待原因；历史系数保留作参考。拟合落在零边界的组合标记为无法可靠分离，继续积累数据。正常使用即可，不必为了校准额外消耗配额。

速度的含义
近 1 分钟 / 5 分钟输出速率是窗口内响应入账的输出 token 除以窗口秒数，包含推理 token。日志通常在响应结束时记账，因此它不是逐 token 生成速度。暂时为 0 不代表模型已停止；缺少日志时显示“未知”。本轮平均值包含工具与等待时间，首响应入账等待也不是首 token 延迟。

会话与关联
列表每行只计会话自身，详情另外列出自身 + 子树汇总，避免重复计数。会话树根据明确关联建立；会话间交互保留在“关联”页。关联页可双击跳转。最近活动显示树结构，周期 / 累计排序显示所有会话排名。

系统进程
进程树按 Windows PID、父 PID 与创建时间建立。只通过可核实的会话标识认领进程；执行编号不是 Windows PID。共享宿主无法可靠归属于单一会话时明确显示未知。

刷新与快捷键
完整统计的刷新间隔可选 5 秒、10 秒、30 秒、60 秒、5 分钟或仅手动。状态随本地记录变化更新，每秒检查补漏；仅手动会暂停全部自动采集。界面逐行更新，保留选中项、树展开状态和滚动位置。F5 立即刷新；Ctrl+F 搜索会话；Esc 收起详情。关闭或最小化窗口收起到托盘，托盘双击恢复；从菜单“退出程序”完全停止采集。时间显示为北京时间。

悬浮小窗
点击“小窗”或按 Ctrl+Shift+M 进入小窗，托盘菜单也有入口。显示所有活跃会话，子会话标明分支。每行展示近 5 分钟柱形与近 1 分钟输出均值，支持置顶和拖动。点击一行或按 Enter 打开对应 Codex 会话。完成与错误点击后动画收起，待回答显示问号。刷新菜单可选择“减少动画”。权限审批实时状态尚未接入。小窗刷新间隔独立保存；返回主窗口后恢复主窗口间隔。小窗 Esc 收起到托盘，F5 刷新，“展开”返回主窗口。数据过期时速度显示“—”，可按 F5 重试。手动模式显示快照和距更新时间。
'@
$ui.MiniModeButton.Add_Click({try{Show-Mini}catch{Write-UiError $_}})
$ui.RefreshButton.Add_Click({Refresh-Monitor})
$ui.RefreshChoice.Add_SelectionChanged({if(-not $script:ready -or $ui.RefreshChoice.SelectedIndex -lt 0){return};try{$script:refreshSeconds=$refreshValues[$ui.RefreshChoice.SelectedIndex];$settings.refreshSeconds=$refreshSeconds;Save-MonitorSettings;Send-Request 'configure'}catch{Write-UiError $_}})
$ui.DetailsButton.Add_Click({Set-Details (-not $script:detailsVisible)});$ui.CloseDetails.Add_Click({Set-Details $false})
$ui.Minimize.Add_Click({Hide-Monitor});$ui.CloseWindow.Add_Click({Hide-Monitor})
$ui.Maximize.Add_Click({$window.WindowState=if($window.WindowState -eq 'Maximized'){'Normal'}else{'Maximized'}})
$ui.CaptionBar.Add_MouseLeftButtonDown({if($_.OriginalSource -is [Windows.Controls.Button]){return};if($_.ClickCount -eq 2){$window.WindowState=if($window.WindowState -eq 'Maximized'){'Normal'}else{'Maximized'}}else{try{$window.DragMove()}catch{}}})
$window.Add_StateChanged({if($window.WindowState -eq 'Minimized'){Hide-Monitor};$ui.Maximize.Content=if($window.WindowState -eq 'Maximized'){'❐'}else{'□'}})
$window.Add_SizeChanged({if($script:ready){Update-Size}});$ui.TrendCanvas.Add_SizeChanged({if($script:chartRow){Render-Trend $script:chartRow}})
$ui.NavLive.Tag='Live';$ui.NavSessions.Tag='Session';$ui.NavModels.Tag='Model';$ui.NavProcesses.Tag='Process'
foreach($key in @('NavLive','NavSessions','NavModels','NavProcesses')){$ui[$key].Add_Checked({if(-not $script:syncing){Show-Page ([string]$this.Tag)}})}
$ui.HelpButton.Add_Click({foreach($key in @('NavLive','NavSessions','NavModels','NavProcesses')){$ui[$key].IsChecked=$false};Show-Page 'Help'})
foreach($key in @('RecentFilter','GuardianFilter','StaleFilter','SessionGuardians','ArchivedFilter')){$ui[$key].Add_Click({if(-not $script:syncing){Render-Page}})}
$ui.SessionOrder.Add_SelectionChanged({if($script:ready -and -not $script:syncing){Render-Page}})
foreach($key in @('LiveGrid','SessionGrid','ModelGrid','ProcessGrid')){$ui[$key].Add_SelectionChanged({if(-not $script:syncing){Render-Selection}})}
$ui.SessionGrid.AddHandler([Windows.Controls.Button]::ClickEvent,[Windows.RoutedEventHandler]{param($sender,$eventArgs)
    $button=$eventArgs.OriginalSource
    if($button -is [Windows.Controls.Button] -and $button.Tag -and $button.Content){$id=[string]$button.Tag;if($script:expanded.ContainsKey($id)){$script:expanded.Remove($id)}else{$script:expanded[$id]=$true};Render-Page;$eventArgs.Handled=$true}
})
$ui.SessionGrid.Add_PreviewKeyDown({
    if($ui.SessionOrder.SelectedIndex -ne 0 -or -not $ui.SessionGrid.SelectedItem){return};$id=[string]$ui.SessionGrid.SelectedItem.Id
    if($_.Key -eq 'Right' -and $ui.SessionGrid.SelectedItem.Chevron){$script:expanded[$id]=$true;Render-Page;$_.Handled=$true}
    elseif($_.Key -eq 'Left'){
        if($script:expanded.ContainsKey($id)){$script:expanded.Remove($id);Render-Page}
        else{$parents=Get-Parents;$parent=$parents[$id];if($parent){foreach($view in $tables.Session.DefaultView){if([string]$view.Id -eq $parent){$ui.SessionGrid.SelectedItem=$view;$ui.SessionGrid.ScrollIntoView($view);break}}}}
        $_.Handled=$true
    }
})
$ui.OpenSession.Add_Click({if($script:detailTarget){Select-Session $script:detailTarget}})
$ui.LiveGrid.Add_MouseDoubleClick({if($ui.LiveGrid.SelectedItem){Select-Session ([string]$ui.LiveGrid.SelectedItem.Id)}})
$ui.RelationsGrid.Add_MouseDoubleClick({if($ui.RelationsGrid.SelectedItem){Select-Session ([string]$ui.RelationsGrid.SelectedItem.Other)}})
$script:searchTimer=New-Object Windows.Threading.DispatcherTimer;$searchTimer.Interval=[TimeSpan]::FromMilliseconds(250)
$searchTimer.Add_Tick({$searchTimer.Stop();if($ui.Search.Text -and $script:page -ne 'Session'){$ui.NavSessions.IsChecked=$true}else{Render-Page}})
$ui.Search.Add_TextChanged({Set-Visible 'SearchHint' (-not $ui.Search.Text);if($script:ready -and -not $script:syncing){$searchTimer.Stop();$searchTimer.Start()}})
$window.Add_PreviewKeyDown({
    if($_.Key -eq 'M' -and ([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control) -and ([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Shift)){Show-Mini;$_.Handled=$true}
    elseif($_.Key -eq 'F5'){Refresh-Monitor;$_.Handled=$true}
    elseif($_.Key -eq 'F' -and ([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control)){[void]$ui.Search.Focus();$ui.Search.SelectAll();$_.Handled=$true}
    elseif($_.Key -eq 'Escape' -and -not $ui.RefreshChoice.IsDropDownOpen -and -not $ui.SessionOrder.IsDropDownOpen -and -not $ui.MoreButton.ContextMenu.IsOpen -and -not $ui.SettingsButton.ContextMenu.IsOpen){Set-Details $false;$_.Handled=$true}
})

$script:trayIcon=New-Object Windows.Forms.NotifyIcon;$trayIcon.Icon=New-Object Drawing.Icon((Join-Path $baseDir 'assets/app.ico'));$trayIcon.Text='Codex 用量透视 '+$appVersion;$trayIcon.Visible=$true
$trayMenu=New-Object Windows.Forms.ContextMenuStrip
[void]$trayMenu.Items.Add('打开用量透视',$null,[EventHandler]{Show-Monitor});[void]$trayMenu.Items.Add('悬浮小窗',$null,[EventHandler]{try{Show-Mini}catch{Write-UiError $_}});[void]$trayMenu.Items.Add('立即刷新',$null,[EventHandler]{Refresh-Monitor});[void]$trayMenu.Items.Add('退出程序',$null,[EventHandler]{$script:closing=$true;$window.Close()})
$trayIcon.ContextMenuStrip=$trayMenu;$trayIcon.Add_DoubleClick({Show-Monitor})
$window.Add_Closing({if(-not $script:closing){$_.Cancel=$true;Hide-Monitor}})
$window.Dispatcher.Add_UnhandledException({Write-UiError $_.Exception;$_.Handled=$true})

if($SelfTest){. (Join-Path $baseDir 'visual-checks.ps1')}
$script:poll=New-Object Windows.Threading.DispatcherTimer;$poll.Interval=[TimeSpan]::FromMilliseconds(100)
$poll.Add_Tick({
    try{
        if($showEvent.WaitOne(0)){if($settings.lastView -eq 'Mini'){Show-Mini}else{Show-Monitor}}
        if($showMiniEvent.WaitOne(0)){Show-Mini};if($showMainEvent.WaitOne(0)){Show-Monitor};if($showTrayEvent.WaitOne(0)){Hide-Mini;Hide-Monitor}
        $readCount=0
        while($script:reader -and $reader.IsCompleted -and $readCount -lt 8){
            $line=$reader.GetAwaiter().GetResult();$script:reader=$null
            if($null -ne $line){$script:reader=$backend.StandardOutput.ReadLineAsync();if($line){$message=$line|ConvertFrom-Json;switch($message.type){'ready'{Confirm-MonitorReady} 'snapshot'{Render-Snapshot $message} 'activity'{Render-Activity $message} 'processes'{Render-Processes $message} 'detail'{Apply-Detail $message} 'error'{$script:lastError=$message.message;$ui.StatusText.Text='采集异常：'+$message.message;$ui.ConnectionText.Text='采集异常';$ui.ConnectionDot.Fill=(Theme-Color 'Error')}}}}
            $readCount++
        }
        if($script:errReader -and $errReader.IsCompleted){$line=$errReader.GetAwaiter().GetResult();$script:errReader=$null;if($null -ne $line){$script:errReader=$backend.StandardError.ReadLineAsync();if($line){$script:lastError=$line;$ui.StatusText.Text=$line}}}
        if($script:backend -and $backend.HasExited){$ui.ConnectionText.Text='采集器已停止 · 可点击刷新重试';$ui.ConnectionDot.Fill=(Theme-Color 'Error');if($ReadyEvent){[Console]::Error.WriteLine('Collector failed during startup. '+$script:lastError);$script:closing=$true;$window.Close()}}
        Update-MiniMotion;Update-MiniClock
        if($SelfTest -and -not $script:checking){$script:checking=$true;try{Invoke-VisualChecks}finally{$script:checking=$false}}
    }catch{Write-UiError $_;if($SelfTest){$script:closing=$true;$window.Close()}}
})
$window.Add_ContentRendered({if(-not $script:ready){$script:ready=$true;Update-Size;try{
    Start-Collector;$poll.Start()
    if($Mini -or (-not $Main -and -not $Tray -and -not $SelfTest -and $settings.lastView -eq 'Mini')){Show-Mini}elseif($Tray){Hide-Monitor}
}catch{Write-UiError $_;if($ReadyEvent){[Console]::Error.WriteLine($_.Exception.Message);$script:closing=$true;$window.Close()}}}})
$script:application=New-Object Windows.Application
$application.ShutdownMode='OnMainWindowClose'
try{[void]$application.Run($window)}
finally{$script:closing=$true;if($script:miniWindow){try{$miniWindow.Close()}catch{}};Stop-Collector;$searchTimer.Stop();$trayIcon.Visible=$false;$trayIcon.Dispose();$trayMenu.Dispose();$showEvent.Dispose();$showMiniEvent.Dispose();$showMainEvent.Dispose();$showTrayEvent.Dispose();try{$mutex.ReleaseMutex()}catch{};$mutex.Dispose()}
