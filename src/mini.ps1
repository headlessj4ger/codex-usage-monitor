# Compact native WPF activity list. All windows share one collector and PowerShell host.
$script:miniWindow=$null;$script:miniUi=@{};$script:miniTable=$null;$script:miniOrder=@()
$script:miniRefreshValues=@(5,10,30,60,0);$script:miniRefreshSeconds=5
$script:miniClock=[DateTime]::MinValue;$script:miniFresh=$null;$script:miniGlass='pending'
$script:miniMenu=$null;$script:miniRefreshItems=@{};$script:miniNewLine=[Environment]::NewLine
$script:miniGlassSource=$null;$script:miniGlassHook=$null
function Save-MonitorSettings {
    $parent=[IO.Path]::GetDirectoryName($settingsPath);[void][IO.Directory]::CreateDirectory($parent)
    $temp=$settingsPath+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllText($temp,($script:settings|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($true)))
        if([IO.File]::Exists($settingsPath)){[IO.File]::Replace($temp,$settingsPath,[System.Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($temp,$settingsPath)}
    } finally { if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)} }
}
function Get-EffectiveInterval {
    if($script:miniWindow -and $miniWindow.IsVisible){return $script:miniRefreshSeconds}
    return $script:refreshSeconds
}
function Test-MiniActive($row) {
    if($null -ne $row.mini_visible){return [bool]$row.mini_visible}
    return ($row.is_open -and $row.state -eq 'running' -and -not $row.long_stale -and $row.source -notin @('guardian_review','guardian'))
}
function Get-MiniEntries([object[]]$rows,[string[]]$previous=@()) {
    # Preserve order as rates change; place active children after their active parent.
    $rank=@{};for($i=0;$i -lt $previous.Count;$i++){$rank[$previous[$i]]=$i}
    $ordered=@($rows|Where-Object {Test-MiniActive $_}|Sort-Object @{Expression={if($rank.ContainsKey([string]$_.id)){$rank[[string]$_.id]}else{[int]::MaxValue}}},@{Expression='started_ms';Descending=$true},id)
    $byId=@{};$children=@{};$roots=@()
    foreach($row in $ordered){$byId[[string]$row.id]=$row}
    foreach($row in $ordered){
        $parent=[string]$row.parent_id
        if($parent -and $parent -ne $row.id -and $byId.ContainsKey($parent)){
            if(-not $children.ContainsKey($parent)){$children[$parent]=New-Object 'System.Collections.Generic.List[object]'}
            $children[$parent].Add($row)
        }else{$roots+=,$row}
    }
    $seen=@{};$stack=New-Object 'System.Collections.Generic.Stack[object]'
    # Second pass keeps malformed cyclic relations visible without recursion or duplicates.
    foreach($root in @($roots)+@($ordered)){
        if($seen.ContainsKey([string]$root.id)){continue}
        $stack.Push(@{Row=$root;Depth=0;VisibleParentId=''})
        while($stack.Count){
            $entry=$stack.Pop();$row=$entry.Row;$id=[string]$row.id
            if($seen.ContainsKey($id)){continue};$seen[$id]=$true
            $entry
            $list=$children[$id]
            if($list){for($i=$list.Count-1;$i -ge 0;$i--){$stack.Push(@{Row=$list[$i];Depth=$entry.Depth+1;VisibleParentId=$id})}}
        }
    }
}
function Format-MiniRate($value) {
    if($null -eq $value -or [double]::IsNaN([double]$value) -or [double]::IsInfinity([double]$value) -or [double]$value -lt 0){return '—'}
    if($value -gt 0 -and $value -lt 0.1){return '<0.1'}
    if($value -ge 1000){return (([double]$value/1000).ToString('0.0',[Globalization.CultureInfo]::InvariantCulture)+'k')}
    return ([double]$value).ToString('0.0',[Globalization.CultureInfo]::InvariantCulture)
}
function Get-MiniScale([object[]]$entries) {
    $maximum=0.0
    foreach($entry in $entries){if($entry.Row.available){foreach($point in $entry.Row.trend){if($null -ne $point.output_tps -and -not [double]::IsNaN([double]$point.output_tps) -and -not [double]::IsInfinity([double]$point.output_tps)){$maximum=[Math]::Max($maximum,[double]$point.output_tps)}}}}
    if($maximum -le 0){return 1.0}
    $step=[Math]::Pow(10,[Math]::Floor([Math]::Log10($maximum)))
    return [Math]::Ceiling($maximum/$step)*$step
}
function Get-MiniDisplayRows([object[]]$entries,[bool]$fresh,[double]$scale) {
    foreach($entry in $entries){
        $row=$entry.Row;$child=($row.parent_id -or $row.source -eq 'subagent')
        # A relationship in the data is not a visible tree edge when its parent is filtered out.
        $nested=([int]$entry.Depth -gt 0 -and $entry.VisibleParentId -and [string]$entry.VisibleParentId -ceq [string]$row.parent_id)
        $title=Clean-Title $row.title;if(-not $title){$title=[string]$row.id}
        $model=if($row.model -and $row.model -ne 'unknown'){$row.model}else{'模型未记录'}
        $subtitle=$(if($child){'子会话 · '}else{''})+$model+' · '+(Format-Effort $row.effort)
        $rate=if($fresh -and $row.available){Format-MiniRate $row.one.output_tps}else{'—'}
        $displayState=if($row.display_state){[string]$row.display_state}else{[string]$row.state}
        $tone=Theme-Color 'Accent';$mark='';$rowFill='Transparent'
        switch($displayState){
            'waiting'{$tone=Theme-Color 'Warning';$mark='?';$rowFill='#09DEBF83'}
            'failed'{$tone=Theme-Color 'Error';$mark='!';$rowFill='#09F2949A'}
            'interrupted'{$tone=Theme-Color 'TextMuted';$mark='!'}
            'completed'{$tone='#9CBEB1';$mark='✓'}
            'quiet'{$tone=Theme-Color 'TextMuted'}
            'starting'{$rate='—'}
        }
        $state=switch($displayState){'waiting'{'等待回答'} 'failed'{'会话出错，点击查看'} 'interrupted'{'会话已中断，点击查看'} 'completed'{'已完成，点击查看并收起'} 'starting'{'会话已开始'} 'quiet'{'暂无新用量记录'} default{'进行中'}}
        if(-not $fresh){$state+=' · 数据待更新'}
        if($mark){$rate=''}
        $tooltip=$title+$miniNewLine+$subtitle+$miniNewLine+$state+' · 近 1 分钟 '+$rate+' tok/s'+$miniNewLine+'每行仅计自身输出，包含推理 token；响应结束后入账。'
        $parentTitle=''
        if($row.parent_id){
            $parentId=[string]$row.parent_id
            if($speedRows.ContainsKey($parentId)){$parentTitle=Clean-Title $speedRows[$parentId].title}
            elseif($script:sessions -and $script:sessions.ContainsKey($parentId)){$parentTitle=Clean-Title $script:sessions[$parentId].title}
            if(-not $parentTitle){$parentTitle=$parentId}
            $tooltip+=$miniNewLine+'父会话：'+$parentTitle
            if(-not $nested){$tooltip+=$miniNewLine+'父会话当前未在小窗显示'}
        }
        $item=@{Id=[string]$row.id;Title=$title;Subtitle=$subtitle;Rate=$rate;RateTone=$(if($fresh){(Theme-Color 'TextPrimary')}else{(Theme-Color 'TextMuted')});Tone=$(if($fresh -and $row.available){(Theme-Color 'Accent')}else{(Theme-Color 'TextMuted')});Branch=$(if($nested){'└'}else{''});Indent=((8+20*$(if($nested){[Math]::Min(2,[int]$entry.Depth)}else{0}))).ToString()+',0,0,0';Tooltip=$tooltip;Accessible=$title+'，'+$state+'，'+$rate+' token 每秒';ChartOpacity=$(if($fresh -and $row.available){'1'}else{'0.3'});ChartLabel='近 5 分钟输出速率，每柱 30 秒，共用刻度 0 至 '+($scale.ToString('0.###',[Globalization.CultureInfo]::InvariantCulture))+' token 每秒'}
        $item.Tone=$tone;$item.State=$displayState;$item.Mark=$mark;$item.RowFill=$rowFill
        $item.ChartTone=if($displayState -eq 'failed'){'#9BF2949A'}elseif($displayState -in @('waiting','interrupted')){'#807E919B'}else{Theme-Color 'Chart'}
        $item.ChartLastTone=if($displayState -in @('waiting','interrupted')){'#B07E919B'}else{$tone}
        $item.TitleTone=Theme-Color 'TextPrimary';$item.SubtitleTone=Theme-Color 'TextMuted'
        if($displayState -eq 'interrupted'){
            $item.TitleTone='#929BAA';$item.SubtitleTone='#7E8999';$item.Tone='#929BAA';$item.RateTone='#929BAA'
            $item.ChartTone='#608994A3';$item.ChartLastTone='#908994A3'
        }
        $item.MarkVisibility=if($mark){'Visible'}else{'Collapsed'};$item.RateVisibility=if($mark){'Collapsed'}else{'Visible'}
        $item.RingVisibility=if($mark -in @('?','!')){'Visible'}else{'Collapsed'}
        if($mark){$item.Accessible=$title+'，'+$state}
        if($parentTitle){$item.Accessible+='，父会话：'+$parentTitle}
        $trend=@($row.trend|Where-Object {$null -ne $_})
        for($i=0;$i -lt 10;$i++){
            $point=if($i -lt $trend.Count){$trend[$i]}else{$null}
            $value=if($row.available -and $point -and $null -ne $point.output_tps){[double]$point.output_tps}else{0}
            if([double]::IsNaN($value) -or [double]::IsInfinity($value)){$value=0}
            $item['H'+$i]=([Math]::Max(0,[Math]::Min(32,32*$value/[Math]::Max(0.000001,$scale)))).ToString('0.###',[Globalization.CultureInfo]::InvariantCulture)
            $item['T'+$i]=if($point -and $row.available){(Format-Time ($point.at-30000))+' — '+(Format-Time $point.at)+$miniNewLine+(Format-MiniRate $point.output_tps)+' tok/s'+$(if(-not $fresh){$miniNewLine+'快照待更新'}else{''})}else{'尚无用量记录'}
        }
        $item
    }
}
function Set-MiniText([string]$name,[string]$value) {
    if($miniUi[$name].Text -cne $value){$miniUi[$name].Text=$value}
}
function Initialize-MiniGlass {
    try {
        if(-not ('CodexMiniGlass' -as [type])){
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CodexMiniGlass {
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out int value, int size);
    [DllImport("user32.dll", EntryPoint="GetWindowLongW")] static extern int GetWindowLong(IntPtr window, int index);
    [DllImport("user32.dll", EntryPoint="SetWindowLongW", SetLastError=true)] static extern int SetWindowLong(IntPtr window, int index, int value);
    [DllImport("user32.dll", SetLastError=true)] static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll", EntryPoint="DefWindowProcW")] static extern IntPtr DefWindowProc(IntPtr window, int message, IntPtr wParam, IntPtr lParam);
    public static int CaptionFillResult { get; private set; }
    public static int InactiveAppearanceMessages { get; private set; }
    public static IntPtr FilterBackdropActivation(IntPtr window, int message, IntPtr wParam, IntPtr lParam, ref bool handled) {
        if(message==0x0086) { // WM_NCACTIVATE: frame appearance, not WM_ACTIVATE/input focus.
            if(wParam==IntPtr.Zero)InactiveAppearanceMessages++;
            handled=true;
            // Retain DWM's acrylic appearance without painting a native title bar.
            DefWindowProc(window,message,new IntPtr(1),new IntPtr(-1));
            return new IntPtr(1); // Allow the real active window/input focus to change.
        }
        return IntPtr.Zero;
    }
    public static void RefreshBackdropAppearance(IntPtr window) {
        DefWindowProc(window,0x0086,new IntPtr(1),new IntPtr(-1));
    }
    public static bool HasSystemCaptionButtons(IntPtr window) {
        return (GetWindowLong(window,-16)&0x00080000)!=0;
    }
    public static void HideSystemCaptionButtons(IntPtr window) {
        // Keep WS_CAPTION for DWM's rounded frame, remove WS_SYSMENU so it cannot paint
        // a second close button/title strip. UseAeroCaptionButtons only changes hit testing.
        int style=GetWindowLong(window,-16);
        if((style&0x00080000)==0)return;
        if(SetWindowLong(window,-16,style&~0x00080000)==0)
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        // Recalculate the frame without moving, resizing, activating or changing z-order.
        if(!SetWindowPos(window,IntPtr.Zero,0,0,0,0,0x0037))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }
    public static int Enable(IntPtr window) {
        HideSystemCaptionButtons(window);
        // WindowChrome retains the native frame. DWM owns its only rounded edge and border.
        int dark=1, corners=2, border=0x00807066, backdrop=3, caption=-2;
        DwmSetWindowAttribute(window,20,ref dark,4);
        DwmSetWindowAttribute(window,33,ref corners,4);
        DwmSetWindowAttribute(window,34,ref border,4);
        // Suppress the system accent-colored caption fill over the custom WPF header.
        CaptionFillResult=DwmSetWindowAttribute(window,35,ref caption,4);
        // WindowChrome already extends the frame to the entire client area.
        return DwmSetWindowAttribute(window,38,ref backdrop,4);
    }
    public static int ReadBackdrop(IntPtr window) {
        int value; return DwmGetWindowAttribute(window,38,out value,4)<0 ? -1 : value;
    }
}
'@
        }
        $helper=New-Object Windows.Interop.WindowInteropHelper($miniWindow)
        $source=[Windows.Interop.HwndSource]::FromHwnd($helper.Handle)
        $source.CompositionTarget.BackgroundColor=[Windows.Media.Colors]::Transparent
        $result=[CodexMiniGlass]::Enable($helper.Handle)
        if($result -lt 0 -or [Windows.SystemParameters]::HighContrast){throw 'System backdrop unavailable'}
        $script:miniGlassSource=$source
        $script:miniGlassHook=[Delegate]::CreateDelegate([Windows.Interop.HwndSourceHook],[CodexMiniGlass].GetMethod('FilterBackdropActivation'))
        $source.AddHook($miniGlassHook)
        [CodexMiniGlass]::RefreshBackdropAppearance($helper.Handle)
        $miniWindow.Background=[Windows.Media.Brushes]::Transparent
        $miniUi.MiniSurface.Background=(Theme-Color 'GlassTint');$script:miniGlass='Desktop Acrylic'
    } catch {
        $miniWindow.Background=(Theme-Color 'WindowSurface');$miniUi.MiniSurface.Background=(Theme-Color 'WindowSurface');$script:miniGlass='solid fallback'
    }
}
function Sync-MiniNativeCaption {
    if(-not $script:miniWindow -or -not ('CodexMiniGlass' -as [type])){return}
    $helper=New-Object Windows.Interop.WindowInteropHelper($miniWindow)
    if($helper.Handle -ne [IntPtr]::Zero){[CodexMiniGlass]::HideSystemCaptionButtons($helper.Handle)}
}
function Set-MiniInterval([int]$seconds) {
    if($seconds -notin $miniRefreshValues){return}
    $script:miniRefreshSeconds=$seconds;$settings.miniRefreshSeconds=$seconds;Save-MonitorSettings
    foreach($value in $miniRefreshValues){$miniRefreshItems[$value].IsChecked=($seconds -eq $value)}
    Set-MiniText 'MiniRefreshLabel' $(if($seconds -gt 0){$seconds.ToString()+' 秒刷新'}else{'手动刷新'})
    Send-Request 'configure';$script:miniClock=[DateTime]::MinValue;Update-MiniClock
}
function Expand-MiniSession {
    $selected=$miniUi.MiniList.SelectedItem;$id=if($selected){[string]$selected.Id}else{''}
    Show-Monitor;$ui.NavLive.IsChecked=$true
    if($id){foreach($view in $tables.Live.DefaultView){if($view.Id -eq $id){$ui.LiveGrid.SelectedItem=$view;$ui.LiveGrid.ScrollIntoView($view);break}}}
}
function Open-MiniSession {
    $selected=$miniUi.MiniList.SelectedItem;if(-not $selected){return}
    $id=[string]$selected.Id
    if($id -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'){throw '此会话没有可打开的 Codex 会话 ID'}
    try {
        $start=New-Object Diagnostics.ProcessStartInfo;$start.FileName='codex://threads/'+$id;$start.UseShellExecute=$true
        [void][Diagnostics.Process]::Start($start)
        $row=$speedRows[$id]
        if($row -and -not $row.is_open -and -not $row.requires_input){Send-Request 'acknowledge' $id ([string]$row.turn_id)}
    } catch {
        $miniUi.MiniStatus.Text='打开失败 · 点击重试';$miniUi.MiniFreshness.Text=$_.Exception.Message
        Write-UiError $_
    }
}
function New-MiniWindow {
    if($script:miniWindow){return}
    $path=Join-Path $baseDir 'mini.xaml';$xmlReader=[Xml.XmlReader]::Create($path)
    try{$script:miniWindow=[Windows.Markup.XamlReader]::Load($xmlReader)}finally{$xmlReader.Close()}
    $miniWindow.Icon=$window.Icon
    $xml=[xml][IO.File]::ReadAllText($path)
    foreach($element in $xml.SelectNodes('//*[@*[local-name()="Name"]]')){
        $name=$element.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml')
        $control=$miniWindow.FindName($name);if($control){$miniUi[$name]=$control}
    }
    if($settings.ContainsKey('miniRefreshSeconds') -and $settings.miniRefreshSeconds -in $miniRefreshValues){$script:miniRefreshSeconds=[int]$settings.miniRefreshSeconds}
    $miniWindow.Topmost=(-not $settings.ContainsKey('miniTopmost') -or [bool]$settings.miniTopmost)
    $miniUi.MiniTopmost.IsChecked=$miniWindow.Topmost
    $fields=@('Title','Subtitle','TitleTone','SubtitleTone','Rate','RateTone','Tone','Branch','Indent','Tooltip','Accessible','ChartOpacity','ChartLabel','ChartTone','ChartLastTone','SeparatorVisibility','State','Mark','RowFill','MarkVisibility','RateVisibility','RingVisibility','Phase','Motion')
    for($i=0;$i -lt 10;$i++){$fields+=@(('H'+$i),('T'+$i))}
    $script:miniTable=New-StateTable $fields;$miniUi.MiniList.ItemsSource=$miniTable.DefaultView
    $script:miniMenu=New-Object Windows.Controls.ContextMenu
    $miniMenu.Style=$miniWindow.FindResource([Windows.Controls.ContextMenu])
    foreach($value in $miniRefreshValues){
        $item=New-Object Windows.Controls.MenuItem;$item.Header=if($value){$value.ToString()+' 秒刷新'}else{'手动刷新'}
        $item.Style=$miniWindow.FindResource([Windows.Controls.MenuItem])
        $item.Tag=$value;$item.IsCheckable=$true;$item.IsChecked=($value -eq $miniRefreshSeconds)
        $item.Add_Click({try{Set-MiniInterval ([int]$this.Tag)}catch{Write-UiError $_}})
        [void]$miniMenu.Items.Add($item);$miniRefreshItems[$value]=$item
    }
    $miniUi.MiniRefresh.ContextMenu=$miniMenu
    $miniUi.MiniRefresh.ToolTip='完整统计的采样间隔。状态随本地记录变化更新；手动模式会暂停全部自动采集。'
    [void]$miniMenu.Items.Add((New-Object Windows.Controls.Separator))
    $motionItem=New-Object Windows.Controls.MenuItem;$motionItem.Header='减少动画';$motionItem.IsCheckable=$true;$motionItem.IsChecked=($settings.ContainsKey('reduceMotion') -and [bool]$settings.reduceMotion)
    $motionItem.Style=$miniWindow.FindResource([Windows.Controls.MenuItem])
    $motionItem.Add_Click({try{$settings.reduceMotion=[bool]$this.IsChecked;Save-MonitorSettings;Clear-MiniMotion;Render-Mini}catch{Write-UiError $_}})
    [void]$miniMenu.Items.Add($motionItem)
    Set-MiniText 'MiniRefreshLabel' $(if($miniRefreshSeconds){$miniRefreshSeconds.ToString()+' 秒刷新'}else{'手动刷新'})
    $miniUi.MiniRefresh.Add_Click({$miniMenu.PlacementTarget=$miniUi.MiniRefresh;$miniMenu.Placement='Top';$miniMenu.IsOpen=$true})
    $miniMenu.Add_Closed({if($miniWindow.IsVisible){[void]$miniUi.MiniRefresh.Focus()}})
    $miniUi.MiniClose.Add_Click({try{Hide-Mini}catch{Write-UiError $_}})
    $miniUi.MiniExpand.Add_Click({try{Expand-MiniSession}catch{Write-UiError $_}})
    $miniUi.MiniTopmost.Add_Click({try{$miniWindow.Topmost=($miniUi.MiniTopmost.IsChecked -eq $true);$settings.miniTopmost=$miniWindow.Topmost;Save-MonitorSettings}catch{Write-UiError $_}})
    $miniUi.MiniList.Add_PreviewMouseLeftButtonUp({try{
        $item=[Windows.Controls.ItemsControl]::ContainerFromElement($miniUi.MiniList,$_.OriginalSource)
        if($item -is [Windows.Controls.ListBoxItem] -and $item.IsSelected){Open-MiniSession}
    }catch{Write-UiError $_}})
    $miniUi.MiniList.Add_PreviewKeyDown({if($_.Key -eq 'Return'){try{Open-MiniSession;$_.Handled=$true}catch{Write-UiError $_}}})
    $miniUi.MiniCaption.Add_MouseLeftButtonDown({
        try {
            $origin=$_.OriginalSource
            while($origin -and $origin -ne $miniUi.MiniCaption){
                if($origin -is [Windows.Controls.Primitives.ButtonBase]){return}
                $origin=[Windows.Media.VisualTreeHelper]::GetParent($origin)
            }
            $miniWindow.DragMove();Save-MiniPosition
        }catch{Write-UiError $_}
    })
    $miniWindow.Add_PreviewKeyDown({try{if($_.Key -eq 'F5'){Refresh-Monitor;$_.Handled=$true}elseif($_.Key -eq 'Escape' -and -not $miniMenu.IsOpen){Hide-Mini;$_.Handled=$true}}catch{Write-UiError $_}})
    $miniWindow.Add_SourceInitialized({Initialize-MiniGlass})
    $miniWindow.Add_Loaded({try{Sync-MiniNativeCaption}catch{Write-UiError $_}})
    $miniWindow.Add_Activated({try{Sync-MiniNativeCaption}catch{Write-UiError $_}})
    $miniWindow.Add_IsVisibleChanged({if($miniWindow.IsVisible){try{Sync-MiniNativeCaption}catch{Write-UiError $_}}})
    $miniWindow.Add_Closed({if($script:miniGlassSource -and $script:miniGlassHook){if(-not $miniGlassSource.IsDisposed){$miniGlassSource.RemoveHook($miniGlassHook)};$script:miniGlassHook=$null;$script:miniGlassSource=$null}})
    $miniWindow.Add_Closing({if(-not $script:closing){$_.Cancel=$true;Hide-Mini}})
}
function Set-MiniBounds([int]$count) {
    $area=[Windows.SystemParameters]::WorkArea
    $target=[Math]::Min($area.Height-32,118+52*[Math]::Min(6,[Math]::Max(1,$count)))
    if($count -eq 0){$target=[Math]::Min($area.Height-32,208)}
    if([Math]::Abs($miniWindow.Height-$target) -gt 0.5){
        $before=$miniWindow.ActualHeight;$miniWindow.BeginAnimation([Windows.FrameworkElement]::HeightProperty,$null);$miniWindow.Height=$target
        if($miniWindow.IsVisible -and $before -gt 0 -and (Test-MiniMotion)){
            $animation=New-Object Windows.Media.Animation.DoubleAnimation($before,$target,[TimeSpan]::FromMilliseconds(220));$animation.FillBehavior='Stop'
            $ease=New-Object Windows.Media.Animation.CubicEase;$ease.EasingMode='EaseOut';$animation.EasingFunction=$ease
            $miniWindow.BeginAnimation([Windows.FrameworkElement]::HeightProperty,$animation)
        }
    }
    if(-not [double]::IsNaN($miniWindow.Top)){$miniWindow.Top=[Math]::Max($area.Top,[Math]::Min($miniWindow.Top,$area.Bottom-$target))}
}
function Show-Mini {
    $settings.lastView='Mini';Save-MonitorSettings
    New-MiniWindow;$area=[Windows.SystemParameters]::WorkArea
    Set-MiniBounds @($speedRows.Values|Where-Object {Test-MiniActive $_}).Count
    $left=if($settings.ContainsKey('miniLeft')){[double]$settings.miniLeft}else{$area.Right-$miniWindow.Width-24}
    $top=if($settings.ContainsKey('miniTop')){[double]$settings.miniTop}else{$area.Bottom-$miniWindow.Height-24}
    $miniWindow.Left=[Math]::Max($area.Left,[Math]::Min($left,$area.Right-$miniWindow.Width))
    $miniWindow.Top=[Math]::Max($area.Top,[Math]::Min($top,$area.Bottom-$miniWindow.Height))
    $miniWindow.Show();Hide-Monitor;Render-Mini;[void]$miniWindow.Activate();Send-Request 'configure';Refresh-Monitor
}
function Save-MiniPosition {
    if($script:miniWindow){$settings.miniLeft=$miniWindow.Left;$settings.miniTop=$miniWindow.Top;Save-MonitorSettings}
}
function Hide-Mini {
    if($script:miniWindow -and $miniWindow.IsVisible){$miniMenu.IsOpen=$false;Save-MiniPosition;$miniWindow.Hide();Clear-MiniMotion;Send-Request 'configure'}
}
function Get-MiniFreshness {
    $now=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $age=if($script:snapshot){[Math]::Max(0,$now-[double]$snapshot.at)}else{0}
    $stopped=-not $script:backend -or $backend.HasExited
    $stale=$miniRefreshSeconds -gt 0 -and $age -gt ([Math]::Max(15,$miniRefreshSeconds*2+5)*1000)
    $fresh=$script:snapshot -and -not $stopped -and -not $stale
    $status=if(-not $script:snapshot){'等待采集'}elseif($stopped){'采集已停止 · F5 重试'}elseif($stale){'数据已过期 · F5 重试'}elseif($miniRefreshSeconds -eq 0){'快照 · '+[int][Math]::Floor($age/1000)+' 秒前'}else{'近 1 分钟均值'}
    return @{Fresh=[bool]$fresh;Status=$status;Age=$age;Stopped=$stopped;Stale=$stale}
}
function Render-Mini {
    if(-not $script:miniWindow -or -not $miniWindow.IsVisible){return}
    $entries=@(Get-MiniEntries @($speedRows.Values) $miniOrder)
    $script:miniOrder=@($entries|ForEach-Object {[string]$_.Row.id})
    $freshness=Get-MiniFreshness;$scale=Get-MiniScale $entries
    $rows=@(Get-MiniDisplayRows $entries $freshness.Fresh $scale)
    foreach($item in $rows){$item.SeparatorVisibility='Visible'}
    if($rows.Count){$rows[$rows.Count-1].SeparatorVisibility='Collapsed'}
    Sync-MiniMotion $rows
    Set-MiniText 'MiniCount' $rows.Count.ToString()
    $miniUi.MiniEmpty.Visibility=if($miniTable.Rows.Count){'Collapsed'}else{'Visible'}
    Set-MiniText 'MiniEmptyTitle' $(if($snapshot){'暂无活跃会话'}else{'正在读取会话'})
    Set-MiniText 'MiniEmptyHint' $(if($snapshot){'新任务开始后会自动出现'}else{'首次采集完成后自动显示'})
    $miniUi.MiniList.Visibility=if($miniTable.Rows.Count){'Visible'}else{'Collapsed'}
    $miniUi.MiniTrendHeader.ToolTip='每柱 30 秒 · 所有会话共用刻度 0–'+($scale.ToString('0.###',[Globalization.CultureInfo]::InvariantCulture))+' tok/s'
    Set-MiniBounds $miniTable.Rows.Count
    $script:miniFresh=$freshness.Fresh;$script:miniClock=[DateTime]::MinValue;Update-MiniClock
}
function Update-MiniClock {
    if(-not $script:miniWindow -or -not $miniWindow.IsVisible -or ([DateTime]::UtcNow-$miniClock).TotalSeconds -lt 1){return}
    $script:miniClock=[DateTime]::UtcNow;$freshness=Get-MiniFreshness
    Set-MiniText 'MiniStatus' $freshness.Status
    Set-MiniText 'MiniFreshness' ($freshness.Status+$miniNewLine+'最近更新 '+[int][Math]::Floor($freshness.Age/1000)+' 秒前 · '+(Format-Time $snapshot.at)+$miniNewLine+'输出含推理；按响应入账，近 60 秒均值。'+$miniNewLine+'点击打开 Codex 会话；完成和错误可点击收起。'+$miniNewLine+'问号表示待回答问题；权限审批状态尚未接入。')
    $miniUi.MiniStatusDot.Fill=if($freshness.Fresh){(Theme-Color 'Accent')}else{(Theme-Color 'Warning')}
    if($null -ne $miniFresh -and $miniFresh -ne $freshness.Fresh){$script:miniFresh=$freshness.Fresh;Render-Mini}
}
