$ErrorActionPreference='Stop'
$Evidence=Join-Path $PWD 'evidence'; New-Item -ItemType Directory $Evidence -Force | Out-Null
$Result=[ordered]@{os=(Get-CimInstance Win32_OperatingSystem).Caption; build=$env:INSTALLER_BUILD}
function Save { $Result | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $Evidence 'result.json') }
function Shot($Name) {
  Add-Type -AssemblyName System.Windows.Forms,System.Drawing
  $b=[System.Windows.Forms.SystemInformation]::VirtualScreen
  $bmp=New-Object System.Drawing.Bitmap $b.Width,$b.Height
  $g=[System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($b.Left,$b.Top,0,0,$bmp.Size)
  $bmp.Save((Join-Path $Evidence $Name)); $g.Dispose(); $bmp.Dispose()
}
$Exe=Join-Path $env:RUNNER_TEMP 'setup.exe'
curl.exe -L --fail --retry 5 --retry-delay 10 -o $Exe $env:INSTALLER_URL
if ($LASTEXITCODE) { throw 'Download failed.' }
$Hash=(Get-FileHash $Exe -Algorithm SHA256).Hash.ToLower()
$Result.bytes=(Get-Item $Exe).Length; $Result.sha256=$Hash; $Result.sha256_ok=($Hash -eq $env:INSTALLER_SHA256.ToLower()); Save
if (-not $Result.sha256_ok) { throw 'Checksum mismatch.' }
$Sig=Get-AuthenticodeSignature $Exe; $Result.authenticode=$Sig.Status.ToString()
$P=Start-Process $Exe -ArgumentList '/S' -Wait -PassThru
$Result.install_exit=$P.ExitCode; Save
if ($P.ExitCode) { throw 'Silent install failed.' }
$Dir=Join-Path $env:LOCALAPPDATA "Programs\CristalMemoriaBeta\versions\$($env:INSTALLER_BUILD)"
$Result.installed_files=@(Get-ChildItem $Dir | ForEach-Object { "$($_.Name) $($_.Length)" })
$Shell=New-Object -ComObject WScript.Shell
$Link=Join-Path ([Environment]::GetFolderPath('Desktop')) 'Cristal Memoria Beta.lnk'
$Result.desktop_shortcut=(Test-Path $Link); if ($Result.desktop_shortcut) { $Result.shortcut_target=$Shell.CreateShortcut($Link).TargetPath }
Save
$Game=Join-Path $Dir 'CristalMemoria.exe'
$Runs=@()
# 1. the game's own capture bench (isolated sandbox profile) with each renderer the runner may support
foreach ($Driver in @('default','d3d12','default','opengl3')) {
  $Png=Join-Path $Evidence "village-$Driver-$($Runs.Count).png"
  $env:CM_CAPTURE=$Png; $env:CM_LANGUE='en'
  $Info=[System.Diagnostics.ProcessStartInfo]::new($Game)
  $GameArgs=if ($Driver -eq 'opengl3') { @('--rendering-method','gl_compatibility','--rendering-driver','opengl3') } elseif ($Driver -eq 'default') { @() } else { @('--rendering-driver',$Driver) }
  foreach ($A in $GameArgs) { $Info.ArgumentList.Add($A) }
  $Info.WorkingDirectory=$Dir; $Info.UseShellExecute=$false; $Info.RedirectStandardOutput=$true; $Info.RedirectStandardError=$true
  $Proc=[System.Diagnostics.Process]::Start($Info)
  $Out=$Proc.StandardOutput.ReadToEndAsync(); $Err=$Proc.StandardError.ReadToEndAsync()
  $Deadline=(Get-Date).AddSeconds(240); $n=0
  while (-not $Proc.HasExited -and (Get-Date) -lt $Deadline) { Start-Sleep 20; $n++; if ($n -in 2,5,9) { try { Shot "desktop-$Driver-$n.png" } catch {} } }
  $TimedOut=-not $Proc.HasExited
  if ($TimedOut) { $Proc.Kill($true); $Proc.WaitForExit() }
  $Log=$Out.GetAwaiter().GetResult()+"`n--- stderr ---`n"+$Err.GetAwaiter().GetResult()
  $Log | Set-Content (Join-Path $Evidence "game-$Driver-$($Runs.Count).log")
  $Runs+=[ordered]@{driver=$Driver; exit=$Proc.ExitCode; timed_out=$TimedOut; capture=(Test-Path $Png); capture_bytes=$(if (Test-Path $Png) {(Get-Item $Png).Length} else {0}); script_errors=([regex]::Matches($Log,'SCRIPT ERROR:|Parse Error:')).Count}
  $Result.runs=$Runs; Save
  if (Test-Path $Png) { break }
}
Remove-Item Env:CM_CAPTURE
# 2. the installed launcher, as a player starts it from the shortcut
$L=Start-Process (Join-Path $Dir 'LancerCristalMemoria.exe') -WorkingDirectory $Dir -PassThru
Start-Sleep 20
$Result.launcher_at_20s=@(Get-Process | Where-Object { $_.ProcessName -in 'CristalMemoria','LancerCristalMemoria' } | ForEach-Object { $_.ProcessName })
try { Shot 'desktop-launcher-20s.png' } catch {}
Start-Sleep 40
$Result.launcher_exited=$L.HasExited; if ($L.HasExited) { $Result.launcher_exit=$L.ExitCode }
$Result.launcher_children=@(Get-Process | Where-Object { $_.ProcessName -in 'CristalMemoria','LancerCristalMemoria' } | ForEach-Object { "$($_.ProcessName) $($_.MainWindowTitle)" })
try { Shot 'desktop-launcher.png' } catch { $Result.launcher_shot_error="$_" }
Get-Process | Where-Object { $_.ProcessName -in 'CristalMemoria','LancerCristalMemoria' } | Stop-Process -Force -ErrorAction SilentlyContinue
$Result.started=[bool]($Runs | Where-Object { $_.capture })
Save
if (-not $Result.started) { throw 'The game did not reach its first rendered screen.' }
