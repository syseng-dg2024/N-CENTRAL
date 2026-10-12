<#
.SYNOPSIS
  Removes the N-able N-central Windows Agent and related components.
.NOTES
  Run elevated. Leaves AV Defender (EP* services) alone.
  Logs to C:\Temp\NCentralRemoval\
#>
[CmdletBinding()]
param(
    [int]$TimeoutSeconds = 300,        # max wait per uninstaller
    [switch]$KillStaleMsiexec,         # kill msiexec client processes older than 10 min
    [switch]$KeepFolders               # skip folder/registry cleanup
)

$ErrorActionPreference = 'Continue'
$LogDir = 'C:\Temp\NCentralRemoval'
New-Item $LogDir -ItemType Directory -Force | Out-Null
Start-Transcript -Path (Join-Path $LogDir "removal_$(Get-Date -Format yyyyMMdd_HHmmss).txt") | Out-Null

function Stop-Watchdog {
    # The agent leaves a delayed cmd.exe that runs the AV Defender "Installer.exe /remove /silent"
    # once agent.exe is gone. Kill it so AV is not removed.
    Get-CimInstance Win32_Process -Filter "Name='cmd.exe'" |
        Where-Object { $_.CommandLine -match 'EndpointSetupInformation' -and $_.CommandLine -match '/remove' } |
        ForEach-Object {
            Write-Host "Killing AV watchdog PID $($_.ProcessId)"
            Get-CimInstance Win32_Process | Where-Object { $_.ParentProcessId -eq $_.ProcessId } | Out-Null
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
}

function Invoke-Uninstall {
    param([string]$File, [string]$Arguments, [string]$Label)
    Write-Host "Uninstalling $Label ..."
    $p = Start-Process -FilePath $File -ArgumentList $Arguments -PassThru
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
        Write-Warning "$Label timed out after $TimeoutSeconds s - killing"
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return
    }
    Write-Host "$Label exit code: $($p.ExitCode)  (0/3010 = ok, 1605 = already gone)"
}

# 0. Kill watchdog first
Stop-Watchdog

# 1. Optional: clear stale msiexec jobs (these block new installs/uninstalls)
if ($KillStaleMsiexec) {
    Get-CimInstance Win32_Process -Filter "Name='msiexec.exe'" |
        Where-Object { $_.CommandLine -notmatch ' /V' -and $_.CreationDate -lt (Get-Date).AddMinutes(-10) } |
        ForEach-Object { Write-Host "Killing stale msiexec PID $($_.ProcessId)"; Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Restart-Service msiserver -Force -ErrorAction SilentlyContinue
}

# 2. Stop agent services and processes
Get-Service | Where-Object { $_.DisplayName -match 'Windows Agent|Patch Management|File Cache|Request Handler|MSP Core|Take Control' -or $_.Name -match 'BASupport' } |
    ForEach-Object { Write-Host "Stopping $($_.Name)"; Stop-Service $_ -Force -ErrorAction SilentlyContinue }
Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.Path -like '*N-able Technologies\Windows Agent*' -or $_.Path -like '*BeAnywhere*' -or $_.Name -match 'BASupSrvc|BASupApp'
} | Stop-Process -Force -ErrorAction SilentlyContinue

# 3. Find installed components (by name, not hardcoded GUID)
$names = 'Windows Agent','MSP Core Agent','Patch Management Service Controller','File Cache Service Agent','Request Handler Agent'
$keys  = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
$found = Get-ChildItem $keys -ErrorAction SilentlyContinue | Get-ItemProperty |
         Where-Object { $_.DisplayName -and ($names -contains $_.DisplayName) }

if (-not $found) { Write-Host "No agent components in the registry." }

