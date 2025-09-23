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
# Example: define SQL commands in a way users can customize
# ----------------------------
# Replace these lines with your own SQL commands as needed
$exampleLoginName = "MY_USER"              # <- Change to your desired SQL login
$examplePassword  = "ChangeMe123!"         # <- Change to your desired password
$defaultLanguage  = "English"              # <- Change language if needed
$serverRoles      = @("sysadmin", "dbcreator")  # <- Add/remove server roles as needed

$contentLines = @(
    "-- Set default language for the instance",
    "EXEC sp_configure 'default language', 0;",  # 0 = English, 2 = German, etc.
    "RECONFIGURE;",
    "",
    "-- Create a new SQL login",
    "CREATE LOGIN [$exampleLoginName] WITH PASSWORD = N'$examplePassword', CHECK_POLICY = ON, CHECK_EXPIRATION = OFF, DEFAULT_LANGUAGE = [$defaultLanguage];",
    "",
    "-- Assign server roles"
)
foreach ($role in $serverRoles) {
    $contentLines += "ALTER SERVER ROLE [$role] ADD MEMBER [$exampleLoginName];"
}
$contentLines += ""
$contentLines += "-- Set default language for the new login"
$contentLines += "ALTER LOGIN [$exampleLoginName] WITH DEFAULT_LANGUAGE = [$defaultLanguage];"

$content = $contentLines -join "`r`n"

# ----------------------------
# Ensure setup directory exists
# ----------------------------
if (-not (Test-Path $setupDir)) {
    New-Item -ItemType Directory -Path $setupDir -Force | Out-Null
}

$content | Set-Content -Path $setupFile -Encoding UTF8
Write-Host "Custom SQL setup script created at $setupFile"

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
# Locate sqlcmd.exe
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
# Execute SQL script
# ----------------------------
Write-Host "Executing user-setup.sql on instance $serverInstance using Windows Authentication..."
try {
    & $sqlcmdPath -S $serverInstance -E -b -i $setupFile
    Write-Host "SQL script executed successfully."
} catch {
    throw "Failed to execute user-setup.sql: $_"
}

Write-Host "Custom SQL login and roles configured successfully. You're good to go!"