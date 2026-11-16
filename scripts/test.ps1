param([switch]$Ui)
. (Join-Path $PSScriptRoot 'common.ps1')
$source=Join-Path $ProjectRoot 'src';$tests=Join-Path $ProjectRoot 'tests'
$diagnostics=Join-Path $ProjectRoot '.build\verification';[void][IO.Directory]::CreateDirectory($diagnostics)
$node=Join-Path $source 'runtime\node.exe';$hostExe=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$version=([IO.File]::ReadAllText((Join-Path $source 'version.json'))|ConvertFrom-Json).version
foreach($file in @(Get-ChildItem -LiteralPath $source -File -Filter '*.ps1')+@(Get-ChildItem -LiteralPath $tests -File -Filter '*.ps1')+@(Get-ChildItem -LiteralPath $PSScriptRoot -File -Filter '*.ps1')){
    $tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw ($file.Name+': '+($errors.Message -join '; '))}
}
foreach($file in Get-ChildItem -LiteralPath $source -File -Filter '*.xaml'){[void]([xml][IO.File]::ReadAllText($file.FullName))}
$nodeFiles=@(Get-ChildItem -LiteralPath $tests -File -Filter '*.test.cjs'|Sort-Object Name|ForEach-Object FullName)
$nodeOutput=& $node --no-warnings --test --test-reporter=tap @nodeFiles 2>&1
$nodeExit=$LASTEXITCODE;Write-Utf8 (Join-Path $diagnostics 'node-tests.tap') ($nodeOutput -join "`n")
if($nodeExit -ne 0){$nodeOutput|Write-Output;throw 'Node tests failed'}
$nodeCount=[int]([regex]::Match(($nodeOutput -join "`n"),'(?m)^# tests (\d+)').Groups[1].Value)
foreach($name in @('ui-state.test.ps1','mini-state.test.ps1','storage.test.ps1')){
    $args=@('-NoProfile','-STA','-File',(Join-Path $tests $name))
    if($name -eq 'mini-state.test.ps1'){$args+=@('-DiagnosticDir',(Join-Path $diagnostics 'mini-unit'))}
    $result=& $hostExe @args 2>&1;$testExit=$LASTEXITCODE
    Write-Utf8 (Join-Path $diagnostics ($name+'.log')) ($result -join "`n")
    if($testExit -ne 0){throw ($name+': '+($result -join "`n"))}
}
$report=[ordered]@{version=$version;at=(Get-Date -Format o);passed=$true;node_tests=$nodeCount;powershell_state_tests=$true;syntax=$true;xml=$true;ui=$false}
if($Ui){
    foreach($test in @(
        @{Script=(Join-Path $source 'monitor.ps1');Folder='ui';Extra='-SelfTest';Result='checks.json'},
        @{Script=(Join-Path $tests 'motion-checks.ps1');Folder='motion';Extra='';Result='motion-checks.json'},
        @{Script=(Join-Path $source 'demo.ps1');Folder='demo';Extra='-SelfTest';Result='demo-checks.json'}
    )){
        $dir=Join-Path $diagnostics $test.Folder;Remove-ProjectTree $dir;[void][IO.Directory]::CreateDirectory($dir)
        $arguments='-NoProfile -STA -File "'+$test.Script+'" '+$test.Extra+' -DiagnosticDir "'+$dir+'"'
        $process=Start-Process -FilePath $hostExe -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $dir 'stdout.log') -RedirectStandardError (Join-Path $dir 'stderr.log')
        $processHandle=$process.Handle;$deadline=[DateTime]::UtcNow.AddSeconds(180)
        while(-not $process.WaitForExit(1000)){if([DateTime]::UtcNow -gt $deadline){$process.Kill();throw ($test.Folder+' timed out')}}
        if($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $dir $test.Result))){throw ($test.Folder+' failed; inspect '+$dir)}
        $errors=Join-Path $dir 'ui-errors.log';if(Test-Path -LiteralPath $errors){if((Get-Item -LiteralPath $errors).Length){throw ('UI errors: '+$errors)}}
    }
    $report.ui=$true
}
Write-Utf8 (Join-Path $diagnostics 'result.json') ($report|ConvertTo-Json)
$report|ConvertTo-Json
