. (Join-Path $PSScriptRoot 'common.ps1')
$meta=[IO.File]::ReadAllText((Join-Path $ProjectRoot 'package.json'))|ConvertFrom-Json
$app=[IO.File]::ReadAllText((Join-Path $ProjectRoot 'src\version.json'))|ConvertFrom-Json
if($meta.version -cne $app.version){throw 'npm and app versions must match'}
$native=Join-Path $ProjectRoot '.build\native-publish'
if(-not (Test-Path -LiteralPath (Join-Path $native 'CodexUsageMonitor.exe'))){throw 'Run scripts/publish-native.ps1 first'}
$output=Join-Path $ProjectRoot 'outputs';[void][IO.Directory]::CreateDirectory($output)
$stage=Join-Path $ProjectRoot '.build\package\npm';Remove-ProjectTree $stage;[void][IO.Directory]::CreateDirectory($stage)
foreach($entry in @('package.json','runtime.json','bin','lib','README.md','LICENSE','CHANGELOG.md')){
    Copy-Item -LiteralPath (Join-Path $ProjectRoot $entry) -Destination $stage -Recurse
}
[void][IO.Directory]::CreateDirectory((Join-Path $stage 'docs'))
foreach($entry in @('user-guide.md','metrics.md')){
    Copy-Item -LiteralPath (Join-Path $ProjectRoot ('docs\'+$entry)) -Destination (Join-Path $stage 'docs')
}
Copy-Item -LiteralPath $native -Destination (Join-Path $stage 'native') -Recurse
Push-Location $stage
try{
    $result=& npm.cmd pack --ignore-scripts --json --pack-destination $output
    if($LASTEXITCODE -ne 0){throw 'npm pack failed'}
    $package=($result -join "`n")|ConvertFrom-Json
    foreach($file in $package.files){
        if($file.path -match '(^|/)(data|tests|outputs|\.build|node_modules)/|(^|/)settings\.json$|\.sqlite|\.log$|\.test\.|\.env|\.npmrc|\.ps1$'){throw ('Unexpected npm file: '+$file.path)}
    }
    foreach($required in @('native/runtime/node.exe','native/CodexUsageMonitor.exe','native/coreclr.dll','native/PresentationFramework.dll','bin/codex-usage-monitor.cjs','LICENSE')){if($required -notin $package.files.path){throw ('Missing npm file: '+$required)}}
    $archive=Join-Path $output $package.filename
    $sha=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Utf8 ($archive+'.sha256') ($sha+'  '+$package.filename+"`n")
    [pscustomobject]@{version=$meta.version;package=$archive;files=$package.files.Count;bytes=$package.size;sha256=$sha}|ConvertTo-Json
}finally{Pop-Location}
