param(
    [string]$Builder,
    [string]$ConnectionFile,
    [string]$AssemblerPath,
    [string]$M88V=(Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'M88V')
)
$ErrorActionPreference='Stop'
$out=Join-Path (Split-Path $PSScriptRoot -Parent) 'build/finalizer'
New-Item -ItemType Directory -Force $out|Out-Null
$ctl=Join-Path $M88V 'scripts/m88ctl.ps1'
$typer=Join-Path $M88V 'scripts/type_nbasic.ps1'
foreach($script in @($ctl,$typer)) {
    if(!(Test-Path -LiteralPath $script -PathType Leaf)){throw "M88V helper not found: $script. Specify -M88V with the emulator directory."}
}
$main=Join-Path $out 'main.bin';[IO.File]::WriteAllBytes($main,[byte[]]@(0xF3,0xC3,1,0x90))
$cases=@(@{Name='whole-top';Ranges=,@(0xF800,2048);Entry=0xF800},@{Name='stack-byte';Ranges=,@(0xFAFF,1);Entry=0x9000},@{Name='cross-start';Ranges=,@(0xF7F0,1040);Entry=0x9000},@{Name='two-tails';Ranges=@(@(0xF800,128),@(0xFA00,128));Entry=0xFA00})
$reports=@()
foreach($case in $cases) {
    $segments=@([pscustomobject]@{Path=$main;MemoryControl=0;Destination=0x9000})
    $index=0
    foreach($range in $case.Ranges) {
        [byte[]]$bytes=New-Object byte[] $range[1]
        for($i=0;$i-lt $bytes.Length;$i++){$bytes[$i]=[byte](($i*37+13)-band 255)}
        if($range[0]-eq $case.Entry){$bytes[0]=0xF3;$bytes[1]=0xC3;$bytes[2]=[byte](($case.Entry+1)-band 255);$bytes[3]=[byte]($case.Entry-shr 8)}
        $file=Join-Path $out "$($case.Name)-$index.bin";[IO.File]::WriteAllBytes($file,$bytes)
        $segments+=[pscustomobject]@{Path=$file;MemoryControl=0;Destination=$range[0]};$index++
    }
    $result=& $Builder -AllowLoaderOverwrite -PayloadName FINALIZE -EntryAddress $case.Entry -Segments $segments -OutputStem $case.Name -OutputDirectory $out -AssemblerPath $AssemblerPath
    & $ctl reset -ConnectionFile $ConnectionFile|Out-Null
    & $ctl run -ConnectionFile $ConnectionFile -Frames 180|Out-Null
    & $ctl tape -ConnectionFile $ConnectionFile -Tape $result.Tape|Out-Null
    & $typer -ConnectionFile $ConnectionFile -Line 'cload"NBLD80"'|Out-Null
    & $ctl run -ConnectionFile $ConnectionFile -Frames 18000|Out-Null
    $basic=[IO.File]::ReadAllBytes($result.BasicImage)
    $read=& $ctl memory -ConnectionFile $ConnectionFile -Address 0x8021 -Length $basic.Length
    if($read.hex-ne [Convert]::ToHexString($basic)){throw 'Finalizer CLOAD mismatch'}
    & $typer -ConnectionFile $ConnectionFile -Line 'run'|Out-Null
    & $ctl run -ConnectionFile $ConnectionFile -Frames 2400|Out-Null
    foreach($segment in $segments) {
        $raw=[IO.File]::ReadAllBytes($segment.Path)
        $read=& $ctl memory -ConnectionFile $ConnectionFile -Address $segment.Destination -Length $raw.Length
        if($read.hex-ne [Convert]::ToHexString($raw)){throw "Final copy mismatch: $($case.Name)"}
    }
    $status=& $ctl status -ConnectionFile $ConnectionFile
    if($status.registers.pc-ne ($case.Entry+1)){throw 'Final entry not reached'}
    $reports+=@{Case=$case.Name;Passed=$true;DeferredBytes=$result.DeferredBytes;Scratch=$result.FinalizerAddress;FinalPc=$status.registers.pc}
}
$reports|ConvertTo-Json -Depth 5|Set-Content (Join-Path $out 'report.json')
$reports
