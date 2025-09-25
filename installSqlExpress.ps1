param (
    [Parameter(Mandatory = $true)]
    [hashtable]$ParamHash
)

# ----------------------------
# Logging function
# ----------------------------
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Write-Host "[$timestamp] [$Level] $Message"
}

# ----------------------------
# Quote account if needed
# ----------------------------
function Quote-AccountIfNeeded {
    param([string]$account)
    if ($account -match '\s') { return "`"$account`"" } else { return $account }
}

# ----------------------------
# Ensure directories exist
# ----------------------------
function Ensure-Directories {
    param([string[]]$Folders)
    foreach ($folderPath in $Folders) {
        if (-not (Test-Path $folderPath)) {
            New-Item -ItemType Directory -Path $folderPath -Force | Out-Null
            Write-Log "Created folder: $folderPath"
        }
    }
}

# ----------------------------
# Download and extract SQL Express installer
# ----------------------------
function Get-SqlExpressSetup {
    param(
        [string]$InstallerUrl,
        [string]$InstallerPath,
        [string]$ExtractFolder,
        [string]$ExtractCheck,
        [int]$MaxDownloadRetries = 2,
        [int]$MaxExtractAttempts = 5
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $attempt = 0
    $downloadAttempts = 0
    $success = $false

    while (-not $success) {
        if (-not (Test-Path $InstallerPath) -or $downloadAttempts -ge $MaxDownloadRetries) {
            Write-Log "Downloading SQL Express installer from $InstallerUrl..."
            try {
                Invoke-WebRequest -Uri $InstallerUrl -OutFile $InstallerPath
                Write-Log "Download complete: $InstallerPath"
                $downloadAttempts = 0
            } catch {
                throw "Failed to download installer: $_"
            }
        }

        $attempt++
        Write-Log "Extracting SQL Server setup files... (Attempt $attempt of $MaxExtractAttempts)"
        if (Test-Path $ExtractFolder) { Remove-Item -Recurse -Force -Path $ExtractFolder }
        New-Item -ItemType Directory -Path $ExtractFolder -Force | Out-Null

        try {
            $extractArgs = "/X:`"$ExtractFolder`" /Q"
            $extractProc = Start-Process -FilePath $InstallerPath -ArgumentList $extractArgs -PassThru -Wait
            $setupExe = Join-Path $ExtractFolder "setup.exe"

            if ($extractProc.ExitCode -eq 0 -and (Test-Path $setupExe) -and (Test-Path $ExtractCheck)) {
                Write-Log "Extraction successful."
                $success = $true
                return $setupExe
            } else {
                Write-Warning "Extraction failed or missing files."
                $downloadAttempts++
                if ($downloadAttempts -ge $MaxDownloadRetries) { Remove-Item -Force -Path $InstallerPath }
            }
        } catch {
            Write-Warning "Extraction crashed: $_"
            $downloadAttempts++
            if ($downloadAttempts -ge $MaxDownloadRetries) { Remove-Item -Force -Path $InstallerPath }
        }

        if ($attempt -ge $MaxExtractAttempts) { throw "Extraction failed after $MaxExtractAttempts attempts." }
        Start-Sleep -Seconds 5
    }
}

# ----------------------------
# Wait for SQL service
# ----------------------------
function Wait-SqlService {
    param(
        [string]$ServiceName = "MSSQL*",
        [int]$MaxAttempts = 6,
        [int]$PollInterval = 10,
        [System.Management.Automation.PSCredential]$SqlCredential = $null,
        [string]$InstanceName = $null
    )

    Write-Log "Checking for SQL Server service(s) matching '$ServiceName'..."
    for ($i = 1; $i -le $MaxAttempts; $i++) {
        $services = Get-Service | Where-Object { $_.Name -like $ServiceName } -ErrorAction SilentlyContinue
        $runningService = $services | Where-Object { $_.Status -eq 'Running' }

        if ($runningService) {
            Write-Log "SQL Server service running: $($runningService[0].Name)" "SUCCESS"
            return
        }

        Write-Log "Attempt $i/$MaxAttempts, SQL Server service not running yet..."
        Start-Sleep -Seconds $PollInterval
    }

    Write-Log "SQL Server service '$ServiceName' not running after $MaxAttempts attempts." "ERROR"

    if ($SqlCredential -and $InstanceName) {
        Write-Log "Attempting SQL login test for '$($SqlCredential.UserName)'..."
        try {
            $connString = "Server=localhost\$InstanceName;Database=master;User ID=$($SqlCredential.UserName);Password=$($SqlCredential.GetNetworkCredential().Password);Connection Timeout=5"
            $conn = New-Object System.Data.SqlClient.SqlConnection $connString
            $conn.Open()
            Write-Log "SQL login '$($SqlCredential.UserName)' can connect." "SUCCESS"
            $conn.Close()
        } catch {
            Write-Log "SQL login '$($SqlCredential.UserName)' cannot connect: $_" "WARN"
        }
    }

    # Force restart to finalize installation
    Write-Log "Restarting system to complete SQL Server installation..." "WARN"
    cmd.exe /c shutdown /r /t 0 /f
    exit 0
}

