# Installs Swap for the signed-in user: copies Swap.exe to %LOCALAPPDATA%\Programs\Swap, starts it at
# login, and starts it now in the user's desktop session (works from an SSH session too).
#   install.ps1          normal user rights
#   install.ps1 -Admin   runs Swap elevated (logon task with highest privileges, no UAC prompt), so it can
#                        also switch to windows of apps that run as administrator. Needs an admin shell.
param([switch]$Admin)
$ErrorActionPreference = "Stop"
$dest = Join-Path $env:LOCALAPPDATA "Programs\Swap"
$exe = Join-Path $dest "Swap.exe"
Get-Process Swap -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 1
New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item (Join-Path $PSScriptRoot "Swap.exe") $exe -Force
$user = (Get-CimInstance Win32_ComputerSystem).UserName
Remove-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name Swap -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName "Swap" -Confirm:$false -ErrorAction SilentlyContinue
$level = if ($Admin) { "Highest" } else { "Limited" }
$action = New-ScheduledTaskAction -Execute $exe
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0 -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel $level
if ($Admin) {
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    Register-ScheduledTask -TaskName "Swap" -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName "Swap"
} else {
    Set-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name Swap -Value "`"$exe`""
    Register-ScheduledTask -TaskName "Swap start" -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName "Swap start"
    Start-Sleep 3
    Unregister-ScheduledTask -TaskName "Swap start" -Confirm:$false
}
Start-Sleep 3
Get-Process Swap | Select-Object Id, SessionId, Path
