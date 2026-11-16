$ErrorActionPreference='Stop'
$script:ProjectRoot=(Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
function Assert-ProjectChild([string]$Path) {
    $resolved=[IO.Path]::GetFullPath($Path)
    if(-not $resolved.StartsWith($ProjectRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw ('Path outside project: '+$resolved)}
    return $resolved
}
function Remove-ProjectTree([string]$Path) {
    $resolved=Assert-ProjectChild $Path
    if(-not (Test-Path -LiteralPath $resolved)){return}
    $item=Get-Item -LiteralPath $resolved -Force
    if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw ('Refusing linked path: '+$resolved)}
    if($item.PSIsContainer -and @(Get-ChildItem -LiteralPath $resolved -Recurse -Force -Attributes ReparsePoint).Count){throw ('Refusing tree with links: '+$resolved)}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
function Write-Utf8([string]$Path,[string]$Text) {
    [IO.File]::WriteAllText($Path,$Text,(New-Object Text.UTF8Encoding($false)))
}
