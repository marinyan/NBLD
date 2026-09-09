[CmdletBinding()]
param([string]$AssemblerPath)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$builder=Join-Path $root 'tools/nbld/build_nbld_loader.ps1'
$out=Join-Path $root 'build/capacity'
New-Item -ItemType Directory -Force $out | Out-Null
[byte[]]$noise=New-Object byte[] 12000
[uint32]$rng=1234567
for($i=0;$i-lt $noise.Length;$i++) {
    $rng=($rng-bxor (($rng-shl 13)-band 0xFFFFFFFF))-band 0xFFFFFFFF
    $rng=$rng-bxor ($rng-shr 17)
    $rng=($rng-bxor (($rng-shl 5)-band 0xFFFFFFFF))-band 0xFFFFFFFF
    $noise[$i]=[byte]($rng-band 255)
}
# DI; JP 9001H: stop at entry without changing the loaded image.
$noise[0]=0xF3;$noise[1]=0xC3;$noise[2]=0x01;$noise[3]=0x90
$binary=Join-Path $out 'capacity.bin'
function Build-Candidate([int]$Length) {
    [IO.File]::WriteAllBytes($binary,$noise[0..($Length-1)])
    & $builder -PayloadName 'CAPACITY' -EntryAddress 0x9000 -Segments @([pscustomobject]@{Path=$binary;MemoryControl=0;Destination=0x9000}) -OutputStem capacity -OutputDirectory $out -AssemblerPath $AssemblerPath
}
$lo=8000;$hi=12000
while($lo-lt $hi) {
    $mid=[int][Math]::Ceiling(($lo+$hi)/2)
    try { $null=Build-Candidate $mid; $lo=$mid }
    catch {
        if($_.Exception.Message-notmatch 'Tokenized BASIC reaches|overlaps the F800H common loader') { throw }
        $hi=$mid-1
    }
}
$rejected=$false
try { $null=Build-Candidate ($lo+1) }
catch {
    if($_.Exception.Message-notmatch 'Tokenized BASIC reaches|overlaps the F800H common loader') { throw }
    $rejected=$true
}
if(!$rejected){throw 'One-byte-over boundary accepted'}
$result=Build-Candidate $lo
if($result.TokenizedBasicBytes-le (0xC280-0x8021)){throw 'Fixture does not exceed the previous limit'}
$bad=Join-Path $out 'overlap.bin'
[IO.File]::WriteAllBytes($bad,[byte[]]@(0))
$guard=$false
try {
    $null=& $builder -PayloadName 'OVERLAP' -EntryAddress 0xF800 -Segments @([pscustomobject]@{Path=$bad;MemoryControl=0;Destination=0xF800}) -OutputStem overlap -OutputDirectory $out -AssemblerPath $AssemblerPath
} catch {
    if($_.Exception.Message-notmatch 'overwrites the active common loader') {throw}
    $guard=$true
}
if(!$guard){throw 'Loader overlap accepted'}
$report=@{LoaderOverlapRejected=$guard;Passed=$true;RawBytes=$lo;OneByteOverRejected=$rejected;Loader=$result}
$report|ConvertTo-Json -Depth 6|Set-Content (Join-Path $out 'capacity-report.json')
$report
