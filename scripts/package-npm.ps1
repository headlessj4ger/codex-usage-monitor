. (Join-Path $PSScriptRoot 'common.ps1')
$meta=[IO.File]::ReadAllText((Join-Path $ProjectRoot 'package.json'))|ConvertFrom-Json
$app=[IO.File]::ReadAllText((Join-Path $ProjectRoot 'src\version.json'))|ConvertFrom-Json
if($meta.version -cne $app.version){throw 'npm and app versions must match'}
& node (Join-Path $ProjectRoot 'bin\codex-usage-monitor.cjs') install-runtime
if($LASTEXITCODE -ne 0){throw 'Runtime verification failed'}
$output=Join-Path $ProjectRoot 'outputs';[void][IO.Directory]::CreateDirectory($output)
Push-Location $ProjectRoot
try{
    $result=& npm.cmd pack --ignore-scripts --json --pack-destination $output
    if($LASTEXITCODE -ne 0){throw 'npm pack failed'}
    $package=($result -join "`n")|ConvertFrom-Json
    foreach($file in $package.files){
        if($file.path -match '(^|/)(data|tests|outputs|\.build|node_modules)/|(^|/)settings\.json$|\.sqlite|\.log$|\.test\.|\.env|\.npmrc'){throw ('Unexpected npm file: '+$file.path)}
    }
    foreach($required in @('src/runtime/node.exe','src/storage.ps1','bin/codex-usage-monitor.cjs','LICENSE')){if($required -notin $package.files.path){throw ('Missing npm file: '+$required)}}
    $archive=Join-Path $output $package.filename
    $sha=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Utf8 ($archive+'.sha256') ($sha+'  '+$package.filename+"`n")
    [pscustomobject]@{version=$meta.version;package=$archive;files=$package.files.Count;bytes=$package.size;sha256=$sha}|ConvertTo-Json
}finally{Pop-Location}
