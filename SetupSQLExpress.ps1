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
$setupDir       = "C:\TEMP\SQLExpress"
$setupFile      = Join-Path $setupDir "user-setup.sql"
$serviceName    = "MSSQL`$" + $instanceName
$serverInstance = ".\$instanceName"

# ----------------------------
# Create user-setup.sql
# ----------------------------
$contentLines = @(
    "-- Set default language to German",
    "EXEC sp_configure 'default language', 2;",
    "RECONFIGURE;",
    "",
    "-- Create WINACS SQL login",
    "CREATE LOGIN [WINACS] WITH PASSWORD = N'NOT4ALL', CHECK_POLICY = ON, CHECK_EXPIRATION = OFF, DEFAULT_LANGUAGE = [Deutsch];",
    "",
    "-- Assign server roles",
    "ALTER SERVER ROLE [sysadmin] ADD MEMBER [WINACS];",
    "ALTER SERVER ROLE [dbcreator] ADD MEMBER [WINACS];",
    "",
    "-- Set default language for WINACS",
    "ALTER LOGIN [WINACS] WITH DEFAULT_LANGUAGE = [Deutsch];"
)
$content = $contentLines -join "`r`n"

# ----------------------------
# Ensure setup directory exists
# ----------------------------
if (-not (Test-Path $setupDir)) {
    New-Item -ItemType Directory -Path $setupDir -Force | Out-Null
}

$content | Set-Content -Path $setupFile -Encoding UTF8
Write-Host "user-setup.sql created at $setupFile"

# ----------------------------
# Wait for SQL Server service to be running
# ----------------------------
Write-Host "Waiting for SQL Server service '$serviceName' to be running..."
do {
    Start-Sleep -Seconds 5
    $svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
} while (-not $svc -or $svc.Status -ne 'Running')
Write-Host "SQL Server service is running."

# ----------------------------
# Wait for sqlcmd.exe
# ----------------------------
$maxWaitSeconds    = 180
$retryDelaySeconds = 5
$elapsed           = 0
$sqlcmdPath        = $null

Write-Host "Searching for sqlcmd.exe..."
while (-not $sqlcmdPath -and $elapsed -lt $maxWaitSeconds) {
    $sqlcmdPath = Get-Command sqlcmd.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
    if (-not $sqlcmdPath) {
        Write-Host "sqlcmd.exe not found yet, retrying in $retryDelaySeconds seconds..."
        Start-Sleep -Seconds $retryDelaySeconds
        $elapsed += $retryDelaySeconds
    }
}

if (-not $sqlcmdPath) {
    throw "sqlcmd.exe was not found after $maxWaitSeconds seconds. Ensure SQL Server Command Line Utilities are installed."
}

Write-Host "Found sqlcmd.exe at $sqlcmdPath"

# ----------------------------
# Execute SQL script using Windows Authentication (SYSTEM / local admin)
# ----------------------------
Write-Host "Executing user-setup.sql on instance $serverInstance using Windows Authentication..."
try {
    & $sqlcmdPath -S $serverInstance -E -b -i $setupFile
    Write-Host "SQL script executed successfully with Windows Authentication."
} catch {
    throw "Failed to execute user-setup.sql: $_"
}

Write-Host "WINACS login and roles configured. SA account is now ready for use."
