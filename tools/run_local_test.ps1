# Starts a headless dedicated server + N headless bots, runs for -Seconds,
# then kills everything and prints logs.
#   .\tools\run_local_test.ps1 -Bots 4 -Seconds 20 -NetSim "100,20,3"
param(
	[int]$Bots = 3,
	[int]$Seconds = 20,
	[string]$NetSim = "",
	[string]$Extra = "",
	[int]$Port = 27500,
	[int]$Dummies = 0,
	[string]$ServerExtra = "",
	[string]$Godot = "C:\Tools\Godot\Godot_v4.7.2-stable_win64_console.exe"
)
$root = Split-Path $PSScriptRoot -Parent
$logDir = Join-Path $env:TEMP "slabshot_test"
New-Item -ItemType Directory -Force $logDir | Out-Null
Remove-Item "$logDir\*.log" -ErrorAction SilentlyContinue

$procs = @()
$sa = @("--headless","--path","`"$root`"","--","--server","--port=$Port","--dummies=$Dummies")
if ($Extra) { $sa += $Extra }
if ($ServerExtra) { $sa += $ServerExtra.Split(' ') }
$procs += Start-Process $Godot -ArgumentList $sa `
	-RedirectStandardOutput "$logDir\server.log" -RedirectStandardError "$logDir\server.err.log" -PassThru -WindowStyle Hidden
Start-Sleep -Milliseconds 1500
for ($i = 0; $i -lt $Bots; $i++) {
	$a = @("--headless","--path","`"$root`"","--","--join=127.0.0.1:$Port","--bot","--player=bot$i")
	if ($Extra) { $a += $Extra }
	if ($NetSim) { $a += "--netsim=$NetSim" }
	$procs += Start-Process $Godot -ArgumentList $a -RedirectStandardOutput "$logDir\bot$i.log" `
		-RedirectStandardError "$logDir\bot$i.err.log" -PassThru -WindowStyle Hidden
}
Start-Sleep -Seconds $Seconds
$procs | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 500
Get-ChildItem "$logDir\*.log" | ForEach-Object {
	$c = Get-Content $_.FullName | Where-Object { $_ -and $_ -notmatch "^Godot Engine" }
	if ($c) { "=== $($_.Name)"; $c | Select-Object -Last 8 }
}
