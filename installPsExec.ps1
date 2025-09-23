param (
    [Parameter(Mandatory = $true)]
    [hashtable]$ParamHash
)

# ----------------------------
# Unpack parameters
# ----------------------------
foreach ($k in $ParamHash.Keys) {
    Set-Variable -Name $k -Value $ParamHash[$k] -Scope 0
}

function Install-PsExec {
    param (
        [string]$Directory,
        [string]$psexecUrl
    )

    $DestinationFolder = Join-Path $Directory "Tools"
    $psexecPath = Join-Path $DestinationFolder "PsExec.exe"

    try {
        # Ensure destination folder exists
        if (-not (Test-Path $DestinationFolder)) {
            New-Item -ItemType Directory -Force -Path $DestinationFolder -Verbose -ErrorAction Stop
        }

        # Only download/extract if PsExec.exe is missing
        if (-not (Test-Path $psexecPath)) {
            $zipPath = Join-Path $DestinationFolder "PSTools.zip"
            $tempExtract = Join-Path $DestinationFolder "temp_extract"

            Write-Host "Downloading PsExec from $psexecUrl..." -ForegroundColor Cyan
            Invoke-WebRequest -Uri $psexecUrl -OutFile $zipPath -UseBasicParsing -Verbose -ErrorAction Stop

            # Extract entire ZIP to temp folder
            if (Test-Path $tempExtract) { Remove-Item $tempExtract -Recurse -Force }
            Expand-Archive -Path $zipPath -DestinationPath $tempExtract -Force -Verbose

            # Move only PsExec.exe to destination
            $found = Get-ChildItem -Path $tempExtract -Recurse -Filter "PsExec.exe" | Select-Object -First 1
            if ($found) {
                Move-Item -Path $found.FullName -Destination $psexecPath -Force
                Write-Host "PsExec.exe extracted to $DestinationFolder" -ForegroundColor Green
            }
            else {
                throw "PsExec.exe not found in ZIP archive"
            }

            # Cleanup
            Remove-Item $zipPath -Force -Verbose
            Remove-Item $tempExtract -Recurse -Force -Verbose
        }
        else {
            Write-Host "PsExec.exe already exists at $psexecPath" -ForegroundColor Yellow
        }

        return $psexecPath
    }
    catch {
        $errorObj = $_.Exception
        Write-Host "ERROR: $($errorObj.GetType().FullName): $($errorObj.Message)" -ForegroundColor Red
        Write-Host "StackTrace: $($errorObj.StackTrace)" -ForegroundColor Red
        exit 1
    }
}

# ----------------------------
# Main Execution
# ----------------------------
try {
    Write-Host "Starting PsExec installation..." -ForegroundColor Cyan
    $psexecPath = Install-PsExec -Directory $directory -psexecUrl $psexecUrl
    Write-Host "PsExec ready at: $psexecPath" -ForegroundColor Green
    exit 0
}
catch {
    $errorObj = $_.Exception
    Write-Host "UNHANDLED ERROR: $($errorObj.GetType().FullName): $($errorObj.Message)" -ForegroundColor Red
    Write-Host "StackTrace: $($errorObj.StackTrace)" -ForegroundColor Red
    exit 1
}
