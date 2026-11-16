. (Join-Path $PSScriptRoot 'common.ps1')
$source=Join-Path $ProjectRoot 'src';$version=[IO.File]::ReadAllText((Join-Path $source 'version.json'))|ConvertFrom-Json
$native=Join-Path $ProjectRoot '.build\native-publish'
if(-not (Test-Path -LiteralPath (Join-Path $native 'CodexUsageMonitor.exe'))){throw 'Run scripts/publish-native.ps1 first'}
$stage=Join-Path $ProjectRoot '.build\package\CodexUsageMonitor';Remove-ProjectTree $stage;[void][IO.Directory]::CreateDirectory($stage)
Get-ChildItem -LiteralPath $native | Copy-Item -Destination $stage -Recurse
foreach($name in @('Start.cmd','Demo.cmd')){Copy-Item -LiteralPath (Join-Path $ProjectRoot ('scripts\launcher\'+$name)) -Destination $stage}
Copy-Item -LiteralPath (Join-Path $ProjectRoot 'docs\user-guide.md') -Destination (Join-Path $stage 'README.md')
Copy-Item -LiteralPath (Join-Path $ProjectRoot 'CHANGELOG.md') -Destination $stage
Copy-Item -LiteralPath (Join-Path $ProjectRoot 'LICENSE') -Destination $stage
[void][IO.Directory]::CreateDirectory((Join-Path $stage 'docs'))
foreach($name in @('architecture.md','metrics.md','motion.md')){Copy-Item -LiteralPath (Join-Path $ProjectRoot ('docs\'+$name)) -Destination (Join-Path $stage 'docs')}
$manifestFiles=@(Get-ChildItem -LiteralPath $stage -Recurse -File|Sort-Object FullName|ForEach-Object {
    [ordered]@{path=$_.FullName.Substring($stage.Length+1).Replace('\','/');bytes=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
})
$manifest=[ordered]@{name=$version.name;version=$version.version;released=$version.released;platform=$version.platform;files=$manifestFiles}
Write-Utf8 (Join-Path $stage 'manifest.json') ($manifest|ConvertTo-Json -Depth 5)
$output=Join-Path $ProjectRoot 'outputs';[void][IO.Directory]::CreateDirectory($output)
$name='CodexUsageMonitor-'+$version.version+'-'+$version.platform
$tempArchive=Join-Path $ProjectRoot ('.build\'+$name+'.zip');Remove-ProjectTree $tempArchive
Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
$zip=[IO.Compression.ZipFile]::Open($tempArchive,[IO.Compression.ZipArchiveMode]::Create)
try{
    foreach($file in Get-ChildItem -LiteralPath $stage -Recurse -File){
        $entry='CodexUsageMonitor/'+$file.FullName.Substring($stage.Length+1).Replace('\','/')
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip,$file.FullName,$entry,[IO.Compression.CompressionLevel]::Optimal)
    }
}finally{$zip.Dispose()}
$archive=Join-Path $output ($name+'.zip');Copy-Item -LiteralPath $tempArchive -Destination $archive -Force
$sha=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Utf8 (Join-Path $output ($name+'.sha256')) ($sha+'  '+$name+".zip`n")
[pscustomobject]@{version=$version.version;package=$archive;files=$manifestFiles.Count;bytes=(Get-Item -LiteralPath $archive).Length;sha256=$sha}|ConvertTo-Json
