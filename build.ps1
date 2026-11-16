#requires -Version 5
<#
.SYNOPSIS
  Builds Excavator for the Playdate Simulator and the device, or runs the host-side tests.

.DESCRIPTION
  Default: builds Excavator.pdx (simulator, contains pdex.dll) and Excavator_DEVICE.pdx
  (device, contains pdex.bin and the dll). Both are produced by CMake + Ninja using the Playdate
  SDK's own build support, with the compilers from MSYS2:
    - mingw64 gcc, make, cmake, ninja          (simulator)
    - mingw64 arm-none-eabi-gcc + newlib       (device)
  Install them with: pacman -S make mingw-w64-x86_64-{cmake,ninja,arm-none-eabi-gcc,arm-none-eabi-newlib}

.PARAMETER SimOnly
  Skip the device build.
.PARAMETER Run
  Launch the simulator with Excavator.pdx when the build finishes.
.PARAMETER HostTest
  Do not build the game. Compile tools\hosttest.c with the terrain core, run its checks, run the
  Lua checks (tools\radiotest.lua and tools\armtest.lua, if a lua interpreter is on PATH) and
  convert the frames the harness renders to build\*.png. Needs MSYS2 gcc and python with Pillow.
.PARAMETER Sdk
  Playdate SDK folder (also exported as PLAYDATE_SDK_PATH for CMake).
.PARAMETER Msys
  MSYS2 install folder.

.EXAMPLE
  .\build.ps1 -SimOnly -Run
#>
param(
	[switch]$SimOnly,
	[switch]$Run,
	[switch]$HostTest,
	[string]$Sdk = 'E:\Users\James\Documents\PlaydateSDK',
	[string]$Msys = 'C:\msys64'
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$env:PLAYDATE_SDK_PATH = $Sdk
# the MSYS2 toolchains must come first on PATH so cmake finds them
$env:PATH = "$Msys\mingw64\bin;$Msys\usr\bin;$env:PATH"

# PowerShell does not stop on a failing native command, so check the exit code explicitly.
function Invoke-Native([string]$what, [scriptblock]$cmd) {
	& $cmd
	if ($LASTEXITCODE -ne 0) { throw "$what failed ($LASTEXITCODE)" }
}

if ($HostTest) {
	$out = Join-Path $root 'build'
	New-Item -ItemType Directory -Force $out | Out-Null
	Push-Location $root
	try {
		Invoke-Native 'compile hosttest' { gcc -O2 -Wall -Wextra tools\hosttest.c src\terrain.c -o build\hosttest.exe -lm }
		Invoke-Native 'run hosttest' { .\build\hosttest.exe 256 }
		# song data checks need a standalone Lua interpreter; skip them (with a note) if absent
		if (Get-Command lua -ErrorAction SilentlyContinue) {
			Invoke-Native 'run radiotest' { lua tools\radiotest.lua }
			Invoke-Native 'run armtest' { lua tools\armtest.lua }
		} else {
			Write-Host "lua not found: skipping tools\radiotest.lua and tools\armtest.lua (pacman -S mingw-w64-x86_64-lua)"
		}
		$raws = Get-ChildItem build\*.raw | ForEach-Object { $_.FullName }
		if ($raws) { python tools\raw2png.py @raws | Out-Null; Write-Host "Frames written to $out\*.png" }
	} finally {
		Pop-Location
	}
	return
}

# Simulator build: drops Source\pdex.dll and Excavator.pdx next to the sources.
$sim = Join-Path $root 'build\sim'
New-Item -ItemType Directory -Force $sim | Out-Null
Push-Location $sim
Invoke-Native 'cmake (sim)' { cmake -G Ninja -DCMAKE_BUILD_TYPE=Release $root }
Invoke-Native 'build (sim)' { cmake --build . }
Pop-Location

if (-not $SimOnly) {
	# Device build: drops Source\pdex.elf and Excavator_DEVICE.pdx (which also holds the dll).
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
