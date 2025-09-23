# File: Retry-Helpers.psm1
# Purpose: Provide resilient retry + session handling functions

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Invoke-WithModernRetry {
    [CmdletBinding()]
    param (
        [ScriptBlock]$ScriptBlock,
        [string]$FilePath,
        [string]$ComputerName,
        [PSCredential]$Credential,
        [ref]$SessionRef,
        [string[]]$InitFunctionFilePaths,
        [int]$MaxRetries = 25,
        [int]$InitialDelaySeconds = 30,
        [int]$MaxDelaySeconds = 300,
        [int]$Port = 5985,
        [int]$SessionTimeoutMinutes = 120,
        [object]$ArgumentList = @() # Can be array or hashtable
    )

    if (-not $ScriptBlock -and -not $FilePath) {
        throw "You must provide either -ScriptBlock or -FilePath."
    }

    Write-StructuredLog -Level 'Information' -Message 'Starting retry operation' -Properties @{
        ComputerName = $ComputerName
        MaxRetries   = $MaxRetries
        Port         = $Port
    }

    $currentDelay = $InitialDelaySeconds
    $consecutiveFailures = 0

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            # Ensure session is valid or create a new one
            if (-not $SessionRef.Value -or $SessionRef.Value.State -ne 'Opened') {
                $connectionTest = Test-NetConnection -ComputerName $ComputerName -Port $Port -WarningAction SilentlyContinue
                if (-not $connectionTest.TcpTestSucceeded) {
                    throw "Connection test failed"
                }

                $sessionOptions = New-PSSessionOption -IdleTimeout ([TimeSpan]::FromMinutes($SessionTimeoutMinutes).TotalMilliseconds) `
                                                     -OpenTimeout ([TimeSpan]::FromMinutes(5).TotalMilliseconds) `
                                                     -OperationTimeout ([TimeSpan]::FromMinutes(10).TotalMilliseconds) `
                                                     -MaxConnectionRetryCount 3

                $SessionRef.Value = New-PSSession -ComputerName $ComputerName -Credential $Credential -SessionOption $sessionOptions
                Write-StructuredLog -Level 'Information' -Message 'Opened New Session' -Properties @{
                    SessionState = $SessionRef.Value.State
                }

                foreach ($initFilePath in $InitFunctionFilePaths) {
                    if (Test-Path $initFilePath) {
                        Invoke-Command -Session $SessionRef.Value -FilePath $initFilePath -ErrorAction Stop
                    }
                }
            }

            Write-StructuredLog -Level 'Information' -Message "Attempt $attempt of $MaxRetries"

            # Prepare arguments
            $argArray = @()
            if ($ArgumentList -is [hashtable]) {
                foreach ($kvp in $ArgumentList.GetEnumerator()) {
                    $argArray += "-$($kvp.Key)"
                    $argArray += $kvp.Value
                }
            } elseif ($ArgumentList -is [array]) {
                $argArray = $ArgumentList
            }

            # Execute script
            if ($FilePath) {
                $result = Invoke-Command -Session $SessionRef.Value -FilePath $FilePath -ArgumentList $argArray -ErrorAction Stop
            } elseif ($ScriptBlock) {
                $result = Invoke-Command -Session $SessionRef.Value -ScriptBlock $ScriptBlock -ArgumentList $argArray -ErrorAction Stop
            }

            $consecutiveFailures = 0
            Write-StructuredLog -Level 'Success' -Message "Operation completed successfully on attempt $attempt"
            return $result
        }
        catch {
            $consecutiveFailures++
            Write-StructuredLog -Level 'Warning' -Message "Attempt $attempt failed" -Properties @{
                Error               = $_.Exception.Message
                ConsecutiveFailures = $consecutiveFailures
                ComputerName        = $ComputerName
            }

            if ($consecutiveFailures -ge 5) {
                throw "CIRCUIT_BREAKER_FAILURE: Too many consecutive failures"
            }

            if ($attempt -eq $MaxRetries) {
                throw "Operation failed after $MaxRetries attempts. Last error: $($_.Exception.Message)"
            }

            $jitter = Get-Random -Minimum 1 -Maximum 10
            $currentDelay = [Math]::Min($currentDelay * 1.5 + $jitter, $MaxDelaySeconds)
            Write-StructuredLog -Level 'Information' -Message "Retrying in $currentDelay seconds..."
            Start-Sleep -Seconds $currentDelay
        }
    }
}

Export-ModuleMember -Function Invoke-WithModernRetry