# 4. Uninstall MSI components first (Windows Agent last would also be fine, order is by list)
foreach ($app in $found) {
    $id = $app.PSChildName
    if ($id -match '^\{[0-9A-Fa-f-]{36}\}$') {
        # MSI
        $log = Join-Path $LogDir ("{0}_{1}.log" -f ($app.DisplayName -replace '\s','_'), $id.Trim('{}'))
        Invoke-Uninstall -File 'msiexec.exe' -Arguments "/x $id /qn /norestart /L*v `"$log`"" -Label $app.DisplayName
    }
    elseif ($app.UninstallString) {
        # Inno Setup (_is1) - needs its own unins000.exe, NOT msiexec
        $exe = ($app.UninstallString -replace '^"([^"]+)".*$','$1')
        if (Test-Path -LiteralPath $exe) {
            Invoke-Uninstall -File $exe -Arguments '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' -Label $app.DisplayName
        } else {
            Write-Warning "$($app.DisplayName): uninstaller missing ($exe) - orphaned entry, cleaned in step 7."
        }
    }
}

# 5. Kill the watchdog again (it is created during/after agent removal)
Start-Sleep -Seconds 5
Stop-Watchdog

# 6. Remove Take Control (BeAnywhere) service and files
Get-CimInstance Win32_Service | Where-Object { $_.PathName -match 'BeAnywhere|BASupSrvc' } | ForEach-Object {
    Write-Host "Deleting service $($_.Name)"
    Stop-Process -Name BASupSrvc* -Force -ErrorAction SilentlyContinue
    sc.exe delete $_.Name | Out-Null
}

if (-not $KeepFolders) {
    # 7. Leftover folders (AVDefender folders are deliberately NOT touched)
    $paths = @(
        'C:\Program Files (x86)\BeAnywhere Support Express',
        'C:\Program Files (x86)\N-able Technologies\Windows Agent',
        'C:\Program Files (x86)\N-able Technologies\NcentralAsset.xml',
        'C:\ProgramData\N-able Technologies\Windows Agent',
        'C:\ProgramData\N-able Technologies\AutomationManager'
    )
    foreach ($p in $paths) {
        if (Test-Path -LiteralPath $p) {
            Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $p) { Write-Warning "Could not fully remove $p (locked - reboot and delete)" }
            else { Write-Host "Removed $p" }
        }
    }
    # Remove parent N-able folder only if empty
    $parent = 'C:\Program Files (x86)\N-able Technologies'
    if ((Test-Path $parent) -and -not (Get-ChildItem $parent -Force)) { Remove-Item $parent -Force }

    # 8. Registry leftovers
    foreach ($k in 'HKLM:\SOFTWARE\N-able Technologies','HKLM:\SOFTWARE\WOW6432Node\N-able Technologies') {
        if (Test-Path $k) {
            # keep AV Defender keys if present
            Get-ChildItem $k -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -notmatch 'AVDefender|Endpoint' } |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            if (-not (Get-ChildItem $k -ErrorAction SilentlyContinue)) { Remove-Item $k -Force -ErrorAction SilentlyContinue }
        }
    }
}

# 9. Verification
Write-Host "`n===== VERIFICATION ====="
"Agent exe present : " + (Test-Path 'C:\Program Files (x86)\N-able Technologies\Windows Agent\bin\agent.exe')
"Remaining entries :"
Get-ChildItem $keys -ErrorAction SilentlyContinue | Get-ItemProperty |
    Where-Object { $_.DisplayName -in $names } | Select-Object DisplayName, PSChildName | Format-Table -AutoSize
"Remaining services:"
Get-CimInstance Win32_Service | Where-Object { $_.PathName -match 'Windows Agent|BeAnywhere|BASupSrvc' } | Select-Object Name, State | Format-Table -AutoSize
"AV Defender:"
Get-Service EPSecurityService, EPUpdateService -ErrorAction SilentlyContinue | Select-Object Name, Status | Format-Table -AutoSize
"Watchdog still running: " + [bool](Get-CimInstance Win32_Process -Filter "Name='cmd.exe'" |
    Where-Object { $_.CommandLine -match 'EndpointSetupInformation' -and $_.CommandLine -match '/remove' })

Stop-Transcript | Out-Null
Write-Host "Logs: $LogDir"
