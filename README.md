# SQL Express Setup Scripts 😎

A bunch of PowerShell scripts to help you **install SQL Server Express**, create service accounts, set up SQL logins, and get everything running without having to click through a million dialogs.  

They’re made to be **modular**, **re-run friendly**, and take care of the annoying stuff for you, like downloading PsExec, elevating scripts, and monitoring install logs.

---

## Table of Contents

- [What’s in this repo](#whats-in-this-repo)  
- [Before You Start](#before-you-start)  
- [The Scripts](#the-scripts)  
- [How to Use](#how-to-use)  
- [Parameters](#parameters)  
- [Logs & Watching Stuff](#logs--watching-stuff)  
- [License](#license)  

---

## What’s in this repo

This setup will handle:

- Downloading SQL Express installer and extracting it  
- Installing SQL Express quietly (no popups!) using PsExec  
- Creating SQL logins with proper roles  
- Creating and configuring local service accounts  
- Watching logs for errors in real time  
- Restarting the machine if it’s needed  

Basically, you run it and then grab a coffee while it does the heavy lifting.

---

## Before You Start

Make sure you have:

- Windows 10 / Server 2016 or later  
- PowerShell 5.1+  
- Internet (for SQL Express and PsExec downloads)  
- Local Admin privileges  
- Don’t worry about PsExec, the scripts will get it for you if it’s missing  

---

## The Scripts

| Script | What it does |
|--------|--------------|
| `installSqlExpress.ps1` | Downloads, extracts, configures, and installs SQL Server Express silently. |
| `testsqluser.ps1` | Adds a VM admin account and tweaks it to be ready for services. |
| `Setupsql.ps1` | Runs SQL scripts to create logins, set default language, and assign roles. |
| `install psexec.ps1` | Downloads PsExec to your Tools folder if it isn’t already there. |

---

## How to Use

Here’s a typical run-through:

```powershell
$paramHash = @{
    directory      = "C:\TEMP\SQLExpress"
    installerUrl   = "https://download.microsoft.com/SQLEXPR_x64_ENU.exe"
    instanceName   = "SQLEXPRESS"
    SAPWD          = "Strong!Passw0rd"
    SQLMAXMEMORY   = 2048
    pathToCheck    = "setup.exe"
    psexecUrl      = "https://download.sysinternals.com/files/PSTools.zip"
    VMAdmin        = "MyAdminUser"
}

# 1. Make sure PsExec is there
.\install psexec.ps1 -ParamHash $paramHash

# 2. Install SQL Express
.\installSqlExpress.ps1 -ParamHash $paramHash

# 3. Create service accounts
.\testsqluser.ps1 -ParamHash $paramHash

# 4. Configure SQL logins
.\Setupsql.ps1 -ParamHash $paramHash

## It’s really just a matter of running them in order.

---

## Parameters

All scripts use **one hashtable `$ParamHash`**. Here’s what you can put in it:

| Parameter      | What it’s for                                           |
|----------------|--------------------------------------------------------|
| `directory`    | Where to download stuff and put temp files            |
| `installerUrl` | The SQL Express installer link                         |
| `instanceName` | Your SQL instance name (like `SQLEXPRESS`)            |
| `SAPWD`        | SA password (plain text, will be secured internally)  |
| `SQLMAXMEMORY` | Max memory for SQL in MB                               |
| `pathToCheck`  | File to confirm after extraction (`setup.exe`)        |
| `psexecUrl`    | Where to grab PsExec if missing                        |
| `VMAdmin`      | Name of the service account for `testsqluser.ps1`     |
