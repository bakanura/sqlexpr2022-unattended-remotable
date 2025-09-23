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

# ----------------------------
# Variables
# ----------------------------
$installerPath   = Join-Path $directory "SQLEXPR_x64_ENU.exe"
$configFilePath  = Join-Path $directory "ConfigurationFile.ini"
$psexecPath      = Join-Path $directory "Tools\PsExec.exe"
$extractFolder   = Join-Path $directory "SQLExpress"
$extractCheck    = Join-Path $extractFolder $pathToCheck
$serviceName     = "MSSQL*"

# Convert SA password to SecureString
$secureSAPWD = ConvertTo-SecureString -String $SAPWD -AsPlainText -Force
$saCredential = New-Object System.Management.Automation.PSCredential ("sa", $secureSAPWD)

# ----------------------------
# Ensure directories exist
# ----------------------------
foreach ($folder in @($directory, $extractFolder, (Join-Path $directory "Tools"))) {
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
    Expand-Archive -Path $zipPath -DestinationPath (Join-Path $directory "Tools") -Force
    Remove-Item $zipPath
    Write-Host "PsExec downloaded to $psexecPath"
}

# ----------------------------
# Function: download & extract SQL Express installer
# ----------------------------
function getSqlExpressSetup {
    param (
        [string]$InstallerUrl,
        [string]$InstallerPath,
        [string]$ExtractFolder,
        [string]$ExtractCheck,
        [int]$MaxDownloadRetries = 2,
        [int]$MaxExtractAttempts = 5
    )

    $attempt = 0
    $downloadAttempts = 0
    $success = $false

    while (-not $success) {
        if (-not (Test-Path $InstallerPath) -or $downloadAttempts -ge $MaxDownloadRetries) {
            Write-Host "Downloading SQL Express installer..."
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            try {
                $wc = New-Object System.Net.WebClient
                $wc.DownloadFile($InstallerUrl, $InstallerPath)
                Write-Host "Download complete: $InstallerPath"
                $downloadAttempts = 0
            } catch {
                throw "Failed to download installer: $_"
            }
        }

        $attempt++
        Write-Host "Extracting SQL Server setup files... (Attempt $attempt of $MaxExtractAttempts)"

        if (Test-Path $ExtractFolder) { Remove-Item -Recurse -Force -Path $ExtractFolder }
        New-Item -ItemType Directory -Path $ExtractFolder -Force | Out-Null

        try {
            $extractArgs = "/X:`"$ExtractFolder`" /Q"
            $extractProc = Start-Process -FilePath $InstallerPath -ArgumentList $extractArgs -PassThru -Wait
            $setupExe = Join-Path $ExtractFolder "setup.exe"
            Write-Host "Extraction exit code: $($extractProc.ExitCode)"

            if ($extractProc.ExitCode -eq 0 -and (Test-Path $setupExe) -and (Test-Path $ExtractCheck)) {
                Write-Host "Extraction successful."
                $success = $true
                return $setupExe
            } else {
                Write-Warning "Extraction failed or required files missing (`$setupExe / $ExtractCheck)."
                $downloadAttempts++
                if ($downloadAttempts -ge $MaxDownloadRetries) {
                    Write-Host "Will re-download installer due to repeated extraction failures..."
                    Remove-Item -Force -Path $InstallerPath
                }
            }
        } catch {
            Write-Warning "Extraction crashed: $_"
            $downloadAttempts++
            if ($downloadAttempts -ge $MaxDownloadRetries) {
                Write-Host "Will re-download installer due to repeated extraction failures..."
                Remove-Item -Force -Path $InstallerPath
            }
        }

        if ($attempt -ge $MaxExtractAttempts) { throw "Extraction failed after $MaxExtractAttempts attempts. Aborting." }
        Start-Sleep -Seconds 5
    }
}

# ----------------------------
# Run extraction & get setup.exe
# ----------------------------
$setupExe = getSqlExpressSetup -InstallerUrl $installerUrl `
                                -InstallerPath $installerPath `
                                -ExtractFolder $extractFolder `
                                -ExtractCheck $extractCheck

# ----------------------------
# Function: quote account names if needed
# ----------------------------
function quoteAccountIfNeeded {
    param([string]$account)
    if ($account -match '\s') { return "`"$account`"" } else { return $account }
}

# ----------------------------
# Construct service accounts and INI
# ----------------------------
$sqlServiceAccountFull = "NT Service\MSSQL`$$instanceName"
$sqlAgentAccountFull   = "NT Service\SQLAgent`$$instanceName"

$sqlSvcAccount = quoteAccountIfNeeded -account $sqlServiceAccountFull
$agtSvcAccount = quoteAccountIfNeeded -account $sqlAgentAccountFull

Write-Host "SQL Service Account: $sqlSvcAccount"
Write-Host "SQL Agent Account: $agtSvcAccount"

$iniContent = @(
    '[OPTIONS]',
    'ACTION=Install',
    'FEATURES=SQLENGINE',
    'IACCEPTSQLSERVERLICENSETERMS=1',
    'QUIET=1',
    'SkipRules=RebootRequiredCheck',
    "INSTANCENAME=$instanceName",
    "SECURITYMODE=SQL",
    "SAPWD=$SAPWD",
    'SQLSVCSTARTUPTYPE=Automatic',
    "SQLMAXMEMORY=$SQLMAXMEMORY",
    'TCPENABLED=1',
    'SQLCOLLATION=Latin1_General_CI_AS',
    "SQLSYSADMINACCOUNTS=BUILTIN\Administrators"
)

