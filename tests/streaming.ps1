param(
    [Parameter(Mandatory)][string]$AssemblerPath,
    [ValidateSet('z80asm','sjasmplus')][string]$Assembler='z80asm',
    [Parameter(Mandatory)][string]$M88V,
    [Parameter(Mandatory)][string]$ConnectionFile
)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$out=Join-Path $root 'build/streaming-tests'
New-Item -ItemType Directory -Force $out | Out-Null
$builder=Join-Path $root 'tools/nbld/build_nbld_loader.ps1'
$ctl=Join-Path $M88V 'scripts/m88ctl.ps1'
$typer=Join-Path $M88V 'scripts/type_nbasic.ps1'
$options=@{ConnectionFile=$ConnectionFile}
function Read-Ram($Address,$Length) {
    $r=& $ctl memory @options -Address $Address -Length $Length
    return ,([Convert]::FromHexString($r.hex))
}
function Boot($Result,$Tape='',$ObserveProgress=$false) {
    if(!$Tape){$Tape=$Result.Tape}
    & $ctl reset @options | Out-Null
    & $ctl run @options -Frames 180 | Out-Null
    & $ctl tape @options -Tape $Tape | Out-Null
    & $typer @options -Line 'cload"NBLD80"' | Out-Null
    & $ctl run @options -Frames 5000 | Out-Null
    $basic=[IO.File]::ReadAllBytes($Result.BasicImage)
    if([Convert]::ToHexString((Read-Ram 0x8021 $basic.Length)) -ne [Convert]::ToHexString($basic)){throw 'Streaming CLOAD mismatch'}
    & $typer @options -Line 'run' | Out-Null
    if($ObserveProgress) {
        $seen=[Collections.Generic.HashSet[int]]::new()
        $total=[int][Math]::Ceiling(($Result.PackageBytes-32)/256.0)
        for($frame=0;$frame -lt 12000;$frame+=10) {
            & $ctl run @options -Frames 10 | Out-Null
            $line=[Text.Encoding]::ASCII.GetString((Read-Ram 0xF300 18))
            if($line -match '^LOAD BLOCK (\d{3})/(\d{3})$') {
                if([int]$Matches[2] -ne $total){throw "Wrong total: $line"}
                [void]$seen.Add([int]$Matches[1])
            }
            if((Read-Ram 0xF504 1)[0] -eq 3){break}
        }
        if(!@($seen | Where-Object {$_ -gt 0 -and $_ -lt $total}).Count){throw 'No intermediate progress observed'}
    }
    & $ctl run @options -Frames 12000 | Out-Null
}
function Build-Case($Name,$Segments,$Entry=0x9000,$Baud=1200,$Overwrite=$false,$EntryMode=0) {
    & $builder -Assembler $Assembler -AssemblerPath $AssemblerPath -PayloadName TEST `
        -EntryAddress $Entry -EntryMemoryControl $EntryMode -Segments $Segments `
        -Transport Tape -PayloadBaud $Baud -AllowLoaderOverwrite:$Overwrite `
        -OutputStem $Name -OutputDirectory $out
}
function Make-Segment($Name,$Bytes,$Destination,$Control=0) {
    $file=Join-Path $out "$Name.bin"
    [IO.File]::WriteAllBytes($file,[byte[]]$Bytes)
    return [pscustomobject]@{Path=$file;Destination=$Destination;MemoryControl=$Control}
}
function Check-Segment($Segment) {
    $expected=[IO.File]::ReadAllBytes($Segment.Path)
    if([Convert]::ToHexString((Read-Ram $Segment.Destination $expected.Length)) -ne [Convert]::ToHexString($expected)){throw "Streaming expansion mismatch: $($Segment.Path)"}
}
function Check-Pc($Expected) {
    $r=& $ctl status @options
    if($r.registers.pc -ne $Expected){throw "Expected PC $Expected, got $($r.registers.pc)"}
}
$reports=[Collections.Generic.List[object]]::new()
$small=Make-Segment small ([byte[]]@(0xF3,0xC3,1,0x90)) 0x9000
foreach($baud in @(600,1200)) {
    $result=Build-Case "small-$baud" @($small) -Baud $baud
    Boot $result
    Check-Segment $small
    Check-Pc 0x9001
    $reports.Add(@{case="small-$baud";passed=$true;seconds=$result.TapeSeconds})
}
& $ctl reset @options | Out-Null
& $ctl run @options -Frames 180 | Out-Null
& $ctl tape @options -Tape $result.MonitorTape | Out-Null
& $typer @options -Line 'mon' | Out-Null
& $typer @options -Line 'l' | Out-Null
& $ctl run @options -Frames 5000 | Out-Null
& $typer @options -Line 'g8800' | Out-Null
& $ctl run @options -Frames 12000 | Out-Null
Check-Segment $small
Check-Pc 0x9001
$reports.Add(@{case='monitor-shared-receiver';passed=$true})
# Incompressible bytes occupy 8000H..F4FFH, including the old entire staging area.
$random=[Random]::new(8801)
$bytes=[byte[]]::new(0x7500);$random.NextBytes($bytes)
$bytes[0]=0xF3;$bytes[1]=0xC3;$bytes[2]=1;$bytes[3]=0x80
$large=Make-Segment large $bytes 0x8000
$result=Build-Case large @($large) -Entry 0x8000
if($result.PackageBytes -lt 0x3000 -or $result.EncodedPayloadBytes -ne 0){throw 'Large-stream fixture did not exceed the legacy staging limit'}
Boot $result
Check-Segment $large
Check-Pc 0x8001
$reports.Add(@{case='large-no-staging';passed=$true;bytes=$bytes.Length;packageBytes=$result.PackageBytes})
# Last copies reclaim the loader and its stack, including a top-of-memory entry.
$tailBytes=[byte[]]::new(0xB00);$random.NextBytes($tailBytes)
$tailBytes[0]=0xF3;$tailBytes[1]=0xC3;$tailBytes[2]=1;$tailBytes[3]=0xF5
$tail=Make-Segment tail $tailBytes 0xF500
$result=Build-Case finalizer @($small,$tail) -Entry 0xF500 -Overwrite $true
Boot $result
Check-Segment $small
Check-Segment $tail
Check-Pc 0xF501
$reports.Add(@{case='loader-and-stack-final-copy';passed=$true;deferred=$result.DeferredBytes})
# Low-RAM entry copies its own 256-byte image upward for physical-RAM inspection.
$lowBytes=[byte[]]::new(256);$random.NextBytes($lowBytes)
$code=[byte[]]@(0xF3,0x31,0,0xA0,0x21,0,1,0x11,0,0x90,0x01,0,1,0xED,0xB0,0xC3,15,1)
[Array]::Copy($code,$lowBytes,$code.Length)
$low=Make-Segment low $lowBytes 0x100 2
$result=Build-Case low @($low) -Entry 0x100 -EntryMode 2
Boot $result
if([Convert]::ToHexString((Read-Ram 0x9000 256)) -ne [Convert]::ToHexString($lowBytes)){throw 'ROM-under RAM or entry mapping mismatch'}
Check-Pc 0x10F
$reports.Add(@{case='rom-under-ram-entry';passed=$true})

function Crc([byte[]]$Bytes) {
    $v=0xFFFF
    foreach($b in $Bytes){$v=$v -bxor ([int]$b -shl 8);for($i=0;$i -lt 8;$i++){$v=if($v -band 0x8000){(($v -shl 1)-bxor 0x1021)-band 65535}else{($v-shl 1)-band 65535}}}
    return [UInt16]$v
}
if((Crc ([Text.Encoding]::ASCII.GetBytes('123456789'))) -ne 0x29B1){throw 'CRC check vector failed'}
function Fix-Crc($Body,$Start,$Length) {
    $crc=Crc ([byte[]]$Body[$Start..($Start+$Length-1)])
    $Body[$Start+$Length]=[byte]($crc-band 255);$Body[$Start+$Length+1]=[byte]($crc-shr 8)
}
$base=Build-Case malformed @($small)
$original=[IO.File]::ReadAllBytes($base.Tape)
$offset=24;$dataTag=0
while($offset+4 -le $original.Length) {
    $id=[BitConverter]::ToUInt16($original,$offset);$len=[BitConverter]::ToUInt16($original,$offset+2)
    if($id -eq 0x101){$dataTag++;if($dataTag -eq 3){break}}
    $offset+=4+$len
}
if($dataTag -ne 3){throw 'Missing streamed data tag'}
$bodyOriginal=[IO.File]::ReadAllBytes((Join-Path $out 'malformed-tape-body.bin'))
$cases=@(
    @{name='header-crc';code=3;mutate={param($b) $b[41]=$b[41]-bxor 1}},
    @{name='descriptor-crc';code=3;mutate={param($b) $b[51]=$b[51]-bxor 1}},
    @{name='payload-crc';code=3;mutate={param($b) $b[$b.Length-1]=$b[$b.Length-1]-bxor 1}},
    @{name='address-wrap';code=5;mutate={param($b) $b[47]=255;$b[48]=255;Fix-Crc $b 43 8}},
    @{name='loader-overlap';code=5;mutate={param($b) $b[45]=0;$b[46]=0xF5;Fix-Crc $b 43 8}},
    @{name='zero-length';code=5;mutate={param($b) $b[47]=0;$b[48]=0;Fix-Crc $b 43 8}},
    @{name='codec';code=4;mutate={param($b) $b[44]=9;Fix-Crc $b 43 8}},
    @{name='bank';code=5;mutate={param($b) $b[43]=1;Fix-Crc $b 43 8}},
    @{name='entry-bank';code=5;mutate={param($b) $b[40]=1;Fix-Crc $b 8 33}},
    @{name='back-reference';code=6;mutate={param($b) $b[53]=0;$b[54]=1;$b[55]=0}},
    @{name='package-length';code=4;mutate={param($b) $b[14]=31;$b[15]=0;Fix-Crc $b 8 33}},
    @{name='zero-segments';code=4;mutate={param($b) $b[18]=0;Fix-Crc $b 8 33}},
    @{name='truncated';code=1;mutate={param($b)}}
)
foreach($case in $cases) {
    $body=[byte[]]$bodyOriginal.Clone()
    & $case.mutate $body
    if($case.name -eq 'truncated'){$body=[byte[]]$body[0..53]}
    $tape=[Collections.Generic.List[byte]]::new()
    $tape.AddRange([byte[]]$original[0..($offset-1)])
    $tag=[byte[]]$original[$offset..($offset+15)]
    [BitConverter]::GetBytes([UInt16](12+$body.Length)).CopyTo($tag,2)
    [BitConverter]::GetBytes([UInt32]($body.Length*44)).CopyTo($tag,8)
    [BitConverter]::GetBytes([UInt16]$body.Length).CopyTo($tag,12)
    $tape.AddRange($tag);$tape.AddRange($body);$tape.AddRange([byte[]]@(0,0,0,0))
    $file=Join-Path $out "$($case.name).t88"
    [IO.File]::WriteAllBytes($file,$tape.ToArray())
    Boot $base $file
    $state=Read-Ram 0xF503 2
    if($state[0] -ne $case.code -or $state[1] -ne 255){throw "Corrupt case $($case.name): got error/state $state"}
    $reports.Add(@{case=$case.name;passed=$true;error=$state[0]})
}
# Progress counts validated package bytes (descriptors + compressed payload).
# A final partial block must reach the displayed total, and UI writes must
# cease before a destination overlaps F300..F311, including either edge.
foreach($destination in @(0x9200,0xF2FF,0xF300,0xF311,0xF312)) {
    [byte[]]$bytes=New-Object byte[] $(if($destination -eq 0x9200){1024}else{64})
    $random=[Random]::new(8001)
    $random.NextBytes($bytes)
    $segment=Make-Segment ("progress-{0:X4}" -f $destination) $bytes $destination
    $result=Build-Case ("progress-{0:X4}" -f $destination) @($small,$segment)
    Boot $result -ObserveProgress:($destination -eq 0x9200)
    Check-Segment $small
    Check-Segment $segment
    Check-Pc 0x9001
    if($destination -in @(0x9200,0xF312)) {
        $total=[int][Math]::Ceiling(($result.PackageBytes-32)/256.0)
        $expected='LOAD BLOCK {0:000}/{0:000}' -f $total
        $actual=[Text.Encoding]::ASCII.GetString((Read-Ram 0xF300 18))
        if($actual -ne $expected){throw "Progress mismatch: $actual / $expected"}
    }
    $reports.Add(@{case=("progress-{0:X4}" -f $destination);passed=$true})
}

$reports | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $out 'report.json')
$reports | ForEach-Object { [pscustomobject]$_ }
