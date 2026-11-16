. (Join-Path $PSScriptRoot 'common.ps1')
$version=[IO.File]::ReadAllText((Join-Path $ProjectRoot 'src\version.json'))|ConvertFrom-Json
$name='CodexUsageMonitor-'+$version.version+'-'+$version.platform
$archive=Join-Path $ProjectRoot ('outputs\'+$name+'.zip')
$expected=([IO.File]::ReadAllText((Join-Path $ProjectRoot ('outputs\'+$name+'.sha256'))).Trim() -split '\s+')[0]
if((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ine $expected){throw 'Package checksum mismatch'}
Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
$zip=[IO.Compression.ZipFile]::OpenRead($archive)
try{
    $entry=$zip.GetEntry('CodexUsageMonitor/manifest.json');if(-not $entry){throw 'Missing manifest'}
    $reader=New-Object IO.StreamReader($entry.Open());try{$manifest=$reader.ReadToEnd()|ConvertFrom-Json}finally{$reader.Dispose()}
    if($manifest.version -cne $version.version){throw 'Version mismatch'}
    $known=@{'CodexUsageMonitor/manifest.json'=$true}
    foreach($file in $manifest.files){
        $entry=$zip.GetEntry('CodexUsageMonitor/'+$file.path);if(-not $entry -or $entry.Length -ne $file.bytes){throw ('Missing or truncated file: '+$file.path)}
        $stream=$entry.Open();$algorithm=[Security.Cryptography.SHA256]::Create()
        try{$hash=([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-','').ToLowerInvariant()}finally{$stream.Dispose();$algorithm.Dispose()}
        if($hash -cne $file.sha256){throw ('File checksum mismatch: '+$file.path)}
        $known[$entry.FullName]=$true
    }
    foreach($entry in $zip.Entries){
        if(-not $known.ContainsKey($entry.FullName)){throw ('Unlisted file: '+$entry.FullName)}
        if($entry.FullName -match '/data/|/settings\.json$|\.sqlite|\.log$|\.test\.|\.tap$'){throw ('Private or test file in release: '+$entry.FullName)}
    }
    [pscustomobject]@{version=$manifest.version;verified_files=$manifest.files.Count;private_files=0;sha256=$expected;passed=$true}|ConvertTo-Json
}finally{$zip.Dispose()}
