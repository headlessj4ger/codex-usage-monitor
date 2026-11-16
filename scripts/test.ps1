param([switch]$Ui)
. (Join-Path $PSScriptRoot 'common.ps1')
$source=Join-Path $ProjectRoot 'src'
$diagnostics=Join-Path $ProjectRoot '.build\verification'
[void][IO.Directory]::CreateDirectory($diagnostics)
$node=Join-Path $source 'runtime\node.exe'
$version=([IO.File]::ReadAllText((Join-Path $source 'version.json'))|ConvertFrom-Json).version
$nodeFiles=@(Get-ChildItem -LiteralPath (Join-Path $ProjectRoot 'tests') -File -Filter '*.test.cjs'|Sort-Object Name|ForEach-Object FullName)
$nodeOutput=& $node --no-warnings --test --test-reporter=tap @nodeFiles
$nodeExit=$LASTEXITCODE
Write-Utf8 (Join-Path $diagnostics 'node-tests.tap') ($nodeOutput -join "`n")
if($nodeExit -ne 0){$nodeOutput|Write-Output;throw 'Node tests failed'}
$nodeCount=[int]([regex]::Match(($nodeOutput -join "`n"),'(?m)^# tests (\d+)').Groups[1].Value)
$report=[ordered]@{version=$version;at=(Get-Date -Format o);passed=$true;node_tests=$nodeCount;ui=$false}
if($Ui){
    $native=Join-Path $ProjectRoot '.build\native-publish\CodexUsageMonitor.exe'
    if(-not (Test-Path -LiteralPath $native)){throw 'Run scripts/publish-native.ps1 first'}
    $dir=Join-Path $diagnostics 'native-ui';Remove-ProjectTree $dir;[void][IO.Directory]::CreateDirectory($dir)
    $process=Start-Process -FilePath $native -ArgumentList ('self-test "'+$dir+'"') -PassThru -RedirectStandardOutput (Join-Path $dir 'stdout.log') -RedirectStandardError (Join-Path $dir 'stderr.log')
    $handle=$process.Handle
    if(-not $process.WaitForExit(45000)){$process.Kill();throw 'Native UI check timed out'}
    if($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $dir 'ui-checks.json'))){
        Get-Content -LiteralPath (Join-Path $dir 'stderr.log') -ErrorAction SilentlyContinue
        Get-Content -LiteralPath (Join-Path $dir 'ui-errors.log') -ErrorAction SilentlyContinue
        throw ('Native UI check failed; exit code '+$process.ExitCode)
    }
    $report.ui=$true
}
Write-Utf8 (Join-Path $diagnostics 'result.json') ($report|ConvertTo-Json)
$report|ConvertTo-Json
