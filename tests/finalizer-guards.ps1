param([string]$Builder,[string]$AssemblerPath)
$ErrorActionPreference='Stop'
$out=Join-Path (Split-Path $PSScriptRoot -Parent) 'build/finalizer-guards';New-Item -ItemType Directory -Force $out|Out-Null
$tail=Join-Path $out 'tail.bin';[IO.File]::WriteAllBytes($tail,[byte[]]@(0))
$full=Join-Path $out 'occupied.bin';[IO.File]::WriteAllBytes($full,(New-Object byte[] 18432))
function Must-Reject($Segments,$Enabled,$Pattern){
 $failed=$false
 try{$null=& $Builder -AllowLoaderOverwrite:$Enabled -PayloadName REJECT -EntryAddress 0x9000 -Segments $Segments -OutputStem reject -OutputDirectory $out -AssemblerPath $AssemblerPath}
 catch{if($_.Exception.Message-notmatch $Pattern){throw};$failed=$true}
 if(!$failed){throw "Expected rejection: $Pattern"}
}
$t=[pscustomobject]@{Path=$tail;MemoryControl=0;Destination=0xF800}
Must-Reject @($t) $false 'overwrites the active common loader'
Must-Reject @([pscustomobject]@{Path=$tail;MemoryControl=1;Destination=0xF800}) $true 'ordinary upper RAM'
Must-Reject @([pscustomobject]@{Path=$full;MemoryControl=0;Destination=0x8000},$t) $true 'No unused upper-RAM gap'
Must-Reject @($t,$t) $true 'disjoint destination ranges'
@{Passed=$true;Rejections=4}
