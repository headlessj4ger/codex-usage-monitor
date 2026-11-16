$script:themeColors=@{}
$themeXml=[xml][IO.File]::ReadAllText((Join-Path $PSScriptRoot 'theme.xaml'))
foreach($themeNode in $themeXml.DocumentElement.ChildNodes){if($themeNode.LocalName -eq 'SolidColorBrush'){$themeKey=$themeNode.GetAttribute('Key','http://schemas.microsoft.com/winfx/2006/xaml');$script:themeColors[$themeKey]=$themeNode.GetAttribute('Color')}}
function Theme-Color([string]$key) { if(-not $script:themeColors.ContainsKey($key)){throw ('Missing theme color: '+$key)};return [string]$script:themeColors[$key] }
function Format-Count($n) { if ($null -eq $n) { return '未知' }; return ([double]$n).ToString('N0',[Globalization.CultureInfo]::InvariantCulture) }
function Format-Short($n) { if($null -eq $n){return '未知'};if($n -ge 1e6){return ('{0:0.00} M' -f ($n/1e6))};if($n -ge 1000){return ('{0:0.0} K' -f ($n/1000))};return (Format-Count $n) }
function Format-Time($ms) { if(-not $ms){return '—'};return ([DateTimeOffset]::FromUnixTimeMilliseconds([long]$ms).ToOffset([TimeSpan]::FromHours(8)).ToString('MM-dd HH:mm:ss')) }
function Format-Percent($n) { if($null -eq $n){return '—'};return ('{0:0.00}%' -f [double]$n) }
function Format-Effort($v) { if(-not $v -or $v -eq 'unknown'){return '未记录'};return [string]$v }
function Format-Tier($v) { switch($v){'default'{'标准'} 'priority'{'优先'} default {if($v -and $v -ne 'unknown'){[string]$v}else{'未记录'}}} }
function Format-Estimate($v,$tokens=1) { if($tokens -le 0){return '—'};if($null -eq $v){return '待校准'};return (Format-Percent $v) }
function Format-Rate($n) { if($null -eq $n){return '未知'};return ('{0:N2}' -f [double]$n) }
function Format-Duration($ms) { if($null -eq $ms){return '—'};if($ms -lt 60000){return ('{0:0.0} 秒' -f ($ms/1000))};$span=[TimeSpan]::FromMilliseconds([Math]::Max(0,$ms));if($span.TotalHours -ge 1){return ('{0} 时 {1} 分' -f [Math]::Floor($span.TotalHours),$span.Minutes)};return ('{0} 分 {1} 秒' -f $span.Minutes,$span.Seconds) }
function Speed-State($s) { switch($s){'running'{'进行中'} 'quiet'{'较久无更新'} 'completed'{'已完成'} 'interrupted'{'已中断'} 'failed'{'失败'} default{'状态未知'}} }
function Get-Kind($s) { switch($s){'subagent'{'子代理'} 'guardian_review'{'审批子会话'} 'guardian'{'审批子会话'} 'fork'{'分叉'} 'attached'{'附属会话'} 'interaction'{'会话交互'} 'agent_created_thread'{'代理创建'} default{'主会话'}} }
function Get-Coverage($s) { switch($s){'records'{'逐条用量'} 'metadata'{'仅累计快照'} default{'部分日志 + 累计快照'}} }
function Clean-Title($s) { return ([string]$s -replace '[\r\n]+',' ').Trim() }
function Fact([string]$id,[string]$label,$value) { return @{Id=$id;Label=$label;Value=$(if($null -eq $value -or [string]$value -eq ''){'—'}else{[string]$value})} }
function New-StateTable([string[]]$fields) {
    $table=New-Object System.Data.DataTable
    [void]$table.Columns.Add('Id',[string]);[void]$table.Columns.Add('SortIndex',[int])
    foreach($field in $fields){[void]$table.Columns.Add($field,[string])}
    $table.PrimaryKey=[System.Data.DataColumn[]]@($table.Columns['Id'])
    $table.DefaultView.Sort='SortIndex ASC'
    return ,$table
}
function Sync-StateTable($table,[object[]]$items) {
    # DataRowView notifies WPF per cell. ItemsSource, rows, selection and scroll containers survive refreshes.
    $seen=@{};$index=0
    foreach($item in $items){
        $id=[string]$item.Id;if(-not $id -or $seen.ContainsKey($id)){continue};$seen[$id]=$true
        $row=$table.Rows.Find($id)
        if($null -eq $row){$row=$table.NewRow();$row.Id=$id;$row.SortIndex=$index;foreach($col in $table.Columns){if($col.ColumnName -notin @('Id','SortIndex')){$row[$col.ColumnName]=[string]$item[$col.ColumnName]}};[void]$table.Rows.Add($row);$script:changes.added++}
        else{
            if($row.SortIndex -ne $index){$row.SortIndex=$index;$script:changes.cells++}
            foreach($col in $table.Columns){$key=$col.ColumnName;if($key -in @('Id','SortIndex')){continue};$value=[string]$item[$key];if([string]$row[$key] -cne $value){$row[$key]=$value;$script:changes.cells++}}
        }
        $index++
    }
    for($i=$table.Rows.Count-1;$i -ge 0;$i--){if(-not $seen.ContainsKey([string]$table.Rows[$i].Id)){$table.Rows.RemoveAt($i);$script:changes.removed++}}
}
function Get-Parents {
    $parents=@{}
    foreach($edge in $script:snapshot.edges){
        if($edge.kind -eq 'interaction' -or $edge.child_id -eq $edge.parent_id -or -not $script:sessions.ContainsKey($edge.child_id) -or -not $script:sessions.ContainsKey($edge.parent_id) -or $parents.ContainsKey($edge.child_id)){continue}
        $seen=@{};$seen[$edge.child_id]=$true;$current=$edge.parent_id;$cycle=$false
        while($current){if($seen.ContainsKey($current)){$cycle=$true;break};$seen[$current]=$true;$current=$parents[$current]}
        if(-not $cycle){$parents[$edge.child_id]=$edge.parent_id}
    }
    return $parents
}
function Get-SessionRows {
    $parents=Get-Parents;$visible=@{};$query=$ui.Search.Text.Trim();$order=[Math]::Max(0,$ui.SessionOrder.SelectedIndex)
    foreach($s in $script:sessions.Values){
        if((-not $ui.SessionGuardians.IsChecked -and $s.source -eq 'guardian_review') -or (-not $ui.ArchivedFilter.IsChecked -and $s.archived)){continue}
        $hay=$s.title+' '+$s.id+' '+$s.cwd+' '+$s.agent_path
        if(-not $query -or $hay.IndexOf($query,[StringComparison]::OrdinalIgnoreCase) -ge 0){$visible[$s.id]=$true}
    }
    if($query -and $order -eq 0){foreach($id in @($visible.Keys)){$cur=$id;$seen=@{};while($parents.ContainsKey($cur) -and -not $seen.ContainsKey($cur)){$seen[$cur]=$true;$cur=$parents[$cur];$visible[$cur]=$true}}}
    $sortKey=@('updated','week_total','total')[$order]
    $sorted=@($script:sessions.Values|Where-Object {$visible.ContainsKey($_.id)}|Sort-Object @{Expression=$sortKey;Descending=$true},id)
    $children=@{};$roots=New-Object 'System.Collections.Generic.List[object]'
    foreach($s in $sorted){$p=$parents[$s.id];if($order -eq 0 -and $p -and $visible.ContainsKey($p)){if(-not $children.ContainsKey($p)){$children[$p]=New-Object 'System.Collections.Generic.List[object]'};$children[$p].Add($s)}else{$roots.Add($s)}}
    $stack=New-Object 'System.Collections.Generic.Stack[object]'
    for($i=$roots.Count-1;$i -ge 0;$i--){$stack.Push(@{Session=$roots[$i];Depth=0})}
    while($stack.Count){
        $entry=$stack.Pop();$s=$entry.Session;$depth=$entry.Depth;$hasChild=$children.ContainsKey($s.id);$expanded=$hasChild -and ($query -or $script:expanded.ContainsKey($s.id))
        $note=(Get-Kind $s.source)+' · '+$s.model
        if($hasChild){$note+=' · '+$children[$s.id].Count+' 个子会话'}
        if($s.archived){$note+=' · 已归档'}
        @{Id=$s.id;Title=(Clean-Title $s.title);Subtitle=$note;Indent=([Math]::Min($depth,10)*16).ToString()+',0,0,0';Chevron=$(if($hasChild){if($expanded){'⌄'}else{'›'}}else{''});Week=$(if($s.week_known){Format-Count $s.week_total}else{'未知'});Estimate=(Format-Estimate $s.quota_estimate $s.week_total);Tooltip=$s.title+"`n"+$s.id+"`n"+$s.cwd}
        if($expanded){$list=$children[$s.id];for($i=$list.Count-1;$i -ge 0;$i--){$stack.Push(@{Session=$list[$i];Depth=$depth+1})}}
    }
}
function Get-ProcessRows {
    $byPid=@{};$script:processMap=@{}
    foreach($p in $script:snapshot.processes){$byPid[[string]$p.pid]=$p;$script:processMap[([string]$p.pid+'|'+$p.created)]=$p}
    $children=@{};$roots=New-Object 'System.Collections.Generic.List[object]'
    foreach($p in ($script:snapshot.processes|Sort-Object pid)){
        $parent=$byPid[[string]$p.ppid];$valid=$parent -and $p.pid -ne $p.ppid -and $p.created -and $parent.created -and [DateTime]::Parse($parent.created) -le [DateTime]::Parse($p.created)
        if($valid){$id=[string]$p.ppid;if(-not $children.ContainsKey($id)){$children[$id]=New-Object 'System.Collections.Generic.List[object]'};$children[$id].Add($p)}else{$roots.Add($p)}
    }
    $stack=New-Object 'System.Collections.Generic.Stack[object]';$seen=@{}
    for($i=$roots.Count-1;$i -ge 0;$i--){$stack.Push(@{Process=$roots[$i];Depth=0})}
    while($stack.Count){$entry=$stack.Pop();$p=$entry.Process;$id=[string]$p.pid;if($seen.ContainsKey($id)){continue};$seen[$id]=$true
        $owner=if($p.thread_id -and $script:sessions.ContainsKey($p.thread_id)){$script:sessions[$p.thread_id].title}else{'会话归属未知 / 共享进程'}
        @{Id=$id+'|'+$p.created;Title=$p.name;Subtitle=(Clean-Title $owner);Indent=([Math]::Min(10,$entry.Depth)*16).ToString()+',0,0,0';Pid=$id;Memory=('{0:N1}' -f ($p.memory/1MB));Tooltip='PPID '+$p.ppid+"`n创建于 "+$p.created+"`n关联依据："+$p.association}
        $list=$children[$id];if($list){for($i=$list.Count-1;$i -ge 0;$i--){$stack.Push(@{Process=$list[$i];Depth=$entry.Depth+1})}}
    }
}
function Protect-Csv($value) { $s=[string]$value;if($s -match '^[=+@\-\t\r]'){return "'"+$s};return $s }
