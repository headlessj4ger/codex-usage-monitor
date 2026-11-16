param(
    [Parameter(Mandatory=$true)][string]$SignedDirectory,
    [Parameter(Mandatory=$true)][string]$SignerThumbprint,
    [switch]$Stage
)
. (Join-Path $PSScriptRoot 'common.ps1')
$SignerThumbprint=$SignerThumbprint.Replace(' ','')
if($SignerThumbprint -notmatch '^[A-Fa-f0-9]{40}$'){throw 'Configure the production signer certificate thumbprint'}
$native=Join-Path $ProjectRoot '.build\native-publish'
$files=@('CodexUsageMonitor.exe','CodexUsageMonitor.dll')
foreach($name in $files){
    $path=Join-Path $SignedDirectory $name
    if(-not (Test-Path -LiteralPath $path -PathType Leaf)){throw ('Missing signed binary: '+$name)}
    $signature=Get-AuthenticodeSignature -LiteralPath $path
    if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Thumbprint -ine $SignerThumbprint -or -not $signature.TimeStamperCertificate){
        throw ('Missing valid timestamped production signature: '+$name)
    }
    if($signature.SignerCertificate.PublicKey.Oid.Value -ne '1.2.840.113549.1.1.1'){throw ('Expected an RSA signer: '+$name)}
    $original=Get-Item -LiteralPath (Join-Path $native $name)
    if((Get-Item -LiteralPath $path).VersionInfo.ProductVersion -cne $original.VersionInfo.ProductVersion){
        throw ('Signed version does not match the build: '+$name)
    }
}
if($Stage){
    foreach($name in $files){Copy-Item -LiteralPath (Join-Path $SignedDirectory $name) -Destination (Join-Path $native $name) -Force}
}
'Project binaries have verified timestamped production signatures.'
