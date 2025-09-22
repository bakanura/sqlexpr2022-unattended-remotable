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

$instanceName   = "isynet"
$SAPWD          = "noT-4-all"
$SQLMAXMEMORY   = 8192
$directory      = "C:\Temp"
$installerUrl   = "https://go.microsoft.com/fwlink/?linkid=2213259"

# ----------------------------
# Variables
# ----------------------------
$installerPath   = Join-Path $directory "SQLEXPR_x64_ENU.exe"
$configFilePath  = Join-Path $directory "ConfigurationFile.ini"
$psexecPath      = Join-Path $directory "Tools\PsExec.exe"
$extractFolder   = Join-Path $directory "SQLExpress"
$pathToCheck  = "x64\setup\SQL_ENGINE_CORE_SHARED.MSI"
$extractCheck    = Join-Path $extractFolder $pathToCheck
$setupExe        = Join-Path $extractFolder "setup.exe"
$serviceName     = "MSSQL*"

# ----------------------------
# Ensure directories exist
# ----------------------------
foreach ($folder in @($directory, $extractFolder)) {
    if (-not (Test-Path $folder)) {
        New-Item -ItemType Directory -Force -Path $folder | Out-Null
        Write-Host "Created folder: $folder"
    }
}

# ----------------------------
# Download PsExec if missing
# ----------------------------
if (-not (Test-Path $psexecPath)) {
    $psexecUrl = "https://download.sysinternals.com/files/PSTools.zip"
    $zipPath = Join-Path $directory "PSTools.zip"
    Write-Host "Downloading PsExec..."
    Invoke-WebRequest -Uri $psexecUrl -OutFile $zipPath
    Expand-Archive -Path $zipPath -DestinationPath $directory -Force
    Remove-Item $zipPath
    Write-Host "PsExec downloaded to $psexecPath"
}

# ----------------------------
# Download SQL Express if missing
# ----------------------------
if (-not (Test-Path $installerPath)) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $wc = New-Object System.Net.WebClient
    $wc.DownloadFile($installerUrl, $installerPath)
    Write-Host "Download complete: $installerPath"
} else {
    Write-Host "Installer already exists: $installerPath"
}

# ----------------------------
# Extract installer with retry until valid
# ----------------------------
$maxAttempts = 5
$attempt = 0
$success = $false