Set-Content -Path $configFilePath -Value $iniContent -Encoding ASCII
Write-Host "INI file written to: $configFilePath"

# ----------------------------
# Start SQL Express synchronously via PsExec
# ----------------------------
Write-Host "Starting SQL Express installation using PsExec as SYSTEM..."
$psexecArgs = "-s `"$setupExe`" /ConfigurationFile=`"$configFilePath`" /SkipInstallerRunCheck /Q /IACCEPTSQLSERVERLICENSETERMS"
$proc = Start-Process -FilePath $psexecPath -ArgumentList $psexecArgs -Wait -PassThru

Write-Host "SQL setup exited with code: $($proc.ExitCode)"
if ($proc.ExitCode -ne 0) {
    throw "SQL setup failed with exit code $($proc.ExitCode)"
} else {
    Write-Host "SQL Express installation completed successfully."
}

# ----------------------------
# Monitor installer log for error codes
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
do { Start-Sleep -Seconds 2 } while (-not (Test-Path $detailLog))

# ----------------------------
# Wait for SQLScenarioEngine to start before monitoring logs
# ----------------------------
$maxWaitinSecs = 20
$waited = 0
while (-not (Get-Process -Name "SCENARIOENGINE" -ErrorAction SilentlyContinue) -and $waited -lt $maxWaitinSecs) {
    Start-Sleep -Seconds 1
    $waited++
}

if (-not (Get-Process -Name "SCENARIOENGINE" -ErrorAction SilentlyContinue)) {
    throw "SQLScenarioEngine did not start within $maxWaitinSecs seconds. Aborting log monitoring."
}
# ----------------------------
# Monitor installer log and capture error codes
# ----------------------------
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
            # Capture fatal error result codes
            if ($line -match '(?i)error result:\s*(-?\d+)') {
                $code = $matches[1]
                $errorCodes += $code
                Write-Host "[FATAL] Detected Error result code: $code"
                Stop-Job $logWatcher
                Remove-Job $logWatcher
                throw "SQL Express installer failed with error codes: $($errorCodes -join ', ')"
            }

            # Capture other explicit error codes
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
            } else {
                throw "Installer exited but error codes were detected: $($errorCodes -join ', ')"
            }
            break
        }
    }
} finally {
    if ($logWatcher) {
        try {
            if (Get-Job -Id $logWatcher.Id -ErrorAction SilentlyContinue) {
                Stop-Job -Id $logWatcher.Id -ErrorAction SilentlyContinue
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
function waitSqlService {
    param(
        [string]$ServiceName = "MSSQL*",
        [int]$MaxAttempts = 6,
        [int]$PollInterval = 10,
        [System.Management.Automation.PSCredential]$SqlCredential = $null,
        [string]$InstanceName = $null
    )

    Write-Host "Checking for SQL Server service(s) matching '$ServiceName'..."

    for ($i = 1; $i -le $MaxAttempts; $i++) {
        $services = Get-Service | Where-Object { $_.Name -like $ServiceName } -ErrorAction SilentlyContinue
        $runningService = $services | Where-Object { $_.Status -eq 'Running' }

        if ($runningService) {
            Write-Host "SQL Server service running: $($runningService[0].Name)"
            return
        }

        Write-Host "Attempt $i/$MaxAttempts, SQL Server service not running yet..."
        Start-Sleep -Seconds $PollInterval
    }

    Write-Error "SQL Server service '$ServiceName' could not be found running after $MaxAttempts attempts."

    # Optional: check SQL login if credentials provided
    if ($SqlCredential -and $InstanceName) {
        Write-Host "Attempting SQL login test for user '$($SqlCredential.UserName)'..."
        try {
            $connString = "Server=localhost\$InstanceName;Database=master;User ID=$($SqlCredential.UserName);Password=$($SqlCredential.GetNetworkCredential().Password);Connection Timeout=5"
            $conn = New-Object System.Data.SqlClient.SqlConnection $connString
            $conn.Open()
            Write-Host "SQL login '$($SqlCredential.UserName)' is able to connect."
            $conn.Close()
        } catch {
            Write-Warning "SQL login '$($SqlCredential.UserName)' cannot connect: $_"
        }
    }

    Write-Host "Installation requires system restart to finalize SQL Server..."
    # Abort any pending shutdowns
    cmd.exe /c shutdown /a *> $null
    # Force immediate restart
    cmd.exe /c shutdown /r /t 0 /f *> $null

    exit 0
}

# ----------------------------
# Verify SQL installation folder
# ----------------------------
function verifySqlInstallation {
    param([string]$InstanceName)
    $sqlBinPath = "C:\Program Files\Microsoft SQL Server\MSSQL15.$InstanceName\MSSQL\Binn\sqlservr.exe"
    if (Test-Path $sqlBinPath) {
        Write-Host "Verified SQL Server binary exists at: $sqlBinPath"
    } else {
        Write-Warning "SQL Server binary not found at expected path: $sqlBinPath"
    }
}

verifySqlInstallation -InstanceName $instanceName

# ----------------------------
# Call waitSqlService
# ----------------------------
waitSqlService -ServiceName $serviceName -MaxAttempts 6 -PollInterval 10 -SqlCredential $saCredential -InstanceName $instanceName

Write-Host "SQL Express installation and service setup completed successfully."
