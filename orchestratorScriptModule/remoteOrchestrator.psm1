# File: Orchestrator.ps1
# Purpose: Generic orchestrator for remote operations
# Requires: Remote-Orchestrator.psm1

[CmdletBinding(SupportsShouldProcess)]
Param (
    [Parameter(Mandatory = $true)][string]$VMAdmin = $env:VMAdmin,
    [Parameter(Mandatory = $true)][string]$VMPassword = $env:VMPassword,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^(?:[0-9]{1,3}\.){3}[0-9]{1,3}$')]
    [string]$VMIPAddress = $env:VMIPAddress,
    [Parameter(Mandatory = $true)][ValidateLength(1, 15)][string]$ComputerName = $env:ComputerName,
    [Parameter(Mandatory = $false)][string]$EXTRA_SCRIPTS_PATH = ".\Scripts"
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

#------------------------------------------------------------
# Import orchestrator module
#------------------------------------------------------------
Import-Module ./Remote-Orchestrator.psm1 -Force

#------------------------------------------------------------
# Initialize remote session
#------------------------------------------------------------
$sessionInfo = Initialize-RemoteSession -VMAdmin $VMAdmin `
                                        -VMPassword $VMPassword `
                                        -VMIPAddress $VMIPAddress `
                                        -HelperScriptsPath $EXTRA_SCRIPTS_PATH

#------------------------------------------------------------
# Define operation scripts (edit this for your workload)
#------------------------------------------------------------
$operationScripts = @(
    # Example 1
    @{ Path = "C:\RemoteOps\installDotNet.ps1"; Args = @{
            NetFrameworkVersions = "3.5"
            psexecPath           = "C:\Temp\Tools\PsExec.exe"
    }},
    # Example 2
    @{ Path = "C:\RemoteOps\installSqlExpress.ps1"; Args = @{
            instanceName = "sqlexpress2022"
            SA           = "sa"
            SAPWD        = "sqlexpress2022pwd"
            SQLMAXMEMORY = 8192
            directory    = "C:\Temp"
    }}
)

#------------------------------------------------------------
# Run all operations in sequence
#------------------------------------------------------------
foreach ($script in $operationScripts) {
    Run-RemoteScript -SessionInfo $sessionInfo `
                     -ScriptPath $script.Path `
                     -Arguments $script.Args
    Start-Sleep -Seconds 30  # optional delay for reboot-sensitive steps
}

#------------------------------------------------------------
# Cleanup
#------------------------------------------------------------
Close-RemoteSession -SessionInfo $sessionInfo
Write-Host "🎉 Orchestration completed successfully."
