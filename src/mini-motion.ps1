# WPF animations live in the row template. This reconciler keeps rows until exit finishes.
$script:miniEntering=@{};$script:miniLeaving=@{};$script:miniMotionDisabled=$false
function Test-MiniMotion {
    return (-not $script:miniMotionDisabled -and -not ($settings.ContainsKey('reduceMotion') -and $settings.reduceMotion) -and [Windows.SystemParameters]::ClientAreaAnimation -and -not [Windows.SystemParameters]::HighContrast)
}
function Sync-MiniMotion([object[]]$rows) {
    $now=[DateTime]::UtcNow;$motion=Test-MiniMotion;$wanted=@{};$merged=New-Object 'System.Collections.Generic.List[object]'
    foreach($item in $rows){
        $id=[string]$item.Id;$wanted[$id]=$true;$old=$miniTable.Rows.Find($id)
        if($miniLeaving.ContainsKey($id)){$miniLeaving.Remove($id);$miniEntering[$id]=$now.AddMilliseconds(240)}
        if(-not $old -and $motion){$miniEntering[$id]=$now.AddMilliseconds(240)}
        $item.Phase=if($motion -and $miniEntering.ContainsKey($id)){'enter'}else{'stable'}
        $item.Motion=if($motion){'yes'}else{'no'};$merged.Add($item)
    }
    foreach($old in @($miniTable.Rows)){
        $id=[string]$old.Id;if($wanted.ContainsKey($id)){continue}
        if(-not $motion){$miniLeaving.Remove($id);$miniEntering.Remove($id);continue}
        if(-not $miniLeaving.ContainsKey($id)){$miniLeaving[$id]=$now.AddMilliseconds(200);$miniEntering.Remove($id)}
        if($now -ge $miniLeaving[$id]){$miniLeaving.Remove($id);continue}
        $copy=@{};foreach($column in $miniTable.Columns){$copy[$column.ColumnName]=$old[$column.ColumnName]}
        $copy.Phase='exit';$copy.Motion='yes'
        $merged.Insert([Math]::Min([int]$old.SortIndex,$merged.Count),$copy)
    }
    Sync-StateTable $miniTable @($merged.ToArray())
}
function Update-MiniMotion {
    if(-not $miniWindow -or -not $miniWindow.IsVisible){return}
    $now=[DateTime]::UtcNow
    foreach($id in @($miniEntering.Keys)){if($now -ge $miniEntering[$id]){$row=$miniTable.Rows.Find($id);if($row){$row.Phase='stable'};$miniEntering.Remove($id)}}
    if(@($miniLeaving.Values|Where-Object {$_ -le $now}).Count){Render-Mini}
}
function Clear-MiniMotion {
    $miniEntering.Clear();$miniLeaving.Clear()
    if($miniTable){foreach($row in $miniTable.Rows){$row.Phase='stable'}}
}
