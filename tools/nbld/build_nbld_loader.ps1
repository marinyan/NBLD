[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[ -!#-~]{1,15}$')]
    [string]$PayloadName,
    [Parameter(Mandatory)]
    [UInt16]$EntryAddress,
    [Parameter(Mandatory)]
    [object[]]$Segments,
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$OutputStem,
    [Parameter(Mandatory)]
    [string]$OutputDirectory,
    [string]$AssemblerPath = "D:\data\PC-8001mkII\z80-development-codex-kit-2026-07-30\toolchain\z80asm\z80asm.exe"
)

$ErrorActionPreference = "Stop"
$formatVersion = 3
$headerSize = 32
$codecLzss12 = 1
$basicName = "NBLD80"
$stagingAddress = 0xC500
$relocatorStaging = 0xC8C0
$copyBootstrapAddress = 0xF000
$relocatorAddress = 0xF100
$loaderStackTop = 0xF400
$scriptDirectory = $PSScriptRoot
$stage2Source = Join-Path $scriptDirectory "nbld_stage2.asm"
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
$AssemblerPath = [System.IO.Path]::GetFullPath($AssemblerPath)

if (-not (Test-Path -LiteralPath $AssemblerPath -PathType Leaf)) {
    throw "z80asm.exe not found: $AssemblerPath"
}
if (-not (Test-Path -LiteralPath $stage2Source -PathType Leaf)) {
    throw "Common NBLD stage-2 source not found: $stage2Source"
}
if ($Segments.Count -lt 1 -or $Segments.Count -gt 255) {
    throw "NBLD requires 1..255 segments."
}
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$PayloadName = $PayloadName.ToUpperInvariant()

function Add-UInt16LE([System.Collections.Generic.List[byte]]$Buffer,[UInt16]$Value) {
    [void]$Buffer.Add([byte]($Value -band 0xFF))
    [void]$Buffer.Add([byte](($Value -shr 8) -band 0xFF))
}

function Add-UInt32LE([System.Collections.Generic.List[byte]]$Buffer,[UInt32]$Value) {
    for ($shift=0;$shift-lt 32;$shift+=8) {
        [void]$Buffer.Add([byte](($Value-shr $shift)-band 0xFF))
    }
}

function Add-TimedTag(
    [System.Collections.Generic.List[byte]]$Buffer,[UInt16]$Id,
    [UInt32]$StartTick,[UInt32]$DurationTick
) {
    Add-UInt16LE $Buffer $Id
    Add-UInt16LE $Buffer 8
    Add-UInt32LE $Buffer $StartTick
    Add-UInt32LE $Buffer $DurationTick
}

function Add-T88DataTag(
    [System.Collections.Generic.List[byte]]$Buffer,[byte[]]$Data,
    [ref]$CurrentTick,[UInt16]$TicksPerByte=88,[UInt16]$DataType=0x00CC
) {
    $offset=0
    while ($offset-lt $Data.Length) {
        $count=[Math]::Min(32768,$Data.Length-$offset)
        $duration=[UInt32]($count*$TicksPerByte)
        Add-UInt16LE $Buffer 0x0101
        Add-UInt16LE $Buffer ([UInt16](12+$count))
        Add-UInt32LE $Buffer ([UInt32]$CurrentTick.Value)
        Add-UInt32LE $Buffer $duration
        Add-UInt16LE $Buffer ([UInt16]$count)
        Add-UInt16LE $Buffer $DataType
        [byte[]]$chunk=$Data[$offset..($offset+$count-1)]
        $Buffer.AddRange($chunk)
        $offset+=$count
        $CurrentTick.Value=[UInt32]($CurrentTick.Value+$duration)
    }
}

function Add-NBasicLine(
    [System.Collections.Generic.List[object]]$Lines,[UInt16]$Number,[byte[]]$Body
) {
    if ($Body.Length-gt 249) { throw "N-BASIC line $Number is too long." }
    [void]$Lines.Add([pscustomobject]@{Number=$Number;Body=$Body})
}

function New-NBasicImage([System.Collections.Generic.List[object]]$Lines) {
    $image=[System.Collections.Generic.List[byte]]::new()
    $address=0x8021
    foreach ($line in $Lines) {
        $nextAddress=$address+2+2+$line.Body.Length+1
        if ($nextAddress-gt 0xFFFF) { throw "N-BASIC image exceeds address space." }
        Add-UInt16LE $image ([UInt16]$nextAddress)
        Add-UInt16LE $image ([UInt16]$line.Number)
        $image.AddRange([byte[]]$line.Body)
        [void]$image.Add(0)
        $address=$nextAddress
    }
    Add-UInt16LE $image 0
    return $image.ToArray()
}

function Assert-ByteArraysEqual([byte[]]$Expected,[byte[]]$Actual,[string]$Label) {
    if ($Expected.Length-ne $Actual.Length) { throw "$Label round-trip length mismatch." }
    for ($index=0;$index-lt $Expected.Length;$index++) {
        if ($Expected[$index]-ne $Actual[$index]) { throw "$Label round-trip mismatch at byte $index." }
    }
}

# Eight items share one flag byte (bit=1 literal, bit=0 match). A match uses
# a 12-bit backward distance and a four-bit length (3..18).
function Compress-Lzss([byte[]]$Source) {
    # Match candidates depend only on the source, not on token boundaries.
    # Search the full 12-bit window; stop as soon as the longest match is found.
    $matchLengths=[byte[]]::new($Source.Length)
    $matchDistances=[UInt16[]]::new($Source.Length)
    $history=@{}
    for ($offset=0;$offset+2-lt $Source.Length;$offset++) {
        $key=([int]$Source[$offset]-shl 16)-bor([int]$Source[$offset+1]-shl 8)-bor[int]$Source[$offset+2]
        $positions=$history[$key]
        if ($null-ne $positions) {
            $maximum=[Math]::Min(18,$Source.Length-$offset)
            for ($candidateIndex=$positions.Count-1;$candidateIndex-ge 0;$candidateIndex--) {
                $candidate=[int]$positions[$candidateIndex]
                $distance=$offset-$candidate
                if ($distance-gt 4095) { break }
                $length=3
                while ($length-lt $maximum -and $Source[$candidate+$length]-eq $Source[$offset+$length]) { $length++ }
                if ($length-gt $matchLengths[$offset]) {
                    $matchLengths[$offset]=[byte]$length
                    $matchDistances[$offset]=[UInt16]$distance
                    if ($length-eq $maximum) { break }
                }
            }
        } else {
            $positions=[System.Collections.Generic.List[int]]::new()
            $history[$key]=$positions
        }
        [void]$positions.Add($offset)
    }

    # Find the smallest stream within that candidate set, including flag bytes.
    # State = (source offset, token index modulo 8). Shorter matches are useful
    # when they expose a better match next; greedy longest-match misses these.
    $costs=[int[]]::new(($Source.Length+1)*8)
    $choices=[byte[]]::new($Source.Length*8)
    for ($offset=$Source.Length-1;$offset-ge 0;$offset--) {
        for ($phase=0;$phase-lt 8;$phase++) {
            $nextPhase=($phase+1)-band 7
            $bestCost=1+$costs[($offset+1)*8+$nextPhase]
            $consumed=1
            for ($length=3;$length-le $matchLengths[$offset];$length++) {
                $cost=2+$costs[($offset+$length)*8+$nextPhase]
                if ($cost-le $bestCost) {
                    $bestCost=$cost
                    $consumed=$length
                }
            }
            if ($phase-eq 0) { $bestCost++ }
            $state=$offset*8+$phase
            $costs[$state]=$bestCost
            $choices[$state]=[byte]$consumed
        }
    }

    $packed=[System.Collections.Generic.List[byte]]::new($costs[0])
    $offset=0
    while ($offset-lt $Source.Length) {
        $flagIndex=$packed.Count
        [void]$packed.Add(0)
        $flags=0
        for ($bit=0;$bit-lt 8 -and $offset-lt $Source.Length;$bit++) {
            $consumed=[int]$choices[$offset*8+$bit]
            if ($consumed-ge 3) {
                $distance=[int]$matchDistances[$offset]
                [void]$packed.Add([byte]($distance-band 0xFF))
                [void]$packed.Add([byte]((($distance-shr 8)-shl 4)-bor($consumed-3)))
            } else {
                $flags=$flags-bor(1-shl $bit)
                [void]$packed.Add($Source[$offset])
            }
            $offset+=$consumed
        }
        $packed[$flagIndex]=[byte]$flags
    }
    if ($packed.Count-ne $costs[0]) { throw "LZSS optimal-parse size mismatch." }
    return $packed.ToArray()
}

function Expand-Lzss([byte[]]$Packed,[int]$ExpectedLength) {
    $output=[System.Collections.Generic.List[byte]]::new($ExpectedLength)
    $source=0
    while ($output.Count-lt $ExpectedLength) {
        if ($source-ge $Packed.Length) { throw "Truncated LZSS flag stream." }
        $flags=$Packed[$source++]
        for ($bit=0;$bit-lt 8 -and $output.Count-lt $ExpectedLength;$bit++) {
            if (($flags-band(1-shl $bit))-ne 0) {
                if ($source-ge $Packed.Length) { throw "Truncated LZSS literal." }
                [void]$output.Add($Packed[$source++])
            } else {
                if ($source+1-ge $Packed.Length) { throw "Truncated LZSS match." }
                $low=$Packed[$source++]
                $packedMatch=$Packed[$source++]
                $distance=$low-bor(($packedMatch-band 0xF0)-shl 4)
                $length=($packedMatch-band 0x0F)+3
                if ($distance-lt 1 -or $distance-gt $output.Count) { throw "Invalid LZSS distance." }
                for ($index=0;$index-lt $length -and $output.Count-lt $ExpectedLength;$index++) {
                    [void]$output.Add($output[$output.Count-$distance])
                }
            }
        }
    }
    if ($source-ne $Packed.Length) { throw "LZSS stream has unused trailing bytes." }
    return $output.ToArray()
}

function Assert-LzssForwardInPlaceSafe(
    [byte[]]$Packed,[int]$ExpectedLength,[int]$SourceAddress,[int]$DestinationAddress
) {
    $source=0
    $output=0
    while ($output-lt $ExpectedLength) {
        $flags=$Packed[$source++]
        for ($bit=0;$bit-lt 8 -and $output-lt $ExpectedLength;$bit++) {
            if (($flags-band(1-shl $bit))-ne 0) {
                $source++
                $length=1
            } else {
                $source++
                $packedMatch=$Packed[$source++]
                $length=($packedMatch-band 0x0F)+3
            }
            for ($index=0;$index-lt $length -and $output-lt $ExpectedLength;$index++) {
                $destination=$DestinationAddress+$output
                $nextUnreadSource=$SourceAddress+$source
                if ($destination-ge $nextUnreadSource) {
                    throw ("Forward LZSS would overwrite unread NBLD data at {0:X4}H." -f $destination)
                }
                $output++
            }
        }
    }
    if ($source-ne $Packed.Length) { throw "LZSS safety scan did not consume the whole stream." }
}

function Get-RequiredProperty([object]$Value,[string]$Name,[int]$Index) {
    $property=$Value.PSObject.Properties[$Name]
    if ($null-eq $property) { throw "Segment $Index is missing $Name." }
    return $property.Value
}

$preparedSegments=[System.Collections.Generic.List[object]]::new()
$segmentIndex=0
foreach ($segment in $Segments) {
    $path=[System.IO.Path]::GetFullPath([string](Get-RequiredProperty $segment "Path" $segmentIndex))
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Segment binary not found: $path" }
    $memoryControl=[int](Get-RequiredProperty $segment "MemoryControl" $segmentIndex)
    $destination=[int](Get-RequiredProperty $segment "Destination" $segmentIndex)
    if ($memoryControl-lt 0 -or $memoryControl-gt 255) { throw "Segment $segmentIndex MemoryControl must fit one byte." }
    if ($destination-lt 0 -or $destination-gt 0xFFFF) { throw "Segment $segmentIndex Destination must fit 16 bits." }
    [byte[]]$raw=[System.IO.File]::ReadAllBytes($path)
    if ($raw.Length-lt 1 -or $raw.Length-gt 0xFFFF) { throw "Segment $segmentIndex must contain 1..65535 bytes." }
    if (($destination+$raw.Length)-gt 0x10000) { throw "Segment $segmentIndex exceeds FFFFH." }
    if ($destination-lt 0x8000 -and ($memoryControl-band 0x02)-eq 0) {
        throw "Segment $segmentIndex targets ROM space without selecting ROM-under RAM."
    }
    [byte[]]$packed=Compress-Lzss $raw
    Assert-ByteArraysEqual $raw (Expand-Lzss $packed $raw.Length) "Segment $segmentIndex"
    [void]$preparedSegments.Add([pscustomobject]@{
        Path=$path;MemoryControl=$memoryControl;Destination=$destination;Raw=$raw;Packed=$packed
    })
    $segmentIndex++
}

$package=[System.Collections.Generic.List[byte]]::new()
$package.AddRange([System.Text.Encoding]::ASCII.GetBytes("NBLD"))
[void]$package.Add([byte]$formatVersion)
[void]$package.Add([byte]$headerSize)
Add-UInt16LE $package 0
Add-UInt16LE $package $EntryAddress
[void]$package.Add([byte]$preparedSegments.Count)
[void]$package.Add(0)
[byte[]]$nameBytes=[System.Text.Encoding]::ASCII.GetBytes($PayloadName)
$package.AddRange($nameBytes)
while ($package.Count-lt 28) { [void]$package.Add(0) }
while ($package.Count-lt $headerSize) { [void]$package.Add(0) }

foreach ($segment in $preparedSegments) {
    $packedAddress=$stagingAddress+$package.Count+8
    if ($segment.Destination-ge 0x8000) {
        Assert-LzssForwardInPlaceSafe $segment.Packed $segment.Raw.Length $packedAddress $segment.Destination
    }
    [void]$package.Add([byte]$segment.MemoryControl)
    [void]$package.Add([byte]$codecLzss12)
    Add-UInt16LE $package ([UInt16]$segment.Destination)
    Add-UInt16LE $package ([UInt16]$segment.Raw.Length)
    Add-UInt16LE $package ([UInt16]$segment.Packed.Length)
    $package.AddRange([byte[]]$segment.Packed)
}

if ($package.Count-gt 0xFFFF) { throw "NBLD package exceeds 65535 bytes." }
$package[6]=[byte]($package.Count-band 0xFF)
$package[7]=[byte](($package.Count-shr 8)-band 0xFF)
[byte[]]$packageBytes=$package.ToArray()
if (($stagingAddress+$packageBytes.Length)-gt $relocatorAddress) {
    throw ("NBLD package reaches {0:X4}H and overlaps the F100H common loader." -f ($stagingAddress+$packageBytes.Length-1))
}

$packagePath=Join-Path $OutputDirectory "$OutputStem-nbld.bin"
[System.IO.File]::WriteAllBytes($packagePath,$packageBytes)
$encodedText=[Convert]::ToBase64String($packageBytes)
[byte[]]$encodedPackage=[System.Text.Encoding]::ASCII.GetBytes($encodedText)

$relocatorBinaryPath=Join-Path $OutputDirectory "$OutputStem-basic-relocator.bin"
$relocatorListingPath=Join-Path $OutputDirectory "$OutputStem-basic-relocator.lst"
$relocatorSymbolsPath=Join-Path $OutputDirectory "$OutputStem-basic-relocator.sym"
& $AssemblerPath $stage2Source -o $relocatorBinaryPath -l $relocatorListingPath --sym $relocatorSymbolsPath --cpu z80 | Out-Host
if ($LASTEXITCODE-ne 0) { throw "Common NBLD stage-2 assembly failed." }
[byte[]]$relocatorBinary=[System.IO.File]::ReadAllBytes($relocatorBinaryPath)
if (($relocatorAddress+$relocatorBinary.Length)-gt $loaderStackTop) {
    throw "Common NBLD stage-2 overlaps its F400H stack reserve."
}

[byte[]]$copyBootstrap=@(
    0xF3,
    0x31,0x00,0xF4,
    0x21,($relocatorStaging-band 0xFF),(($relocatorStaging-shr 8)-band 0xFF),
    0x11,($relocatorAddress-band 0xFF),(($relocatorAddress-shr 8)-band 0xFF),
    0x01,($relocatorBinary.Length-band 0xFF),(($relocatorBinary.Length-shr 8)-band 0xFF),
    0xED,0xB0,
    0xC3,($relocatorAddress-band 0xFF),(($relocatorAddress-shr 8)-band 0xFF)
)

$relocatorChunkBytes=48
$relocatorChunkCount=[int][Math]::Ceiling($relocatorBinary.Length/[double]$relocatorChunkBytes)
$tokenLines=[System.Collections.Generic.List[object]]::new()
Add-NBasicLine $tokenLines 20 ([byte[]]@(
    0x91,0x20,0x22,0x4C,0x4F,0x41,0x44,0x49,0x4E,0x47,0x20,0x30,0x25,0x22
))
Add-NBasicLine $tokenLines 21 ([byte[]]@(0x98,0x20,0x0C,0x00,0xC8,0x2C,0x11))
Add-NBasicLine $tokenLines 22 ([byte[]]@(0x98,0x20,0x0C,0x01,0xC8,0x2C,0x0C,0x20,0x00))
[byte[]]$line30Body=@(
    0x98,0x20,0x0C,0x01,0xC8,0x2C,0x0C,0x30,0x00,0x3A,
    0x49,0xF1,0x0C,($relocatorStaging-band 0xFF),(($relocatorStaging-shr 8)-band 0xFF),0x3A,
    0x82,0x20,0x4B,0xF1,0x12,0x20,0xD7,0x20,0x0F,$relocatorChunkCount
)
Add-NBasicLine $tokenLines 30 $line30Body
Add-NBasicLine $tokenLines 31 ([byte[]]@(
    0x98,0x20,0x0C,0x01,0xC8,0x2C,0x0C,0x31,0x00,0x3A,
    0x87,0x20,0x44,0x24,0x3A,0x82,0x20,0x4A,0xF1,0x12,0x20,0xD7,0x20,
    0xFF,0x92,0x28,0x44,0x24,0x29,0x20,0xDA,0x20,0x13
))
Add-NBasicLine $tokenLines 32 ([byte[]]@(
    0x98,0x20,0x0C,0x01,0xC8,0x2C,0x0C,0x32,0x00,0x3A,
    0x98,0x20,0x49,0x2C,0xFF,0x94,0x28,0x22,0x26,0x48,0x22,0xF3,
    0xFF,0x83,0x28,0x44,0x24,0x2C,0x4A,0x2C,0x13,0x29,0x29,0x3A,
    0x49,0xF1,0x49,0xF3,0x12,0x3A,0x83
))
Add-NBasicLine $tokenLines 33 ([byte[]]@(0x83))

# All 18 bootstrap POKEs fit in one tokenized line. Omit optional spaces after
# POKE as well; this saves 34 bytes without changing execution or work memory.
$bootstrapChunkBytes=18
$bootstrapLine=40
for ($bootstrapOffset=0;$bootstrapOffset-lt $copyBootstrap.Length;$bootstrapOffset+=$bootstrapChunkBytes) {
    $bootstrapBody=[System.Collections.Generic.List[byte]]::new()
    $bootstrapLast=[Math]::Min($copyBootstrap.Length-1,$bootstrapOffset+$bootstrapChunkBytes-1)
    for ($bootstrapIndex=$bootstrapOffset;$bootstrapIndex-le $bootstrapLast;$bootstrapIndex++) {
        if ($bootstrapBody.Count-ne 0) { [void]$bootstrapBody.Add(0x3A) }
        $bootstrapDestination=$copyBootstrapAddress+$bootstrapIndex
        $bootstrapValue=$copyBootstrap[$bootstrapIndex]
        $bootstrapBody.AddRange([byte[]]@(
            0x98,
            0x0C,($bootstrapDestination-band 0xFF),(($bootstrapDestination-shr 8)-band 0xFF),
            0x2C,0x0C,$bootstrapValue,0x00
        ))
    }
    Add-NBasicLine $tokenLines ([UInt16]$bootstrapLine) $bootstrapBody.ToArray()
    $bootstrapLine++
}
Add-NBasicLine $tokenLines 50 ([byte[]]@(
    0x97,0x20,0xDB,0xF1,
    0x0C,($copyBootstrapAddress-band 0xFF),(($copyBootstrapAddress-shr 8)-band 0xFF),
    0x3A,0x41,0xF1,0xDB,0x28,0x11,0x29
))

$readableLines=[System.Collections.Generic.List[string]]::new()
[void]$readableLines.Add('20 PRINT "LOADING 0%"')
[void]$readableLines.Add('21 POKE &HC800,0')
[void]$readableLines.Add('22 POKE &HC801,&H20')
[void]$readableLines.Add(('30 POKE &HC801,&H30:I=&H{0:X4}:FOR K=1 TO {1}' -f $relocatorStaging,$relocatorChunkCount))
[void]$readableLines.Add('31 POKE &HC801,&H31:READ D$:FOR J=1 TO LEN(D$) STEP 2')
[void]$readableLines.Add('32 POKE &HC801,&H32:POKE I,VAL("&H"+MID$(D$,J,2)):I=I+1:NEXT')
[void]$readableLines.Add('33 NEXT')
for ($bootstrapOffset=0;$bootstrapOffset-lt $copyBootstrap.Length;$bootstrapOffset+=$bootstrapChunkBytes) {
    $bootstrapLast=[Math]::Min($copyBootstrap.Length-1,$bootstrapOffset+$bootstrapChunkBytes-1)
    $statements=[System.Collections.Generic.List[string]]::new()
    for ($bootstrapIndex=$bootstrapOffset;$bootstrapIndex-le $bootstrapLast;$bootstrapIndex++) {
        [void]$statements.Add(('POKE &H{0:X4},&H{1:X2}' -f ($copyBootstrapAddress+$bootstrapIndex),$copyBootstrap[$bootstrapIndex]))
    }
    [void]$readableLines.Add(('{0} {1}' -f (40+[int]($bootstrapOffset/$bootstrapChunkBytes)),($statements-join ':')))
}
[void]$readableLines.Add(('50 DEF USR=&H{0:X4}:A=USR(0)' -f $copyBootstrapAddress))

$lineNumber=100
for ($offset=0;$offset-lt $relocatorBinary.Length;$offset+=$relocatorChunkBytes) {
    $last=[Math]::Min($relocatorBinary.Length-1,$offset+$relocatorChunkBytes-1)
    $hex=-join($relocatorBinary[$offset..$last]|ForEach-Object{$_.ToString("X2")})
    $dataBody=[System.Collections.Generic.List[byte]]::new()
    [void]$dataBody.Add(0x84)
    [void]$dataBody.Add(0x20)
    $dataBody.AddRange([System.Text.Encoding]::ASCII.GetBytes($hex))
    Add-NBasicLine $tokenLines ([UInt16]$lineNumber) $dataBody.ToArray()
    [void]$readableLines.Add(("{0} DATA {1}" -f $lineNumber,$hex))
    $lineNumber+=10
}

$payloadLineNumber=1000
$encodedChunkBytes=240
for ($offset=0;$offset-lt $encodedPackage.Length;$offset+=$encodedChunkBytes) {
    $count=[Math]::Min($encodedChunkBytes,$encodedPackage.Length-$offset)
    $body=[System.Collections.Generic.List[byte]]::new()
    [void]$body.Add(0x8E)
    [void]$body.Add([byte][char]'D')
    [byte[]]$chunk=$encodedPackage[$offset..($offset+$count-1)]
    $body.AddRange($chunk)
    Add-NBasicLine $tokenLines ([UInt16]$payloadLineNumber) $body.ToArray()
    $payloadLineNumber++
}
Add-NBasicLine $tokenLines ([UInt16]$payloadLineNumber) ([byte[]]@(0x8E,[byte][char]'E'))
[void]$readableLines.Add(("1000 REM Base64 NBLD v3 package: {0} bytes ({1} encoded bytes)" -f $packageBytes.Length,$encodedPackage.Length))

[byte[]]$basicImage=New-NBasicImage $tokenLines
$basicEnd=0x8021+$basicImage.Length
if ($basicEnd-gt ($stagingAddress-0x280)) {
    throw ("Tokenized BASIC reaches {0:X4}H and leaves too little work space below C500H." -f ($basicEnd-1))
}

$basicSourcePath=Join-Path $OutputDirectory "$OutputStem-loader.bas"
$basicImagePath=Join-Path $OutputDirectory "$OutputStem-loader.nbas"
[System.IO.File]::WriteAllText($basicSourcePath,(($readableLines-join "`r`n")+"`r`n"),[System.Text.Encoding]::ASCII)
[System.IO.File]::WriteAllBytes($basicImagePath,$basicImage)

$basicHeader=[System.Collections.Generic.List[byte]]::new()
$basicHeader.AddRange([byte[]](0xD3)*10)
$basicHeader.AddRange([System.Text.Encoding]::ASCII.GetBytes($basicName))
$basicBody=[System.Collections.Generic.List[byte]]::new()
$basicBody.AddRange($basicImage)
$basicBody.AddRange([byte[]](0x00)*10)
$cmt=[System.Collections.Generic.List[byte]]::new()
$cmt.AddRange($basicHeader.ToArray())
$cmt.AddRange($basicBody.ToArray())
$cmtPath=Join-Path $OutputDirectory "$OutputStem-basic.cmt"
[System.IO.File]::WriteAllBytes($cmtPath,$cmt.ToArray())

$ticksPerByte=[UInt16]88
$t88=[System.Collections.Generic.List[byte]]::new()
$t88.AddRange([System.Text.Encoding]::ASCII.GetBytes("PC-8801 Tape Image(T88)`0"))
Add-UInt16LE $t88 0x0001
Add-UInt16LE $t88 0x0002
Add-UInt16LE $t88 0x0100
$currentTick=[UInt32]0
Add-TimedTag $t88 0x0102 $currentTick 12000
$currentTick+=12000
Add-TimedTag $t88 0x0103 $currentTick 2400
$currentTick+=2400
Add-T88DataTag $t88 $basicHeader.ToArray() ([ref]$currentTick) $ticksPerByte 0x00CC
Add-TimedTag $t88 0x0103 $currentTick 960
$currentTick+=960
Add-T88DataTag $t88 $basicBody.ToArray() ([ref]$currentTick) $ticksPerByte 0x00CC
Add-TimedTag $t88 0x0103 $currentTick 6240
$currentTick+=6240
Add-TimedTag $t88 0x0102 $currentTick 12000
$currentTick+=12000
Add-TimedTag $t88 0x0100 $currentTick 4800
Add-UInt16LE $t88 0
Add-UInt16LE $t88 0
$t88Path=Join-Path $OutputDirectory "$OutputStem-basic.t88"
[System.IO.File]::WriteAllBytes($t88Path,$t88.ToArray())

$residentBytes=($preparedSegments|ForEach-Object {$_.Raw.Length}|Measure-Object -Sum).Sum
$packedResidentBytes=($preparedSegments|ForEach-Object {$_.Packed.Length}|Measure-Object -Sum).Sum

[pscustomobject]@{
    Format="NBLD v3"
    BasicName=$basicName
    PayloadName=$PayloadName
    EntryAddress=("{0:X4}H" -f $EntryAddress)
    SegmentCount=$preparedSegments.Count
    ResidentBytes=$residentBytes
    PackedResidentBytes=$packedResidentBytes
    Package=$packagePath
    PackageBytes=$packageBytes.Length
    EncodedPayloadBytes=$encodedPackage.Length
    TokenizedBasicBytes=$basicImage.Length
    TokenizedBasicRange=("8021H-{0:X4}H" -f ($basicEnd-1))
    StagingRange=("C500H-{0:X4}H" -f ($stagingAddress+$packageBytes.Length-1))
    Relocator=$relocatorBinaryPath
    RelocatorBytes=$relocatorBinary.Length
    BasicSource=$basicSourcePath
    BasicImage=$basicImagePath
    Cmt=$cmtPath
    Tape=$t88Path
    CmtBytes=$cmt.Count
    TapeBytes=$t88.Count
}
