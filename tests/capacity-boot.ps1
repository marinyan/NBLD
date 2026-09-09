param(
    [Parameter(Mandatory)][string]$ConnectionFile,
    [string]$M88V=(Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'M88V')
)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$dir=Join-Path $root 'build/capacity'
$ctl=Join-Path $M88V 'scripts/m88ctl.ps1'
$typer=Join-Path $M88V 'scripts/type_nbasic.ps1'
foreach($script in @($ctl,$typer)) {
    if(!(Test-Path -LiteralPath $script -PathType Leaf)){throw "M88V helper not found: $script. Specify -M88V with the emulator directory."}
}
& $ctl reset -ConnectionFile $ConnectionFile | Out-Null
& $ctl run -ConnectionFile $ConnectionFile -Frames 180 | Out-Null
& $ctl tape -ConnectionFile $ConnectionFile -Tape (Join-Path $dir 'capacity-basic.t88') | Out-Null
& $typer -ConnectionFile $ConnectionFile -Line 'cload"NBLD80"' | Out-Null
& $ctl run -ConnectionFile $ConnectionFile -Frames 18000 | Out-Null
$basic=[IO.File]::ReadAllBytes((Join-Path $dir 'capacity-loader.nbas'))
$read=& $ctl memory -ConnectionFile $ConnectionFile -Address 0x8021 -Length $basic.Length
if($read.hex -ne [Convert]::ToHexString($basic)){throw 'Boundary CLOAD mismatch'}
& $typer -ConnectionFile $ConnectionFile -Line 'run' | Out-Null
& $ctl run -ConnectionFile $ConnectionFile -Frames 2400 | Out-Null
$raw=[IO.File]::ReadAllBytes((Join-Path $dir 'capacity.bin'))
$read=& $ctl memory -ConnectionFile $ConnectionFile -Address 0x9000 -Length $raw.Length
if($read.hex -ne [Convert]::ToHexString($raw)){throw 'Boundary expansion mismatch'}
$status=& $ctl status -ConnectionFile $ConnectionFile
if($status.registers.pc-ne 0x9001){throw 'Boundary payload entry not reached'}
$report=@{Passed=$true;BasicBytes=$basic.Length;RawBytes=$raw.Length;Method='CLOAD / RUN, full BASIC and expanded bytes';Performance='Not measured'}
$report|ConvertTo-Json|Set-Content (Join-Path $dir 'capacity-boot-report.json')
$report