while (-not $success -and $attempt -lt $maxAttempts) {
    $attempt++
    Write-Host "Extracting SQL Server setup files... (Attempt $attempt of $maxAttempts)"

    # Clean folder first if it exists
    if (Test-Path $extractFolder) {
        Write-Host "Cleaning up old extraction folder: $extractFolder"
        Remove-Item -Recurse -Force -Path $extractFolder
    }
    New-Item -ItemType Directory -Path $extractFolder -Force | Out-Null

    try {
        $extractArgs = "/X:`"$extractFolder`" /Q"
        $extractProc = Start-Process -FilePath $installerPath -ArgumentList $extractArgs -PassThru -Wait
        Write-Host "Extraction exit code: $($extractProc.ExitCode)"

        # Check both setup.exe and MSI existence
        if ($extractProc.ExitCode -eq 0 -and (Test-Path $setupExe) -and (Test-Path $extractCheck)) {
            Write-Host "Extraction successful."
            $success = $true
        }
        else {
            Write-Warning "Extraction failed or required files missing (`$setupExe / $extractCheck)."
        }
    }
    catch {
        Write-Warning "Extraction crashed: $_"
    }

    if (-not $success) {
        if ($attempt -lt $maxAttempts) {
            Write-Host "Retrying extraction in 5 seconds..."
            Start-Sleep -Seconds 5
        }
        else {
            throw "Extraction failed after $maxAttempts attempts. Aborting installation."
        }
    }
}
# ----------------------------
# Generate SQL Server .ini content
# ----------------------------
$iniContent = @(
    '[OPTIONS]',
    'ACTION=Install',
    'FEATURES=SQLENGINE',
    'IACCEPTSQLSERVERLICENSETERMS=1',
    'QUIET=1',
    'SkipRules=RebootRequiredCheck',
    "INSTANCENAME=$instanceName",
    "SQLSVCACCOUNT=$VMAdmin",
    "SQLSVCPASSWORD=$VMPassword",
    "AGTSVCACCOUNT=NT SERVICE\SQLAgent$$$instanceName",
    'SECURITYMODE=SQL',
    "SAPWD=P@ssw0rd123!",
    'SQLSVCSTARTUPTYPE=Automatic',
    "SQLMAXMEMORY=$SQLMAXMEMORY",
    'TCPENABLED=1',
    'SQLCOLLATION=Latin1_General_CI_AS',
    "SQLSYSADMINACCOUNTS=`"BUILTIN\Administrators`""
)

Set-Content -Path $configFilePath -Value $iniContent -Encoding ASCII
Write-Host "INI file written to: $configFilePath"

# ----------------------------
# Start SQL Express via PsExec without waiting for exit code
# ----------------------------
Write-Host "Starting SQL Express installation using PsExec as SYSTEM..."
$psexecArgs = "-d -s powershell.exe -NoProfile -Command `"& '$setupExe' /ConfigurationFile='$configFilePath' /SkipInstallerRunCheck /Q /IACCEPTSQLSERVERLICENSETERMS`""
Start-Process -FilePath $psexecPath -ArgumentList $psexecArgs -NoNewWindow

# ----------------------------
# Wait until setup process starts (SCENARIOENGINE.exe)
# ----------------------------
Write-Host "Waiting for SQL setup process to start..."
do {
    Start-Sleep -Seconds 5
    $setupProc = Get-Process -Name "SCENARIOENGINE" -ErrorAction SilentlyContinue
} while (-not $setupProc)

Write-Host "SQL setup process detected."
# ----------------------------
# Monitor installer log for errors/warnings
# ----------------------------
$logRoot = "C:\Program Files\Microsoft SQL Server\160\Setup Bootstrap\Log"
$logFolder = $null
do {
    Start-Sleep -Seconds 5
    $folders = Get-ChildItem -Path $logRoot -Directory | Sort-Object LastWriteTime -Descending
    if ($folders) { $logFolder = $folders[0].FullName }
} while (-not $logFolder)

Write-Host "Log folder found: $logFolder"

$detailLog = Join-Path $logFolder "Detail.txt"
do {
    Start-Sleep -Seconds 2
} while (-not (Test-Path $detailLog))

Write-Host "Monitoring SQL installer log..."
$errorCodes = @()
$lastStatus = Get-Date

$logWatcher = Start-Job -ScriptBlock {
    param($detailLog)
    Get-Content -Path $detailLog -Wait
} -ArgumentList $detailLog

try {
    while ($true) {
        Start-Sleep -Seconds 2
        $lines = Receive-Job -Job $logWatcher -Keep

        foreach ($line in $lines) {
            # Fatal errors -> capture & exit
            if ($line -match '(?i)error result:\s*(-?\d+)') {
                $code = $matches[1]
                $errorCodes += $code
                Write-Host "[FATAL] Detected Error result code: $code"
                Stop-Job $logWatcher
                Remove-Job $logWatcher
                throw "SQL Express installer failed with error codes: $($errorCodes -join ', ')"
            }

            if ($line -match '(?i)result error code:\s*(\d+)') {
                $code = $matches[1]
                $errorCodes += $code
                Write-Host "[FATAL] Detected Result error code: $code"
                Stop-Job $logWatcher
                Remove-Job $logWatcher
                throw "SQL Express installer failed with error codes: $($errorCodes -join ', ')"
            }

            # Only capture explicit error codes, not generic "error" messages
            if ($line -match 'ErrorCode\s*:\s*(\S+)') {
                $code = $matches[1]
                $errorCodes += $code
                Write-Host "[LOG] Captured installer error code: $code"
            }
        }

        # Print periodic status every 30s if no errors
        if ((Get-Date) -gt $lastStatus.AddSeconds(30)) {
            Write-Host "[STATUS] Installer still running..."
            $lastStatus = Get-Date
        }

        # Check if setup process finished
        $setupProc = Get-Process -Name "SCENARIOENGINE" -ErrorAction SilentlyContinue
        if (-not $setupProc) {
            Stop-Job $logWatcher
            Remove-Job $logWatcher
            if ($errorCodes.Count -eq 0) {
                Write-Host "[INFO] Installer process has exited. No error codes detected. Installation successful."
                break
            } else {
                throw "Installer exited but error codes were detected: $($errorCodes -join ', ')"
            }
        }
    }
}
finally {
    if ($logWatcher) {
        try {
            if (Get-Job -Id $logWatcher.Id -ErrorAction SilentlyContinue) {
                Stop-Job -Id $logWatcher.Id -Force -ErrorAction SilentlyContinue
                Remove-Job -Id $logWatcher.Id -ErrorAction SilentlyContinue
            }
        } catch {
            Write-Host "Log watcher cleanup skipped: $($_.Exception.Message)"
        }
    }
}

# ----------------------------
# Wait for SQL Server service to start
# ----------------------------
Write-Host "Waiting for SQL Server service '$serviceName' to be running..."
do {
    Start-Sleep -Seconds 10
    $svc = Get-Service | Where-Object { $_.Name -like $serviceName } -ErrorAction SilentlyContinue
} while ( $null -eq $svc -or $svc.Status -ne 'Running' )

if ( ![string]::IsNullOrEmpty($svc.name) ){
    Write-Host "SQL Server service is running. `n SQL Express installation complete"
    Write-Host "Restarting system to finalize installation..."
    cmd /c shutdown /a *> $null
    cmd /c shutdown /r /t 0 *> $null
}
