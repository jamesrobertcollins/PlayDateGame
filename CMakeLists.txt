# CMake project for the Excavator game's native extension (renderer + terrain edits).
#
# Do not run this by hand - use build.ps1, which sets up the simulator and device builds.
# The SDK's playdate_game.cmake supplies the Playdate-specific flags, copies the built
# library into Source/ as pdex.dll / pdex.elf, and runs pdc to package the .pdx.
cmake_minimum_required(VERSION 3.14)
set(CMAKE_C_STANDARD 11)

# The Playdate SDK location comes from the environment (build.ps1 exports it).
set(ENVSDK $ENV{PLAYDATE_SDK_PATH})

if (NOT ${ENVSDK} STREQUAL "")
	file(TO_CMAKE_PATH ${ENVSDK} SDK)
else()
	message(FATAL_ERROR "Set PLAYDATE_SDK_PATH to your Playdate SDK folder")
endif()

if (NOT EXISTS ${SDK})
	message(FATAL_ERROR "SDK Path not found: ${SDK}")
endif()

set(CMAKE_CONFIGURATION_TYPES "Debug;Release")

set(PLAYDATE_GAME_NAME Excavator)
set(PLAYDATE_GAME_DEVICE Excavator_DEVICE)

project(${PLAYDATE_GAME_NAME} C ASM)

set(GAME_SOURCES src/main.c src/terrain.c)

if (TOOLCHAIN STREQUAL "armgcc")
	# device build: an executable linked with the SDK's startup glue
	add_executable(${PLAYDATE_GAME_DEVICE} ${GAME_SOURCES})
	target_link_libraries(${PLAYDATE_GAME_DEVICE} m)
else()
	# simulator build: a shared library the simulator loads
	add_library(${PLAYDATE_GAME_NAME} SHARED ${GAME_SOURCES})
	if (NOT MSVC AND NOT APPLE)
		target_link_libraries(${PLAYDATE_GAME_NAME} m)
	endif()
endif()

include(${SDK}/C_API/buildsupport/playdate_game.cmake)
