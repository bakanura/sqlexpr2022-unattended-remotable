param (
    [Parameter(Mandatory = $true)]
    [hashtable]$ParamHash
)

# ----------------------------
# Unpack parameters from hashtable
# ----------------------------
foreach ($k in $ParamHash.Keys) {
    Set-Variable -Name $k -Value $ParamHash[$k] -Scope 0
}

$DestinationFolder = Join-Path $directory "Tools"
if (-not (Test-Path $DestinationFolder)) {
    New-Item -ItemType Directory -Force -Path $DestinationFolder | Out-Null
    Write-Host "Created folder: $DestinationFolder"
}

$psexecPath = Join-Path $DestinationFolder "PsExec.exe"

if (-not (Test-Path $psexecPath)) {
    $psexecUrl = "https://download.sysinternals.com/files/PSTools.zip"
    $zipPath = Join-Path $DestinationFolder "PSTools.zip"
    Write-Host "Downloading PsExec..."
    Invoke-WebRequest -Uri $psexecUrl -OutFile $zipPath

    Write-Host "Extracting PsExec..."
    Expand-Archive -Path $zipPath -DestinationPath $DestinationFolder -Force
    Remove-Item $zipPath
    Write-Host "PsExec downloaded and extracted to $psexecPath"
} else {
    Write-Host "PsExec already exists at $psexecPath"
}

Write-Host "Restarting System to finalize pending updates before continuing..."
cmd /c shutdown /a *> $null
cmd /c shutdown /r /t 0 *> $null