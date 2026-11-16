param([string]$Dotnet='dotnet')
. (Join-Path $PSScriptRoot 'common.ps1')
$stage=Join-Path $ProjectRoot '.build\native-publish'
$version=([IO.File]::ReadAllText((Join-Path $ProjectRoot 'src\version.json'))|ConvertFrom-Json).version
& node (Join-Path $ProjectRoot 'bin\codex-usage-monitor.cjs') install-runtime
if($LASTEXITCODE){throw 'Node runtime preparation failed'}
Remove-ProjectTree $stage
& $Dotnet publish (Join-Path $ProjectRoot 'app\CodexUsageMonitor.csproj') -c Release -r win-x64 --self-contained true -o $stage "-p:Version=$version" -p:DebugType=None
if($LASTEXITCODE){throw 'Native publish failed'}
$sdkLine=(& $Dotnet --list-sdks | Select-Object -Last 1)
if($sdkLine -match '\[(.+)\]'){
    $dotnetRoot=Split-Path -Parent $Matches[1]
    Copy-Item -LiteralPath (Join-Path $dotnetRoot 'LICENSE.txt') -Destination (Join-Path $stage 'LICENSE.dotnet.txt')
    Copy-Item -LiteralPath (Join-Path $dotnetRoot 'ThirdPartyNotices.txt') -Destination (Join-Path $stage 'THIRD-PARTY-NOTICES.dotnet.txt')
}else{throw 'Could not locate .NET license notices'}
foreach($path in @('CodexUsageMonitor.exe','CodexUsageMonitor.dll','coreclr.dll','PresentationFramework.dll','runtime\node.exe','window.xaml')){
    if(-not (Test-Path -LiteralPath (Join-Path $stage $path) -PathType Leaf)){throw ('Missing native package file: '+$path)}
}
if(Get-ChildItem -LiteralPath $stage -Recurse -File -Filter '*.ps1'){throw 'PowerShell scripts cannot ship in the native runtime package'}
