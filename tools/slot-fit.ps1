<#
Reports whether loose voice files fit the slots reserved for them inside
revo_kart.brsar - the single most useful thing to know when a costume's voice
does not come out.

Retro Rewind patches a loose file into the sound archive in place, so it needs
BOTH halves to fit the slot the archive already reserves:

  * the header   - the file's own declared size, at offset 8
  * the wave     - the size declared by the RWAR block that follows it

Overflow is not a crash. The engine bounds-checks before writing and falls back
to an external buffer, or drops that one override. It shows up as a wrong or
missing clip, which is exactly why this check is worth running.

usage:
  powershell -File tools\slot-fit.ps1 -Brsar <revo_kart.brsar> -Dir <Patches folder>
             [-Filter 'GRP_VO_RS-2_*'] [-RefVoices <mod's Voices folder>]

Files named <index>.<ext> carry their brsar index in the name and need nothing
else. Files named GRP_VO_<CODE>-<v>_<TYPE>.<ext> need -RefVoices pointing at a
mod Voices folder, whose "<index> GRP_VO_<CODE>_<TYPE>" names supply the map.
#>
param(
  [Parameter(Mandatory=$true)][string]$Brsar,
  [Parameter(Mandatory=$true)][string]$Dir,
  [string]$Filter = '*',
  [string]$RefVoices = ''
)
$ErrorActionPreference = 'Stop'

function BE($fs, [int64]$o, [int]$n) {
  $fs.Position = $o; $b = New-Object byte[] $n; [void]$fs.Read($b, 0, $n)
  $v = [int64]0; foreach ($x in $b) { $v = $v * 256 + $x }; $v
}
function MAGIC($fs, [int64]$o) {
  $fs.Position = $o; $b = New-Object byte[] 4; [void]$fs.Read($b, 0, 4)
  [System.Text.Encoding]::ASCII.GetString($b)
}

# type -> brsar index, from a mod's Voices folder
$map = @{}
if ($RefVoices) {
  Get-ChildItem -LiteralPath $RefVoices -File |
    Where-Object { $_.Extension -in '.brwsd', '.brbnk' } |
    ForEach-Object {
      if ($_.BaseName -match '^(\d+)\s+GRP_VO_[A-Za-z]+_(.+)$') {
        $map["$($matches[2])$($_.Extension)"] = [int]$matches[1]
      }
    }
}

# index -> slot, walking every group in the archive
$fs = [System.IO.File]::OpenRead($Brsar)
$base = (BE $fs 24 4) + 8
$grpTbl = $base + (BE $fs ($base + 0x24) 4)
$gc = BE $fs $grpTbl 4
$slot = @{}
for ($g = 0; $g -lt $gc; $g++) {
  $e = $base + (BE $fs ($grpTbl + 4 + ($g * 8) + 4) 4)
  $itemTbl = $base + (BE $fs ($e + 36) 4)
  $n = BE $fs $itemTbl 4
  for ($i = 0; $i -lt $n; $i++) {
    $it = $base + (BE $fs ($itemTbl + 4 + ($i * 8) + 4) 4)
    $fid = [int](BE $fs $it 4)
    if (-not $slot.ContainsKey($fid)) {
      $slot[$fid] = @{ g = $g; h = (BE $fs ($it + 8) 4); w = (BE $fs ($it + 16) 4) }
    }
  }
}
$fs.Close()

"{0,-22} {1,-5} {2,-5} {3,10} {4,10} {5,11} {6,11}  {7}" -f `
  'FILE','id','group','hdr','slotHdr','wave','slotWave','verdict'

$bad = 0
foreach ($f in (Get-ChildItem -LiteralPath $Dir -File -Filter $Filter | Sort-Object Name)) {
  if ($f.Extension -notin '.brwsd', '.brbnk') { continue }

  $id = $null
  if ($f.BaseName -match '^(\d+)$') { $id = [int]$matches[1] }
  elseif ($f.BaseName -match '^GRP_VO_[A-Za-z]+-\d+_(.+)$') { $id = $map["$($matches[1])$($f.Extension)"] }
  if ($null -eq $id) { "{0,-22} no index (pass -RefVoices?)" -f $f.Name; continue }

  $s = $slot[$id]
  if (-not $s) { "{0,-22} id {1} is not in this archive" -f $f.Name, $id; continue }

  $g = [System.IO.File]::OpenRead($f.FullName)
  $hdr = BE $g 8 4                       # the file's own declared size
  $p = $hdr; $wav = 0
  while ($p -lt $g.Length) {             # skip LABL, stop at the wave archive
    $m = MAGIC $g $p
    if ($m -eq 'LABL') { $p += (BE $g ($p + 4) 4) }
    elseif ($m -eq 'RWAR') { $wav = BE $g ($p + 8) 4; break }
    else { break }
  }
  $g.Close()

  $dh = $hdr - $s.h; $dw = $wav - $s.w
  if ($dh -le 0 -and $dw -le 0) { $verdict = 'fits' }
  else {
    $bad++
    $parts = @()
    if ($dh -gt 0) { $parts += "hdr +$dh" }
    if ($dw -gt 0) { $parts += "wave +$dw" }
    $verdict = $parts -join ', '
  }
  "{0,-22} {1,-5} {2,-5} {3,10} {4,10} {5,11} {6,11}  {7}" -f `
    $f.Name, $id, $s.g, $hdr, $s.h, $wav, $s.w, $verdict
}

if ($bad -gt 0) {
  Write-Output ""
  Write-Output "$bad file(s) overflow their slot. Options, cheapest first:"
  Write-Output "  * swap in another take from the same mod that does fit"
  Write-Output "  * drop the file and let the slot keep whatever the archive holds"
  Write-Output "  * install a brsar built from these same files, which sizes every"
  Write-Output "    slot to fit them exactly (tools\patch-brsar.ps1)"
}
