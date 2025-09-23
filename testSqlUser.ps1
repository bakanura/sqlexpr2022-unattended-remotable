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
# Paths
# ----------------------------
$scriptFile = Join-Path $directory "TempElevatedUserCreation.ps1"
$psexecPath = Join-Path $directory "Tools\PsExec.exe"

# Ensure temp folder exists
if (-not (Test-Path $directory)) { 
    New-Item -ItemType Directory -Force -Path $directory | Out-Null 
}

# ----------------------------
# Build elevated script
# ----------------------------
$scriptContent = @'
param($VMAdmin)

# ----------------------------
# Detect exact Administrators group
# ----------------------------
$groupObj = Get-LocalGroup | Where-Object { $_.Name -eq "Administrators" }
if (-not $groupObj) { Write-Error "Administrators group not found."; exit 1 }
$group = $groupObj.Name

# ----------------------------
# Get current members
# ----------------------------
$members = Get-LocalGroupMember -Group $group -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name

# ----------------------------
# Add user if missing
# ----------------------------
if ($members -notcontains $VMAdmin) {
    Write-Host "Adding user $VMAdmin to $group..."
    Add-LocalGroupMember -Group $group -Member $VMAdmin
    Write-Host "Added to Administrators."
} else {
    Write-Host "User already in Administrators group."
}

# ----------------------------
# Service account adjustments
# ----------------------------
# Make password never expire
Set-LocalUser -Name $VMAdmin -PasswordNeverExpires $true

# Get SID of account
$accountSid = (New-Object System.Security.Principal.NTAccount($VMAdmin)).Translate([System.Security.Principal.SecurityIdentifier]).Value

# Build temporary security policy
$secpolFile = Join-Path $env:TEMP 'secpol.inf'
@"
[Unicode]
Unicode=yes
[Version]
signature=`$CHICAGO$
Revision=1
[Privilege Rights]
SeServiceLogonRight = $accountSid
SeDenyInteractiveLogonRight = $accountSid
SeDenyRemoteInteractiveLogonRight = $accountSid
"@ | Out-File -FilePath $secpolFile -Encoding Unicode

# Apply security policy
secedit.exe /import /db secedit.sdb /cfg $secpolFile /quiet
secedit.exe /configure /db secedit.sdb /quiet

# Cleanup
Remove-Item $secpolFile

Write-Host "Service account rights applied: Log on as a service granted, interactive logons denied."
'@

# ----------------------------
# Write elevated script to temp file
# ----------------------------
$scriptContent | Set-Content -Path $scriptFile -Encoding ASCII
Write-Host "Temporary script written to $scriptFile"

# ----------------------------
# Execute temp script via PsExec as SYSTEM
# ----------------------------
$psexecArgs = "/accepteula -s powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$scriptFile`" -VMAdmin `"$VMAdmin`""
Write-Host "Running user modification script as SYSTEM via PsExec..."
Start-Process -FilePath $psexecPath -ArgumentList $psexecArgs -Wait -NoNewWindow
Write-Host "Script executed successfully."

# ----------------------------
# Cleanup temp script
# ----------------------------
Remove-Item $scriptFile -Force
Write-Host "Temporary script removed."

Write-Host "Restarting system to finalize pending updates..."
# Exit cleanly for orchestrator
        # Abort any pending shutdowns
        cmd.exe /c shutdown /a *> $null

        # Force an immediate restart
        cmd.exe /c shutdown /r /t 0 /f *> $null
        exit 0
