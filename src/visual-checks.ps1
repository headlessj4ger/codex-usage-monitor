$script:checkPhase=0;$script:checkWait=0;$script:checks=[ordered]@{version=$appVersion;framework='native WPF';started=(Get-Date -Format o)}
function Assert-Ui([bool]$condition,[string]$message) { if(-not $condition){throw ('UI check failed: '+$message)} }
$script:miniMotionDisabled=$true # Motion has a separate timed test; these assertions inspect settled geometry.
function Save-Preview([string]$name) {
    $window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ContextIdle)
    $window.UpdateLayout()
    $window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ContextIdle)
    $window.UpdateLayout()
    $bitmap=New-Object Windows.Media.Imaging.RenderTargetBitmap([int]$window.ActualWidth,[int]$window.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($window);$encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder;$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream=[IO.File]::Create((Join-Path $DiagnosticDir $name));try{$encoder.Save($stream)}finally{$stream.Dispose()}
}
function Click-Ui($control) { $control.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent))) }
function Get-ChartElements($root) {
    if($root -is [Windows.FrameworkElement]){$binding=$root.GetBindingExpression([Windows.FrameworkElement]::HeightProperty);if($binding -and $binding.ParentBinding.Path.Path -match '^H\d$'){,@{Path=$binding.ParentBinding.Path.Path;Element=$root}}}
    for($c=0;$c -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($root);$c++){Get-ChartElements ([Windows.Media.VisualTreeHelper]::GetChild($root,$c))}
}
function Save-ControlPreview($control,[string]$name) {
    $control.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ContextIdle);$control.UpdateLayout()
    $bitmap=New-Object Windows.Media.Imaging.RenderTargetBitmap([int]($control.ActualWidth*2),[int]($control.ActualHeight*2),192,192,[Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($control);$encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder;$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream=[IO.File]::Create((Join-Path $DiagnosticDir $name));try{$encoder.Save($stream)}finally{$stream.Dispose()}
}
function Find-Visual($root,[type]$type) {
    if($root -is $type){return ,$root}
    for($i=0;$i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($root);$i++){$found=Find-Visual ([Windows.Media.VisualTreeHelper]::GetChild($root,$i)) $type;if($found){return ,$found}}
    return $null
}
function Invoke-VisualChecks {
    if(([DateTime]::UtcNow-$script:startupAt).TotalSeconds -gt 180){throw 'Visual self-test timed out'}
    if(-not $script:snapshot -or -not $snapshot.process_at){return}
    if($script:checkPhase -eq 0){
        $script:checks.sessions=$snapshot.sessions.Count;$script:checks.live=$tables.Live.Rows.Count;$script:checks.processes=$snapshot.processes.Count
        $script:checks.viewport=@($window.ActualWidth,$window.ActualHeight)
        $sourceDpi=[Windows.PresentationSource]::FromVisual($window).CompositionTarget.TransformToDevice
        $script:checks.actual_dpi=@((96*$sourceDpi.M11),(96*$sourceDpi.M22))
        Save-Preview 'live.png'
        $selected=$ui.LiveGrid.SelectedItem;$source=$ui.LiveGrid.ItemsSource;$bar=$bars[0]
        $script:changes=@{added=0;removed=0;cells=0};Render-Snapshot $snapshot
        Assert-Ui ([object]::ReferenceEquals($source,$ui.LiveGrid.ItemsSource)) 'Live ItemsSource changed'
        Assert-Ui ([object]::ReferenceEquals($selected,$ui.LiveGrid.SelectedItem)) 'Selection lost on refresh'
        Assert-Ui ([object]::ReferenceEquals($bar,$bars[0])) 'Chart rebuilt on refresh'
        Assert-Ui (($changes.added+$changes.removed+$changes.cells) -eq 0) 'Identical scan changed UI data'
        $script:checks.incremental_refresh=$changes.Clone();$script:checks.selection_preserved=$true;$script:checks.chart_objects_preserved=$true
        [void]$window.Activate();[void]$ui.Search.Focus();Assert-Ui $ui.Search.IsKeyboardFocusWithin 'Search cannot receive keyboard focus'
        $ui.MoreButton.ContextMenu.PlacementTarget=$ui.MoreButton;$ui.MoreButton.ContextMenu.IsOpen=$true
        Assert-Ui $ui.MoreButton.ContextMenu.IsOpen 'Actions menu cannot open';Save-ControlPreview $ui.MoreButton.ContextMenu 'main-menu.png';$ui.MoreButton.ContextMenu.IsOpen=$false
        $ui.RefreshChoice.IsDropDownOpen=$true;Assert-Ui $ui.RefreshChoice.IsDropDownOpen 'Refresh dropdown cannot open';$ui.RefreshChoice.IsDropDownOpen=$false
        $ui.RefreshChoice.SelectedIndex=5;Assert-Ui ($script:refreshSeconds -eq 0) 'Manual interval not applied'
        $persisted=Get-Content -LiteralPath $settingsPath -Raw|ConvertFrom-Json;Assert-Ui ($persisted.refreshSeconds -eq 0) 'Interval not persisted'
        $ui.RefreshChoice.SelectedIndex=2;$script:checks.refresh_configuration=$true
        Assert-Ui ((Protect-Csv '=SUM(A1)') -eq "'=SUM(A1)") 'CSV formula escaping failed'
        $ui.NavSessions.IsChecked=$true;Assert-Ui ($script:page -eq 'Session') 'Session navigation event not connected'
        $parents=Get-Parents;$parentId=@($parents.Values|Sort-Object -Unique|Where-Object {$tables.Session.Rows.Find($_)})|Select-Object -First 1
        if($parentId){$before=$tables.Session.Rows.Count;$script:expanded[$parentId]=$true;Render-Page;Assert-Ui ($tables.Session.Rows.Count -gt $before) 'Expanding tree did not reveal children';$script:checks.tree_expansion=$true}
        $session=@($snapshot.sessions|Sort-Object commands -Descending)[0];Select-Session $session.id
        $script:checkPhase=1;return
    }
    if($script:checkPhase -eq 1){
        if(-not $script:lastDetail -or $lastDetail.id -ne $script:selectedId){return}
        Assert-Ui ($tables.SessionFacts.Rows.Count -ge 18) 'Session facts incomplete'
        $script:checks.detail=@{commands=$tables.Commands.Rows.Count;models=$tables.SessionModels.Rows.Count;daily=$tables.Daily.Rows.Count;relations=$tables.Relations.Rows.Count}
        Save-Preview 'sessions.png';$ui.SessionDetailTabs.SelectedIndex=1;Save-Preview 'commands.png';$ui.SessionDetailTabs.SelectedIndex=0
        $scroll=Find-Visual $ui.SessionGrid ([Windows.Controls.ScrollViewer]);$scroll.ScrollToVerticalOffset(480);$window.UpdateLayout()
        $offset=$scroll.VerticalOffset;$view=$ui.SessionGrid.SelectedItem;$script:changes=@{added=0;removed=0;cells=0};Render-Page;$window.UpdateLayout()
        Assert-Ui ([Math]::Abs($scroll.VerticalOffset-$offset) -lt 1 -and [object]::ReferenceEquals($view,$ui.SessionGrid.SelectedItem)) 'Session refresh moved scroll or selection'
        $script:checks.scroll_preserved=$true
        $query=$script:selectedId;$ui.Search.Text=$query;$searchTimer.Stop();Render-Page
        Assert-Ui ($null -ne $tables.Session.Rows.Find($query)) 'Search lost matching session'
        $ui.Search.Text='';$searchTimer.Stop();$ui.SessionOrder.SelectedIndex=1;Render-Page
        Assert-Ui ($tables.Session.Rows.Count -eq $snapshot.sessions.Count) 'Ranking omitted sessions with inclusive filters'
        $ui.SessionOrder.SelectedIndex=0
        $ui.NavModels.IsChecked=$true;Assert-Ui ($tables.Model.Rows.Count -eq $snapshot.combinations.Count) 'Model groups omitted'
        Save-Preview 'models.png'
        $ui.NavProcesses.IsChecked=$true;Assert-Ui ($tables.Process.Rows.Count -eq $snapshot.processes.Count) 'Process hierarchy omitted rows';Save-Preview 'processes.png'
        $script:checks.navigation=$true;$script:checks.search_and_ranking=$true;$script:checks.process_tree=$true
        $ui.NavLive.IsChecked=$true;$window.Width=1280;$window.Height=800;$script:checkPhase=2;return
    }
    if($script:checkPhase -eq 2){Save-Preview 'live-1280.png';$window.Width=1020;$window.Height=680;$script:checkPhase=3;return}
    if($script:checkPhase -eq 3){
        Save-Preview 'live-1020.png';Assert-Ui ($ui.LiveGrid.ActualWidth -ge 450) 'Compact list too narrow';Assert-Ui ($ui.DetailPane.ActualWidth -ge 300) 'Compact detail pane too narrow'
        $script:checks.compact=@{list=$ui.LiveGrid.ActualWidth;details=$ui.DetailPane.ActualWidth;sidebar=$ui.SidebarColumn.ActualWidth}
        $script:checks.compact.columns=@($ui.LiveGrid.Columns|ForEach-Object {@{header=$_.Header;width=$_.ActualWidth}})
        Click-Ui $ui.DetailsButton;Assert-Ui (-not $script:detailsVisible) 'Detail toggle failed';Click-Ui $ui.DetailsButton
        Hide-Monitor;Assert-Ui (-not $window.IsVisible) 'Tray hide failed';Show-Monitor;Assert-Ui $window.IsVisible 'Tray restore failed'
        $script:checks.tray_hide_restore=$true
        $window.Width=[Math]::Min(1440,$area.Width-60);$window.Height=[Math]::Min(900,$area.Height-60);$script:checkPhase=4;return
    }
    if($script:checkPhase -eq 4){
        Save-Preview 'preview.png';$ui.Frame.LayoutTransform=New-Object Windows.Media.ScaleTransform(1.25,1.25);$script:checkPhase=5;return
    }
    if($script:checkPhase -eq 5){
        Save-Preview 'scale-125.png';$ui.Frame.LayoutTransform=[Windows.Media.Transform]::Identity;$script:checks.simulated_layout_scale=1.25;$script:checkPhase=6;return
    }
    if($script:checkPhase -eq 6){
        $ui.NavSessions.IsChecked=$true;$scroll=Find-Visual $ui.SessionGrid ([Windows.Controls.ScrollViewer]);$scroll.ScrollToTop();Save-Preview 'sessions-final.png'
        Show-Mini;$script:checkPhase=7;return
    }
    if($script:checkPhase -eq 7){
        $miniWindow.UpdateLayout()
        Assert-Ui ($miniWindow.IsVisible -and -not $window.IsVisible) 'Mini mode did not replace main window'
        Assert-Ui ($miniWindow.ActualWidth -eq 400) 'Mini width'
        Assert-Ui ($miniTable.Rows.Count -eq @($speedRows.Values|Where-Object {Test-MiniActive $_}).Count) 'Mini omitted active sessions'
        $source=$miniUi.MiniList.ItemsSource;$pidBefore=$backend.Id
        if($miniTable.Rows.Count){$miniUi.MiniList.SelectedIndex=0}
        $selected=$miniUi.MiniList.SelectedItem
        $script:changes=@{added=0;removed=0;cells=0};Render-Mini
        Assert-Ui ([object]::ReferenceEquals($source,$miniUi.MiniList.ItemsSource) -and [object]::ReferenceEquals($selected,$miniUi.MiniList.SelectedItem) -and ($changes.added+$changes.removed+$changes.cells) -eq 0) 'Mini refresh rebuilt or mutated unchanged rows'
        Set-MiniInterval 10;Assert-Ui ((Get-EffectiveInterval) -eq 10 -and $refreshSeconds -eq 30) 'Mini interval must be independent'
        Set-MiniInterval 0;Assert-Ui ((Get-EffectiveInterval) -eq 0 -and $miniUi.MiniStatus.Text -match '快照') 'Mini manual mode'
        Set-MiniInterval 5
        Click-Ui $miniUi.MiniRefresh;Assert-Ui $miniMenu.IsOpen 'Refresh menu cannot open';Save-ControlPreview $miniMenu 'mini-menu.png'
        $miniMenu.IsOpen=$false
        $tip=New-Object Windows.Controls.ToolTip
        $tip.Style=$miniWindow.FindResource([Windows.Controls.ToolTip]);$tip.PlacementTarget=$miniUi.MiniExpand
        try {
            $tip.Content=('长会话名称与悬停提示换行检查 '*12);$tip.IsOpen=$true
            Save-ControlPreview $tip 'mini-tooltip.png'
            Assert-Ui ($tip.ActualWidth -le 400 -and $tip.ActualHeight -gt 50) 'Mini string tooltip does not wrap'
            $tip.IsOpen=$false
            $tip.Content=New-Object Windows.Controls.TextBlock
            $tip.Content.Text='近 1 分钟均值';$tip.Content.TextWrapping='Wrap';$tip.IsOpen=$true
            $tip.UpdateLayout()
            Assert-Ui ($tip.ActualHeight -gt 0) 'Mini element tooltip failed'
        } finally {$tip.IsOpen=$false}
        $miniUi.MiniTopmost.IsChecked=$false;Click-Ui $miniUi.MiniTopmost;Assert-Ui (-not $miniWindow.Topmost) 'Topmost disabled'
        $captionHelper=New-Object Windows.Interop.WindowInteropHelper($miniWindow)
        Assert-Ui (-not [CodexMiniGlass]::HasSystemCaptionButtons($captionHelper.Handle)) 'System caption buttons returned after unpinning'
        $miniUi.MiniTopmost.IsChecked=$true;Click-Ui $miniUi.MiniTopmost;Assert-Ui $miniWindow.Topmost 'Topmost enabled'
        Assert-Ui ($backend.Id -eq $pidBefore) 'Mini created a second collector'
        $helper=New-Object Windows.Interop.WindowInteropHelper($miniWindow)
        Assert-Ui (-not [CodexMiniGlass]::HasSystemCaptionButtons($helper.Handle)) 'System caption buttons are still enabled'
        Assert-Ui ([CodexMiniGlass]::CaptionFillResult -eq 0) 'System caption fill was not disabled'
        $script:checks.mini=@{width=$miniWindow.ActualWidth;live_rows=$miniTable.Rows.Count;stable_refresh=$true;independent_interval=$true;manual_mode=$true;topmost_toggle=$true;selection_preserved=$true;same_collector=$true;material=$miniGlass;dwm_backdrop=[CodexMiniGlass]::ReadBackdrop($helper.Handle)}
        $script:checks.mini.tooltips=$true
        $script:checks.mini.native_caption_disabled=$true
        $script:checks.mini.native_caption_fill_hresult=[CodexMiniGlass]::CaptionFillResult
        Save-MiniPreview 'mini-live.png'
        $script:savedMiniRows=$script:speedRows;$script:speedRows=@{}
        $fixtureTitles=@('用量监控小窗改版','告警规则重构','单元测试补齐','部署脚本检查')
        $fixtureRates=@(44.8,31.2,18.6,9.4)
        $points=@(@(23,28,32,40,44,41,39,40,43,44.8),@(14,20,22,24,28,26,25,27,30,31.2),@(6,8,11,14,17,16,15,16,18,18.6),@(2,3,5,7,9,8,6,7,8,9.4))
        for($i=0;$i -lt 4;$i++){
            $id='fixture-'+$i
            $speedRows[$id]=[pscustomobject]@{id=$id;title=$fixtureTitles[$i];model='GPT-6.1';effort='high';parent_id=$(if($i -eq 2){'fixture-1'}else{''});source=$(if($i -eq 2){'subagent'}else{'user'});is_open=$true;state='running';long_stale=$false;available=$true;started_ms=$snapshot.at-$i*1000;one=@{output_tps=$fixtureRates[$i]};trend=@(for($j=0;$j -lt 10;$j++){@{at=$snapshot.at-(9-$j)*30000;output_tps=$points[$i][$j]}})}
        }
        $script:miniOrder=@();Render-Mini;$miniWindow.UpdateLayout()
        Assert-Ui ($miniTable.Rows.Count -eq 4 -and $miniWindow.ActualHeight -eq 326) 'Four-row compact sizing'
        $firstRow=$miniTable.Rows.Find('fixture-0')
        $firstContainer=$miniUi.MiniList.ItemContainerGenerator.ContainerFromIndex(0)
        $script:changes=@{added=0;removed=0;cells=0};Render-Mini;$miniWindow.UpdateLayout()
        Assert-Ui ([object]::ReferenceEquals($firstRow,$miniTable.Rows.Find('fixture-0')) -and [object]::ReferenceEquals($firstContainer,$miniUi.MiniList.ItemContainerGenerator.ContainerFromIndex(0))) 'Mini row/visual container recreated'
        $fixtureScroll=Find-Visual $miniUi.MiniList ([Windows.Controls.ScrollViewer])
        $script:checks.mini.fixture_layout=@{listHeight=$miniUi.MiniList.ActualHeight;scrollHeight=$fixtureScroll.ActualHeight;viewport=$fixtureScroll.ViewportHeight;extent=$fixtureScroll.ExtentHeight;scrollable=$fixtureScroll.ScrollableHeight;scrollbar=[string]$fixtureScroll.ComputedVerticalScrollBarVisibility;rowHeight=$firstContainer.ActualHeight}
        Assert-Ui ($fixtureScroll.ScrollableHeight -eq 0 -and $fixtureScroll.ComputedVerticalScrollBarVisibility -eq 'Collapsed') 'Short list has an unnecessary scrollbar'
        Save-MiniPreview 'mini-design-fixture.png'
        $script:checks.mini.chart_layout=@()
        for($r=0;$r -lt 4;$r++){
            $container=$miniUi.MiniList.ItemContainerGenerator.ContainerFromIndex($r);$view=$miniUi.MiniList.Items[$r]
            $elements=@(Get-ChartElements $container);Assert-Ui ($elements.Count -eq 10) 'Each visible row needs ten chart elements'
            foreach($element in $elements){Assert-Ui ([Math]::Abs($element.Element.ActualHeight-[double]$view[$element.Path]) -le 0.51) 'A bar rendered at the wrong height'}
            $script:checks.mini.chart_layout+=@{row=$view.Id;newestHeight=($elements|Where-Object {$_.Path -eq 'H9'}).Element.ActualHeight;rate=$view.Rate}
        }
        $savedSpeed=$snapshot.speed;$fixtureBeforePush=$script:speedRows;$sessionMapBeforePush=$script:sessions;$quotaBeforePush=$snapshot.quota
        $pushed=$fixtureBeforePush['fixture-0'].PSObject.Copy();$pushed.state='interrupted';$pushed.is_open=$false
        $pushed|Add-Member -NotePropertyName display_state -NotePropertyValue 'interrupted' -Force
        $pushed|Add-Member -NotePropertyName mini_visible -NotePropertyValue $true -Force
        $pushRows=@($pushed)+@($fixtureBeforePush.Values|Where-Object {$_.id -ne 'fixture-0'})
        Render-Activity ([pscustomobject]@{at=$snapshot.at;speed=[pscustomobject]@{rows=$pushRows;activity=$pushRows}})
        $miniWindow.UpdateLayout()
        Assert-Ui ($miniTable.Rows.Find('fixture-0').State -eq 'interrupted') 'Pushed activity did not update native mini state'
        Assert-Ui ([object]::ReferenceEquals($firstRow,$miniTable.Rows.Find('fixture-0'))) 'Pushed activity rebuilt an existing row'
        Assert-Ui ([object]::ReferenceEquals($sessionMapBeforePush,$script:sessions) -and [object]::ReferenceEquals($quotaBeforePush,$snapshot.quota)) 'Activity push changed full statistics'
        Render-Processes ([pscustomobject]@{processes=$snapshot.processes;process_at=$snapshot.process_at;process_error=$snapshot.process_error})
        Assert-Ui ($miniTable.Rows.Find('fixture-0').State -eq 'interrupted') 'Process delivery overwrote newer activity'
        $script:checks.mini.activity_push=$true;$script:checks.mini.process_delivery_independent=$true
        $snapshot.speed=$savedSpeed;$script:speedRows=$fixtureBeforePush;Render-Mini
        $oldAt=$snapshot.at;$snapshot.at=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()-120000;Render-Mini
        Assert-Ui (@($miniTable.Rows|Where-Object {$_.Rate -ne '—'}).Count -eq 0 -and $miniUi.MiniStatus.Text -match '过期') 'Stale rates still shown'
        Save-MiniPreview 'mini-stale.png';$snapshot.at=$oldAt
        $fixtureRows=$speedRows;$script:speedRows=@{};Render-Mini
        Assert-Ui ($miniTable.Rows.Count -eq 0 -and $miniUi.MiniEmpty.Visibility -eq 'Visible') 'Mini empty state'
        Save-MiniPreview 'mini-empty.png';$script:speedRows=$fixtureRows
        Assert-Ui (-not [CodexMiniGlass]::HasSystemCaptionButtons($helper.Handle)) 'System caption buttons returned when empty'
        for($i=4;$i -lt 10;$i++){$id='fixture-'+$i;$clone=$fixtureRows['fixture-0'].PSObject.Copy();$clone.id=$id;$clone.title='长标题检验 · '+('活动会话速率监控'*8);$speedRows[$id]=$clone}
        Render-Mini;$miniWindow.UpdateLayout()
        Assert-Ui ($miniTable.Rows.Count -eq 10 -and $miniWindow.ActualHeight -eq 430) 'Overflow must cap at six visible rows'
        $miniScroll=Find-Visual $miniUi.MiniList ([Windows.Controls.ScrollViewer])
        Assert-Ui ($miniScroll.ScrollableHeight -gt 0) 'Many sessions cannot scroll'
        $miniUi.MiniList.SelectedIndex=8;$miniUi.MiniList.ScrollIntoView($miniUi.MiniList.SelectedItem);$miniWindow.UpdateLayout()
        $offset=$miniScroll.VerticalOffset;$selected=$miniUi.MiniList.SelectedItem;Render-Mini;$miniWindow.UpdateLayout()
        Assert-Ui ([Math]::Abs($miniScroll.VerticalOffset-$offset) -lt 1 -and [object]::ReferenceEquals($selected,$miniUi.MiniList.SelectedItem)) 'Refresh moved mini list scroll or selection'
        Save-MiniPreview 'mini-overflow.png'
        $script:checks.mini.four_row_height=326;$script:checks.mini.six_row_limit=430;$script:checks.mini.scroll_preserved=$true;$script:checks.mini.chart_containers_preserved=$true
        $script:speedRows=$script:savedMiniRows;Render-Mini
        $miniWindow.Content.LayoutTransform=New-Object Windows.Media.ScaleTransform(1.25,1.25)
        $miniWindow.Width=500;$miniWindow.Height=$miniWindow.Height*1.25;$script:miniScaledHeight=$miniWindow.Height
        $script:checkPhase=8;return
    }
    if($script:checkPhase -eq 8){
        Save-MiniPreview 'mini-scale-125.png'
        $miniWindow.Content.LayoutTransform=[Windows.Media.Transform]::Identity;$miniWindow.Width=400
        Hide-Mini;Assert-Ui (-not $miniWindow.IsVisible -and (Get-EffectiveInterval) -eq $refreshSeconds) 'Mini hide did not restore interval'
        Show-Monitor;Assert-Ui $window.IsVisible 'Main window restore'
        Show-Mini;$miniWindow.UpdateLayout()
        $helper=New-Object Windows.Interop.WindowInteropHelper($miniWindow)
        Assert-Ui (-not [CodexMiniGlass]::HasSystemCaptionButtons($helper.Handle)) 'System caption returned after main/mini round trip'
        Assert-Ui ($miniUi.MiniClose.IsEnabled -and $miniUi.MiniCaption.ActualHeight -eq 46) 'Custom header lost controls or changed height'
        $script:checks.mini.caption_after_round_trip=$true
        $script:focusProbe=New-Object Windows.Window
        $focusProbe.Title='Codex focus regression probe';$focusProbe.Width=220;$focusProbe.Height=90;$focusProbe.ShowInTaskbar=$false
        $script:focusProbeInput=New-Object Windows.Controls.TextBox;$focusProbe.Content=$focusProbeInput
        $script:inactiveCountBefore=[CodexMiniGlass]::InactiveAppearanceMessages
        $focusProbe.Show();[void]$focusProbe.Activate();[void]$focusProbeInput.Focus()
        $script:checkPhase=9;return
    }
    if($script:checkPhase -eq 9){
        Assert-Ui (-not $miniWindow.IsActive -and $focusProbe.IsActive -and $focusProbeInput.IsKeyboardFocusWithin) 'Mini prevented another window from taking input focus'
        Assert-Ui ([CodexMiniGlass]::InactiveAppearanceMessages -gt $script:inactiveCountBefore) 'Inactive frame message was not handled'
        $helper=New-Object Windows.Interop.WindowInteropHelper($miniWindow)
        Assert-Ui ([CodexMiniGlass]::ReadBackdrop($helper.Handle) -eq 3) 'Inactive mini lost its acrylic backdrop'
        Assert-Ui ($miniUi.MiniSurface.Background.Color.A -lt 255 -and $miniWindow.Background.Color.A -eq 0) 'Inactive mini switched to an opaque WPF background'
        Assert-Ui (-not [CodexMiniGlass]::HasSystemCaptionButtons($helper.Handle)) 'Inactive mini restored a native caption'
        $miniWindow.Left+=24;$miniWindow.Top+=16;$miniWindow.UpdateLayout()
        Assert-Ui (-not $miniWindow.IsActive -and $focusProbeInput.IsKeyboardFocusWithin) 'Moving the inactive mini stole focus'
        $script:checks.mini.inactive_glass=@{dwm_backdrop=3;inactive_messages=[CodexMiniGlass]::InactiveAppearanceMessages;input_focus_transferred=$true;move_without_activation=$true}
        [void]$miniWindow.Activate();$script:checkPhase=10;return
    }
    if($script:checkPhase -eq 10){
        Assert-Ui $miniWindow.IsActive 'Mini cannot regain focus'
        Click-Ui $miniUi.MiniRefresh;Assert-Ui $miniMenu.IsOpen 'Refresh menu failed after focus round trip'
        $miniMenu.IsOpen=$false
        $focusProbe.Close();$script:focusProbe=$null
        $script:checks.mini.inactive_glass.reactivation_and_menu=$true
        Hide-Mini;Show-Monitor
        $script:checks.mini.stale_state=$true;$script:checks.mini.empty_state=$true;$script:checks.mini.simulated_layout_scale=1.25
        $script:checks.finished=(Get-Date -Format o);$script:checks.ui_errors=$script:lastError
        Assert-Ui (-not $script:lastError) ('Runtime error: '+$script:lastError)
        $checks|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $DiagnosticDir 'checks.json') -Encoding UTF8
        $script:closing=$true;$miniWindow.Close()
        Assert-Ui ($null -eq $script:miniGlassSource -and $null -eq $script:miniGlassHook) 'Backdrop hook was not released on close'
        $window.Close()
    }

}

function Save-MiniPreview([string]$name) {
 $miniWindow.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ContextIdle);$miniWindow.UpdateLayout();$bitmap=New-Object Windows.Media.Imaging.RenderTargetBitmap([int]($miniWindow.ActualWidth*2),[int]($miniWindow.ActualHeight*2),192,192,[Windows.Media.PixelFormats]::Pbgra32);$bitmap.Render($miniWindow);$encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder;$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap));$stream=[IO.File]::Create((Join-Path $DiagnosticDir $name));try{$encoder.Save($stream)}finally{$stream.Dispose()}
}
