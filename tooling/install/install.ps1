# Install the latest Windows release for the current user.
#
#   irm https://raw.githubusercontent.com/bostrot/sennit/main/tooling/install/install.ps1 | iex
#
# The app goes to %LOCALAPPDATA%\Programs\<App> with a Start menu shortcut.
# No admin rights needed. Pin a version with $env:VERSION = '1.0.6' first.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repo = 'bostrot/sennit'
$api = if ($env:VERSION) {
  "https://api.github.com/repos/$repo/releases/tags/v$($env:VERSION.TrimStart('v'))"
} else {
  "https://api.github.com/repos/$repo/releases/latest"
}

# Release assets are named <App>-<version>-windows-x64.zip; matching on the
# suffix keeps this working across renames of the app.
$asset = (Invoke-RestMethod $api).assets |
  Where-Object { $_.name -like '*-windows-x64.zip' } |
  Select-Object -First 1
if (-not $asset) { throw "No Windows build in the release at $api" }

$name = $asset.name.Split('-')[0]
$dest = Join-Path $env:LOCALAPPDATA "Programs\$name"
$zip = Join-Path ([IO.Path]::GetTempPath()) $asset.name

Write-Host "Downloading $($asset.name)"
Invoke-WebRequest $asset.browser_download_url -OutFile $zip

if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
Expand-Archive $zip -DestinationPath $dest
Remove-Item $zip

$exe = Get-ChildItem $dest -Filter *.exe | Select-Object -First 1
if (-not $exe) { throw "No executable inside $($asset.name)" }

$shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) "$name.lnk"
$link = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcut)
$link.TargetPath = $exe.FullName
$link.WorkingDirectory = $dest
$link.Save()

Write-Host "Installed to $dest. Find $name in the Start menu."
