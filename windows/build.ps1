# Builds Swap.exe (and SwapQA.exe with the live self-test) with the C# compiler that ships with Windows.
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$refs = "/r:System.Windows.Forms.dll", "/r:System.Drawing.dll", "/r:System.Core.dll"
& $csc /nologo /target:winexe /optimize+ /out:Swap.exe $refs Swap.cs Tokens.cs
if ($LASTEXITCODE) { exit $LASTEXITCODE }
& $csc /nologo /target:winexe /optimize+ /define:SELFTEST /out:SwapQA.exe $refs Swap.cs Tokens.cs SelfTest.cs
if ($LASTEXITCODE) { exit $LASTEXITCODE }
"built Swap.exe and SwapQA.exe"