# ----------------------------
# Verify SQL installation
# ----------------------------
function Verify-SqlInstallation {
    param([string]$InstanceName)
    $sqlBinPath = "C:\Program Files\Microsoft SQL Server\MSSQL15.$InstanceName\MSSQL\Binn\sqlservr.exe"
    if (Test-Path $sqlBinPath) {
        Write-Log "Verified SQL Server binary exists at: $sqlBinPath" "SUCCESS"
    } else {
        Write-Log "SQL Server binary not found at expected path: $sqlBinPath" "WARN"
    }
}

# ----------------------------
# Main installer
# ----------------------------
function Install-SqlExpress {
    param([hashtable]$ParamHash)

    Write-Log "Starting SQL Express installation..."

    # Unpack parameters
    foreach ($k in $ParamHash.Keys) { Set-Variable -Name $k -Value $ParamHash[$k] -Scope 0 }

    $extractFolder = Join-Path $directory "SQLExpress"
    $toolsFolder   = Join-Path $directory "Tools"
    Ensure-Directories -Folders @($directory, $extractFolder, $toolsFolder)

    # Convert SA password
    $secureSAPWD = ConvertTo-SecureString -String $SAPWD -AsPlainText -Force
    $saCredential = New-Object System.Management.Automation.PSCredential ($SA, $secureSAPWD)

    # Ensure PsExec
    $psexecPath = Join-Path $toolsFolder "PsExec.exe"
    if (-not (Test-Path $psexecPath)) {
        Write-Log "Downloading PsExec..."
        $psexecUrl = "https://download.sysinternals.com/files/PSTools.zip"
        $zipPath = Join-Path $directory "PSTools.zip"
        Invoke-WebRequest -Uri $psexecUrl -OutFile $zipPath
        Expand-Archive -Path $zipPath -DestinationPath $toolsFolder -Force
        Remove-Item $zipPath
        Write-Log "PsExec extracted to $toolsFolder"
    }

    $installerPath = Join-Path $directory "SQLEXPR_x64_ENU.exe"
    $setupExe = Get-SqlExpressSetup -InstallerUrl $installerUrl `
                                    -InstallerPath $installerPath `
                                    -ExtractFolder $extractFolder `
                                    -ExtractCheck $pathToCheck

    $sqlSvcAccountFull = "NT Service\MSSQL`$$instanceName"
    $sqlSvcAccount = Quote-AccountIfNeeded -account $sqlSvcAccountFull

    $configFilePath = Join-Path $directory "ConfigurationFile.ini"
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
    Write-Log "INI file written: $configFilePath"

    # Start SQL Express via PsExec
    $psexecArgs = "-s `"$setupExe`" /ConfigurationFile=`"$configFilePath`" /SkipInstallerRunCheck /Q /IACCEPTSQLSERVERLICENSETERMS"
    Write-Log "Starting SQL Express setup via PsExec..."
    $proc = Start-Process -FilePath $psexecPath -ArgumentList $psexecArgs -PassThru

    while (-not $proc.HasExited) {
        Write-Log "SQL Express setup is still running..."
        Start-Sleep -Seconds 15
    }
    $proc.WaitForExit()
    Write-Log "SQL setup exited with code $($proc.ExitCode)"

    if ($proc.ExitCode -ne 0) { throw "SQL setup failed with exit code $($proc.ExitCode)" }

    # Verify installation
    Verify-SqlInstallation -InstanceName $instanceName

    # Wait for service
    Wait-SqlService -ServiceName "MSSQL*" -MaxAttempts 6 -PollInterval 10 -SqlCredential $saCredential -InstanceName $instanceName

    Write-Log "SQL Express installation completed successfully." "SUCCESS"
}

# ----------------------------
# Execute
# ----------------------------
Install-SqlExpress -ParamHash $ParamHash
