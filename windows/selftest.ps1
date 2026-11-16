# Runs the live self-test (SwapQA.exe) on the desktop of the signed-in user, even from an SSH session:
# a one-off scheduled task runs it in that user's interactive session. Takes about 2 minutes; nobody
# should use the keyboard or mouse meanwhile. Prints the results; panel.png is saved next to the log.
param([switch]$DesktopsOnly)
Set-Location $PSScriptRoot
$log = Join-Path $PSScriptRoot "selftest.log"
Remove-Item $log, (Join-Path $PSScriptRoot "panel.png") -ErrorAction SilentlyContinue
$args = "--selftest `"$log`" --only notepad,mspaint"
if ($DesktopsOnly) { $args += " --desktops-only" }
$user = (Get-CimInstance Win32_ComputerSystem).UserName
$action = New-ScheduledTaskAction -Execute (Join-Path $PSScriptRoot "SwapQA.exe") -Argument $args -WorkingDirectory $PSScriptRoot
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
Register-ScheduledTask -TaskName "Swap self-test" -Action $action -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName "Swap self-test"
for ($i = 0; $i -lt 240; $i++) {
    Start-Sleep 1
    if ((Test-Path $log) -and (Select-String -Path $log -Pattern "^DONE" -Quiet)) { break }
}
Unregister-ScheduledTask -TaskName "Swap self-test" -Confirm:$false
Get-Content $log
