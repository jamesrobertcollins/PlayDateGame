#requires -Version 5
<#
  Builds Excavator.pdx containing both the simulator library (pdex.dll) and the device
  binary (pdex.elf). Needs the Playdate SDK, MSYS2 mingw64 (gcc, make, cmake, ninja) and
  the mingw ARM toolchain (arm-none-eabi-gcc).
  Usage: .\build.ps1 [-SimOnly] [-Run]
#>
param(
	[switch]$SimOnly,
	[switch]$Run,
	[string]$Sdk = 'E:\Users\James\Documents\PlaydateSDK',
	[string]$Msys = 'C:\msys64'
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$env:PLAYDATE_SDK_PATH = $Sdk
$env:PATH = "$Msys\mingw64\bin;$Msys\usr\bin;$env:PATH"

function Invoke-Native([string]$what, [scriptblock]$cmd) {
	& $cmd
	if ($LASTEXITCODE -ne 0) { throw "$what failed ($LASTEXITCODE)" }
}

# Simulator build (drops Source\pdex.dll and Excavator.pdx)
$sim = Join-Path $root 'build\sim'
New-Item -ItemType Directory -Force $sim | Out-Null
Push-Location $sim
Invoke-Native 'cmake (sim)' { cmake -G Ninja -DCMAKE_BUILD_TYPE=Release $root }
Invoke-Native 'build (sim)' { cmake --build . }
Pop-Location

if (-not $SimOnly) {
	# Device build (drops Source\pdex.elf and Excavator_DEVICE.pdx, which also contains the dll)
	$dev = Join-Path $root 'build\device'
	New-Item -ItemType Directory -Force $dev | Out-Null
	Push-Location $dev
	Invoke-Native 'cmake (device)' {
		cmake -G Ninja -DCMAKE_BUILD_TYPE=Release "-DCMAKE_TOOLCHAIN_FILE=$Sdk\C_API\buildsupport\arm.cmake" -DTOOLCHAIN=armgcc $root
	}
	Invoke-Native 'build (device)' { cmake --build . }
	Pop-Location
	Write-Host "Device package: $root\Excavator_DEVICE.pdx"
}
Write-Host "Simulator package: $root\Excavator.pdx"

if ($Run) {
	Start-Process "$Sdk\bin\PlaydateSimulator.exe" -ArgumentList "`"$root\Excavator.pdx`""
}
