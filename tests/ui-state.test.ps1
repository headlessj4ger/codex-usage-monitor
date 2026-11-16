$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Data
. (Join-Path $PSScriptRoot '..\src\ui-state.ps1')
function Assert-State([bool]$value,[string]$message){if(-not $value){throw $message}}
$script:changes=@{added=0;removed=0;cells=0};$table=New-StateTable @('Title','Value')
Sync-StateTable $table @(@{Id='a';Title='第一行';Value='100'},@{Id='b';Title='第二行';Value='200'})
$row=$table.Rows.Find('a');$view=$table.DefaultView[0];$script:events=New-Object 'System.Collections.Generic.List[string]'
$table.DefaultView.add_ListChanged({$script:events.Add([string]$_.ListChangedType)})
$script:changes=@{added=0;removed=0;cells=0}
Sync-StateTable $table @(@{Id='a';Title='第一行';Value='100'},@{Id='b';Title='第二行';Value='200'})
Assert-State (($changes.added+$changes.removed+$changes.cells) -eq 0 -and $events.Count -eq 0) 'Unchanged data notified the view'
Sync-StateTable $table @(@{Id='a';Title='第一行';Value='101'},@{Id='b';Title='第二行';Value='200'})
Assert-State ([object]::ReferenceEquals($view,$table.DefaultView[0]) -and $row.Value -eq '101' -and $changes.cells -eq 1 -and $events -notcontains 'Reset') 'Value update rebuilt view rows'
Sync-StateTable $table @(@{Id='c';Title='新增行';Value='300'},@{Id='a';Title='第一行';Value='101'})
Assert-State ($table.Rows.Count -eq 2 -and [object]::ReferenceEquals($view,$table.DefaultView[1]) -and $events -notcontains 'Reset') 'Insert/remove/reorder lost surviving row'
$script:sessions=@{a=@{};b=@{};c=@{}}
$script:snapshot=[pscustomobject]@{edges=@([pscustomobject]@{parent_id='a';child_id='b';kind='subagent'},[pscustomobject]@{parent_id='b';child_id='c';kind='subagent'},[pscustomobject]@{parent_id='c';child_id='a';kind='subagent'},[pscustomobject]@{parent_id='c';child_id='b';kind='interaction'})}
$parents=Get-Parents
Assert-State ($parents.Count -eq 2 -and -not $parents.ContainsKey('a')) 'Cycles or interactions entered the ownership tree'
'PASS: stable refresh, single-cell update, insert/remove/reorder, cycle-safe parent relationships (4 checks)'
