<#
.SYNOPSIS
  Copy (or move) the Bannerlord-Reference folder to another location and make it self-contained.
.DESCRIPTION
  The .blend files in this folder reference textures by path (the Native material library under C:\Blender\Bannerlord-Native-Materials,
  the 1k copies in textures-1k, terrain paint layers, the production file's HDR ...). This script:
    1. copies the folder to -Destination (default: <your Documents>\Bannerlord-Reference), skipping .blend1 backups and *.bak-* files,
    2. asks Blender which external files every .blend uses,
    3. copies only those files into <Destination>\deps\... (optionally downscaled with texconv via -MaxTexture),
    4. rewrites every path inside the copied .blends to point at the copies, relative to the blend (//...),
  so the destination folder can be zipped, moved between drives or handed to another person.
.PARAMETER Source       Folder to relocate (default: the folder above this script).
.PARAMETER Destination  Target folder (default: [Documents]\Bannerlord-Reference). Created if missing.
.PARAMETER Move         Delete the source afterwards (only when every file was copied and remapped without errors).
.PARAMETER MaxTexture   Downscale copied PNG textures so their longest side is <= this many px (0 = copy as-is). Needs texconv.exe next to this script.
.PARAMETER IncludeFullRes  Also copy the full-resolution originals recorded in image['bl_fullres_path'] (the CC map files point at 1k copies by default). Off = those props are dropped.
.PARAMETER Blender      Path to blender.exe (auto-detected under Program Files when omitted).
.EXAMPLE
  .\Relocate-BannerlordReference.ps1
  .\Relocate-BannerlordReference.ps1 -Destination D:\Share\Bannerlord-Reference -MaxTexture 2048
  .\Relocate-BannerlordReference.ps1 -Destination "$env:USERPROFILE\Documents\BL-Ref" -Move
#>
param(
  [string]$Source = (Split-Path $PSScriptRoot -Parent),
  [string]$Destination = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Bannerlord-Reference'),
  [switch]$Move,
  [int]$MaxTexture = 0,
  [switch]$IncludeFullRes,
  [string]$Blender = ''
)
$ErrorActionPreference = 'Stop'
$sw = [Diagnostics.Stopwatch]::StartNew()
function Say($m) { Write-Host ("[{0,5:n0}s] {1}" -f $sw.Elapsed.TotalSeconds, $m) }
# ---- locate Blender --------------------------------------------------------------------------------------------------
if (-not $Blender) {
  $Blender = Get-ChildItem "$env:ProgramFiles\Blender Foundation" -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending |
    ForEach-Object { Join-Path $_.FullName 'blender.exe' } | Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $Blender) { $Blender = (Get-Command blender -ErrorAction SilentlyContinue).Source }
  if (-not $Blender) { throw "blender.exe not found - pass -Blender <path>" }
}
$helper = Join-Path $PSScriptRoot 'bl_relocate.py'
$texconv = Join-Path $PSScriptRoot 'texconv.exe'
if ($MaxTexture -gt 0 -and -not (Test-Path $texconv)) { throw "-MaxTexture needs texconv.exe next to this script ($texconv)" }
$Source = (Resolve-Path $Source).Path.TrimEnd('\')
if ($Destination.TrimEnd('\') -ieq $Source) { throw "Destination is the source folder" }
if ($Destination.ToLower().StartsWith($Source.ToLower() + '\')) { throw "Destination must not be inside the source" }
Say "Blender: $Blender"; Say "Source:  $Source"; Say "Target:  $Destination"
# ---- 1. copy the folder ----------------------------------------------------------------------------------------------
New-Item -ItemType Directory -Force $Destination | Out-Null
$rc = robocopy $Source $Destination /E /NFL /NDL /NJH /NJS /R:1 /W:1 /XF *.blend1 *.bak-*   # deps inside the source is copied along (a self-contained folder stays self-contained)
if ($LASTEXITCODE -ge 8) { throw "robocopy failed with code $LASTEXITCODE" }
$blends = Get-ChildItem $Destination -Filter *.blend -File
Say "copied folder ($($blends.Count) blend files)"
# ---- 2. collect dependencies -----------------------------------------------------------------------------------------
$tmp = Join-Path $env:TEMP ("bl-relocate-" + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Force $tmp | Out-Null
$deps = @{}   # old path (lowercase) -> @{ path; kinds }
foreach ($b in $blends) {   # list from the SOURCE copy so relative (//) paths resolve where the files really are
  $json = Join-Path $tmp ($b.BaseName + '.json'); $srcBlend = Join-Path $Source $b.Name
  & $Blender -b $srcBlend --python $helper -- --list $json 2>&1 | Where-Object { $_ -match '^\[relocate\]' } | ForEach-Object { Say $_ }
  if (-not (Test-Path $json)) { Write-Warning "no dependency list for $($b.Name)"; continue }
  foreach ($d in (Get-Content $json -Raw | ConvertFrom-Json).deps) {
    $k = $d.path.ToLower()
    if (-not $deps.ContainsKey($k)) { $deps[$k] = @{ path = $d.path; kinds = @(); exists = $d.exists } }
    if ($deps[$k].kinds -notcontains $d.kind) { $deps[$k].kinds += $d.kind }
  }
}
# ---- 3. decide new locations and copy --------------------------------------------------------------------------------
$destLower = $Destination.ToLower().TrimEnd('\') + '\'; $srcLower = $Source.ToLower() + '\'
$map = @{}; $copied = 0; $bytes = 0L; $missing = @(); $skippedFullRes = 0; $byDims = @{}
foreach ($k in $deps.Keys) {
  $d = $deps[$k]; $old = $d.path
  if ($old.ToLower().StartsWith($srcLower)) { $map[$old] = Join-Path $Destination $old.Substring($Source.Length + 1); continue }   # already inside the folder
  if ($old.ToLower().StartsWith($destLower)) { continue }
  if (($d.kinds -notcontains 'image') -and ($d.kinds -notcontains 'library') -and -not $IncludeFullRes) { $skippedFullRes++; continue }   # only ever referenced as a full-res original
  if (-not (Test-Path -LiteralPath $old)) { $missing += $old; continue }
  # keep the material library's textures\<catalog>\ structure; everything else goes to deps\other\
  $lower = $old.ToLower(); $i = $lower.IndexOf('\textures\')
  if ($i -ge 0) { $rel = 'textures\' + $old.Substring($i + 10) } else { $rel = 'other\' + (Split-Path $old -Leaf) }
  $new = Join-Path $Destination ('deps\' + $rel)
  $map[$old] = $new
  if (Test-Path -LiteralPath $new) { continue }
  New-Item -ItemType Directory -Force (Split-Path $new -Parent) | Out-Null
  $isPng = $old.ToLower().EndsWith('.png')
  if ($MaxTexture -gt 0 -and $isPng) {
    $fs = [IO.File]::OpenRead($old); $hdr = New-Object byte[] 24; [void]$fs.Read($hdr, 0, 24); $fs.Close()
    $w = ([int]$hdr[16] -shl 24) -bor ([int]$hdr[17] -shl 16) -bor ([int]$hdr[18] -shl 8) -bor [int]$hdr[19]
    $h = ([int]$hdr[20] -shl 24) -bor ([int]$hdr[21] -shl 16) -bor ([int]$hdr[22] -shl 8) -bor [int]$hdr[23]
    if ([Math]::Max($w, $h) -gt $MaxTexture) {
      $f = $MaxTexture / [Math]::Max($w, $h); $key = "{0}x{1}|{2}" -f [Math]::Max(1, [int]($w * $f)), [Math]::Max(1, [int]($h * $f)), (Split-Path $new -Parent)
      if (-not $byDims.ContainsKey($key)) { $byDims[$key] = New-Object System.Collections.Generic.List[string] }
      $byDims[$key].Add($old); continue
    }
  }
  Copy-Item -LiteralPath $old -Destination $new; $copied++; $bytes += (Get-Item -LiteralPath $new).Length
}
foreach ($key in $byDims.Keys) {   # batched texconv runs, one per (size, output folder)
  $dims, $outDir = $key -split '\|', 2; $nw, $nh = $dims -split 'x'; $files = $byDims[$key]
  for ($i = 0; $i -lt $files.Count; $i += 200) {
    $chunk = $files[$i..([Math]::Min($i + 199, $files.Count - 1))]
    & $texconv -w $nw -h $nh -ft png -f R8G8B8A8_UNORM -y -o $outDir @chunk *> $null
    foreach ($c in $chunk) { $n = Join-Path $outDir (Split-Path $c -Leaf); if (Test-Path -LiteralPath $n) { $copied++; $bytes += (Get-Item -LiteralPath $n).Length } else { $missing += $c } }
  }
}
Say ("copied {0} dependency files ({1:n1} GB) into deps\; {2} full-res originals skipped; {3} source files missing" -f $copied, ($bytes / 1GB), $skippedFullRes, $missing.Count)
if ($missing.Count) { $missing | Select-Object -First 10 | ForEach-Object { Write-Warning "missing: $_" } }
# ---- 4. remap paths inside the copied blends --------------------------------------------------------------------------
$mapJson = Join-Path $tmp 'map.json'; $map | ConvertTo-Json -Compress | Set-Content $mapJson -Encoding UTF8
$dropArg = @(); if (-not $IncludeFullRes) { $dropArg = @('--drop-fullres') }
$errors = 0
foreach ($b in $blends) {
  $out = & $Blender -b $b.FullName --python $helper -- --remap $mapJson --origin $Source @dropArg 2>&1
  $line = $out | Where-Object { $_ -match '^\[relocate\]' } | Select-Object -Last 1
  if ($line) { Say $line } else { $errors++; Write-Warning "remap failed for $($b.Name): $(($out | Select-Object -Last 3) -join ' | ')" }
  if ($line -match 'still missing on disk: [1-9]') { $errors++ }
}
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
# ---- 5. optionally remove the source ----------------------------------------------------------------------------------
if ($Move) {
  if ($errors -eq 0 -and $missing.Count -eq 0) { Remove-Item -LiteralPath $Source -Recurse -Force; Say "source folder removed" }
  else { Write-Warning "source NOT removed: $errors blend errors, $($missing.Count) missing files" }
}
Say ("done -> {0}  (total {1:n1} GB)" -f $Destination, ((Get-ChildItem $Destination -Recurse -File | Measure-Object Length -Sum).Sum / 1GB))
