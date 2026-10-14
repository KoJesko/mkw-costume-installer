<#
Builds a patched revo_kart.brsar from a mod's Voices folder.

Only needed for the BASE costume's voice on packs that cannot do loose
per-file overrides, and for playing the character outside Retro Rewind. If your
pack supports a Patches folder, install.sh covers the base costume without this.

Voice files must be named the way the mod scene names them, with the file's
index inside revo_kart.brsar first:

    94 GRP_VO_RS_PC.brwsd   ->  replaces brsar file entry 94
    471 GRP_VO_RS_PC.brbnk  ->  replaces brsar file entry 471

Any Audio[N].wav files are imported into the character-select bank, which is a
single RWAR holding every character's menu clips.

BrawlLib is x86-only, so this has to run under 32-bit PowerShell:

    C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -File tools\patch-brsar.ps1 ...

Each WAV import opens a dialog that has to be dismissed by hand - BrawlLib's
importer is interactive and there is no silent path through it.
#>
param(
  [Parameter(Mandatory=$true)][string]$VoiceDir,
  [Parameter(Mandatory=$true)][string]$InBrsar,
  [Parameter(Mandatory=$true)][string]$OutBrsar,
  [string]$BrawlLib = "",
  [int]$CssBank = 637,
  [string]$CssNode = "Audio"
)
$ErrorActionPreference = 'Stop'

if ([IntPtr]::Size -ne 4) {
  Write-Warning "BrawlLib is 32-bit. Re-run with C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe"
}

if (-not $BrawlLib) {
  $cand = @(
    "$env:USERPROFILE\Downloads\Brawl\BrawlLib.dll",
    "$env:USERPROFILE\Downloads\BrawlCrate\BrawlLib.dll",
    "$env:ProgramFiles\BrawlCrate\BrawlLib.dll",
    "${env:ProgramFiles(x86)}\BrawlCrate\BrawlLib.dll"
  ) | Where-Object { Test-Path -LiteralPath $_ }
  if ($cand) { $BrawlLib = $cand[0] }
}
if (-not $BrawlLib -or -not (Test-Path -LiteralPath $BrawlLib)) {
  throw "BrawlLib.dll not found - pass -BrawlLib <path> (ships with BrawlCrate)"
}
Add-Type -Path $BrawlLib

$n = [BrawlLib.SSBB.ResourceNodes.NodeFactory]::FromFile($null, $InBrsar)
Write-Output "loaded $InBrsar ($($n.Files.Count) file entries)"

$files = 0
Get-ChildItem -LiteralPath $VoiceDir -File |
  Where-Object { $_.Extension -in '.brwsd', '.brbnk' } |
  ForEach-Object {
    $head = ($_.Name -split ' ')[0]
    if ($head -notmatch '^\d+$') {
      Write-Output "  skipped $($_.Name) - no leading brsar index"
      return
    }
    $idx = [int]$head
    if ($idx -ge $n.Files.Count) {
      Write-Output "  skipped $($_.Name) - index $idx past the end of this archive"
      return
    }
    $n.Files[$idx].Replace($_.FullName)
    $files++
  }
Write-Output "replaced $files file entries"

$wavs = @(Get-ChildItem -LiteralPath $VoiceDir -File -Filter 'Audio`[*`].wav' -ErrorAction SilentlyContinue)
if ($wavs.Count -gt 0) {
  $rwar = $n.Files[$CssBank].Children | Where-Object { $_.Name -eq $CssNode }
  if (-not $rwar) { throw "no '$CssNode' node inside file entry $CssBank" }
  foreach ($w in $wavs) {
    if ($w.BaseName -notmatch '^Audio\[(\d+)\]$') { continue }
    $i = [int]$matches[1]
    $node = $rwar.Children[$i]
    $before = $node.WorkingUncompressed.Length
    $node.Replace($w.FullName)          # opens a dialog - click OK
    Write-Output ("  Audio[{0}] {1} -> {2} bytes" -f $i, $before, $node.WorkingUncompressed.Length)
  }
  Write-Output "replaced $($wavs.Count) character-select clips"
}

$n.Merge()
$n.Export($OutBrsar)
Write-Output "exported $((Get-Item $OutBrsar).Length) bytes to $OutBrsar"

# Reload the result: a brsar that cannot be parsed back is one the game will not
# read either, and it is cheap to catch here instead of in-game.
$v = [BrawlLib.SSBB.ResourceNodes.NodeFactory]::FromFile($null, $OutBrsar)
Write-Output "verify: $($v.GetType().Name), $($v.Files.Count) file entries"
