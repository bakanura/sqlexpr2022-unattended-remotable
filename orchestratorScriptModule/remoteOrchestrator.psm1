# File: Remote-Orchestrator.psm1
# Purpose: General reusable module for remote orchestration

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

#------------------------------------------------------------
# Public: Initialize-RemoteSession
#------------------------------------------------------------
function Initialize-RemoteSession {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory)][string]$VMAdmin,
        [Parameter(Mandatory)][string]$VMPassword,
        [Parameter(Mandatory)][ValidatePattern('^(?:[0-9]{1,3}\.){3}[0-9]{1,3}$')]
        [string]$VMIPAddress,
        [string]$HelperScriptsPath
    )

    $credential = New-SecureCredential -Username $VMAdmin -Password $VMPassword
    Initialize-WinRMConfiguration -IPAddress $VMIPAddress

    $session = New-PSSession -ComputerName $VMIPAddress `
                             -Credential $credential `
                             -SessionOption (New-PSSessionOption -IdleTimeout ([TimeSpan]::FromMinutes(120).TotalMilliseconds))

    return [pscustomobject]@{
        Session      = $session
        Credential   = $credential
        ComputerName = $VMIPAddress
        HelperPath   = $HelperScriptsPath
    }
}

#------------------------------------------------------------
# Public: Run-RemoteScript
#------------------------------------------------------------
function Run-RemoteScript {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory)]$SessionInfo,
        [Parameter(Mandatory)][string]$ScriptPath,
        [hashtable]$Arguments = @{}
    )

    if (-not (Test-Path $ScriptPath)) {
        throw "Remote script missing: $ScriptPath"
    }

    Write-StructuredLog "Running remote script: $ScriptPath with args: $($Arguments | Out-String)"

    Invoke-WithModernRetry -FilePath $ScriptPath `
                           -SessionRef ([ref]$SessionInfo.Session) `
                           -Credential $SessionInfo.Credential `
                           -ComputerName $SessionInfo.ComputerName `
                           -InitFunctionFilePaths @(Join-Path $SessionInfo.HelperPath "Write-StructuredLog.ps1") `
                           -ArgumentList @($Arguments)
}

#------------------------------------------------------------
# Public: Close-RemoteSession
#------------------------------------------------------------
function Close-RemoteSession {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory)]$SessionInfo
    )
    if ($SessionInfo.Session) {
        Remove-PSSession $SessionInfo.Session
        Write-StructuredLog "✔ Remote session cleaned up."
    }
}

Export-ModuleMember -Function Initialize-RemoteSession, Run-RemoteScript, Close-RemoteSession
