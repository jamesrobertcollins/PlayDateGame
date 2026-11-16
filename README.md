# Excavator

A first-person excavator sandbox for the [Playdate](https://play.date). Sit in the cab, drive across an open grass field ringed by trees, and dig, dump and grade the ground: carve a hole, pile a hill, and shape ramps you can drive up and down.

![status](https://img.shields.io/badge/status-phase%204%20of%204-green)

> Status: all four planned phases are done and it is playable in the simulator. It has not yet been tuned on real hardware. See [Roadmap](#roadmap).

## Controls

| Input | Action |
|---|---|
| **Left / Right** | Turn the body |
| **Up / Down** | Drive forwards / backwards |
| **Crank** | Raise and lower the arm (absolute: crank angle = arm position, with soft end stops). The crank must be undocked; the game shows the standard "undock the crank" prompt otherwise. |
| **A (tap)** | Step the bucket curl: open, half, fully curled, then open again |
| **A (hold)** | Dump the bucket |
| **B (hold)** | Lower the grade blade at the front of the tracks (see below) |
| **B (tap)** | In the *Joints* arm scheme, switch the joint the crank controls (boom or stick) |
| **B** after tipping | Reset the machine to the middle of the field |
| **Menu button** | Radio, Arm and Settings (below) |

A "tap" is a press shorter than 0.25 s; anything longer is a "hold".

### Menu

The Playdate allows only three custom system-menu items, so the game uses them like this:

| Item | Values | Effect |
|---|---|---|
| **Radio** | Off, the built-in stations, then any of your own files | Changes the cab radio. A short notice shows the station. |
| **Arm** | Arc / Joints | *Arc*: the crank drives boom and stick together along a preset digging arc. *Joints*: the crank drives one joint at a time, switched with a B tap (the dashboard shows which). |
| **Settings** | opens a panel | See below. |

The **Settings** panel (Up/Down to choose a row, A to act, B to go back):

| Row | Effect |
|---|---|
| **Terrain size** | Left/Right pick 128, 256 or 512 cells per side (a 64, 128 or 256 m field), A applies. Changing the size starts a new, untouched field. |
| **Slumping** | On: steep dirt slowly relaxes to a natural angle (about 33 degrees). Off: dirt stays exactly where you put it, so you can cut vertical-walled trenches. |
| **Reset position** | Puts the machine back in the middle of the field (the ground is kept). |
| **Reset terrain** | Erases all digging. Press A twice to confirm. |

### Saving

Everything is saved automatically: when you open the Menu, exit the game, or the device goes to sleep, and right after a terrain reset or size change. It restores the terrain edits, the machine's position, and the radio, arm, slumping and size settings. The files live in the game's Data folder (`terrain.bin` and `settings.json`). Only your edits are stored, so the terrain file is small (an edited field is typically well under 20 KB, an untouched one is about 100 bytes).

### Radio

- **Built-in stations:** *Gravel FM* (bright chiptune), *Hardhat Country* (boom-chick two-step) and *Night Shift* (slow, moody). They are original tunes written for this game as note data in [Source/radiodata.lua](Source/radiodata.lua) and played by the Playdate's synth sequencer.
- **Your own music:** any `.mp3` or `.pda` file in `Source/radio/` becomes a station named after the file (`.wav` and `.aiff` files there are converted to `.pda` when the game is built). You can also copy `.mp3` or `.pda` files into the game's `Data/com.playdategame.excavator/radio/` folder without rebuilding. The folder is read when the game starts. Only use audio you have the right to use.
- **Machine sounds:** the engine's pitch and loudness follow how hard you are working, and digging, spilling dirt, the blade and tipping over each make a sound. They play on top of the radio.

## How to play

- **Dig:** undock the crank, lower the arm, and leave the bucket open or half curled. The bucket removes dirt as the tip moves through the ground and fills up to 1.6 m3. The ground bottoms out on bedrock 3 m below the original surface.
- **Carry and dump:** tap A to curl the bucket closed so the dirt stays in, raise the arm, then hold A to spill it. Dirt is conserved: what you dig is what you can dump. A pile can't be higher than the bucket tip, so lift the arm to build taller hills.
- **Grade and build ramps:** hold B and drive forward. The blade levels the strip ahead of you into a smooth slope, so driving into a pile with the blade down turns it into a ramp. It moves dirt around rather than creating it, and never cuts steeper than about 29 degrees so ramps are always drivable.
- **Watch your tilt:** the dashboard gauge shows pitch and roll and a *TILT!* warning blinks near the limit. Slopes steeper than about 32 degrees (uphill) are blocked. Tilt past roughly 48 degrees nose/tail-down or 44 degrees sideways and the machine tips over; press B to reset.
- The edge of the field is a band of trees. You can't drive into it or dig in it.

## Building

Requirements (Windows):

- [Playdate SDK](https://play.date/dev/) 3.1.2 (default location `E:\Users\James\Documents\PlaydateSDK`, change it with `-Sdk`)
- [MSYS2](https://www.msys2.org) with the mingw64 toolchain:
  `pacman -S make mingw-w64-x86_64-cmake mingw-w64-x86_64-ninja mingw-w64-x86_64-arm-none-eabi-gcc mingw-w64-x86_64-arm-none-eabi-newlib`
- Python with Pillow (only for the host test frame converter)
- Optional: a standalone Lua interpreter for the radio data test (`pacman -S mingw-w64-x86_64-lua`)

```powershell
.\build.ps1              # simulator + device packages
.\build.ps1 -SimOnly -Run   # simulator only, then launch it
.\build.ps1 -HostTest    # run the terrain and radio test suites
```

Outputs:

- `Excavator.pdx`: for the Playdate Simulator.
- `Excavator_DEVICE.pdx`: for a real Playdate. Sideload it from the Playdate website's sideload page or with `pdutil` (it contains both the simulator DLL and the device binary).

Both are build products and are git-ignored.

## Project layout

```
Source/            Lua game code and the pdxinfo metadata (this folder becomes the .pdx)
  main.lua         entry point: loading and saving, system menu, per-frame loop
  excavator.lua    body: driving, terrain following, tilt, slope limits, tipping
  arm.lua          arm: crank/button input, kinematics, digging, dumping, arm drawing
  blade.lua        grade blade (B hold)
  view.lua         camera projection that matches the C renderer (for the arm overlay)
  cab.lua          cab frame, dashboard HUD and short notices
  settings.lua     the in-game Settings panel (terrain size, slumping, resets)
  radio.lua        the cab radio: built-in synth stations and your own audio files
  radiodata.lua    song data and the small note notation (plain Lua, testable on a PC)
  sfx.lua          engine and effect sounds
  radio/           drop-in folder for your own .mp3 / .pda stations
src/               C extension (compiled into pdex.dll / pdex.bin)
  terrain.h/.c     heightfield terrain: generation, dig/dump/grade/slump, save/load, renderer
  main.c           entry point and the Lua-callable `terrain` API
tools/
  hosttest.c       host-side test harness for the terrain core
  radiotest.lua    host-side checks of the radio song data
  raw2png.py       converts the harness's raw 1-bit frames to PNG
CMakeLists.txt     CMake project (used through build.ps1)
build.ps1          build and test script
```

## How it works

### Hybrid Lua + C

All game logic is Lua. The expensive parts, rendering the 3D ground and editing it, are a C extension that registers a global `terrain` table (see the header comment in [src/main.c](src/main.c) for the full list). Lua gets camera, dig, dump and grade calls; C draws straight into the Playdate's 1-bit frame buffer.

### Terrain and rendering

The world is a square grid of cells, 0.5 m each (default 256 x 256 = a 128 m field). A cell stores a height in centimeters, a material and a baked brightness (material plus slope lighting). Editing the ground is just changing heights, so there is no mesh to rebuild.

The renderer is a *voxel space* (Comanche style) raycaster:

1. For every screen column a ray marches outward over the terrain, with step size growing with distance.
2. At each step the ground height is projected to a screen row. If that row is above everything drawn so far, the newly visible strip of ground is filled in, dithered with an 8x8 Bayer matrix to fake grey levels.
3. Camera pitch moves the horizon and roll shears it across the screen.
4. Trees are billboards (three stacked cones on a trunk), sorted far to near and clipped against the terrain that was drawn in front of them.

Quality adapts automatically: six levels trade horizontal resolution and view distance, and the controller drops a level quickly when the frame cost is too high and raises it slowly when there is headroom. The dashboard shows the current level (Q0-Q5) and frame rate.

### Editing

| Operation | What it does |
|---|---|
| **Dig** | Carves a shallow bowl at the bucket tip, never below bedrock, never more than the bucket can hold. |
| **Dump** | Spreads dirt in a cone, never above the bucket tip or the global height cap. |
| **Grade** | Least-squares fits a straight ramp (along the heading, level side to side) through the blade strip and eases the ground towards it. The fit passes through the strip's mean height so dirt is redistributed, not created; slope is capped. Rounding is error-diffused so the total stays within half a centimeter. |
| **Slump** | Optional. Edited cells queue for relaxation; each frame a fixed budget of cells moves dirt to any neighbour that is more than 32 cm lower. Moving dirt between two cells conserves the total, and the bounded budget bounds the cost. |

Edits are confined to the field inside the tree band, so the ground under a tree trunk never changes.

### Physics

The tracks are a rectangle whose four corners sample the ground. The average gives body height and the corner differences give pitch and roll. Moving onto a slope that is too steep is refused, and exceeding the tipping angles tips the machine. The drawn camera pose is smoothed so bumpy ground doesn't jolt the view.

## Testing

`.\build.ps1 -HostTest` compiles the terrain core on the PC (no SDK needed) and runs checks for:

- dig stops at bedrock, respects bucket capacity and conserves volume
- dump matches what was dug and respects the height cap
- edits can't reach the tree band
- slumping obeys the angle of repose, conserves dirt exactly, and does nothing when off
- the grade blade conserves dirt, produces a ramp within the excavator's climb limit, and is level side to side
- saving and loading: the save is small, a save/load/save round trip is byte-identical, and stale (other size or seed), truncated, corrupt or missing files fall back to a clean field
- all three terrain sizes generate and can be dug

It also renders sample frames to `build/*.png` for a visual check and prints host render timings (which say nothing about device speed). If a `lua` interpreter is on the PATH it also runs `tools/radiotest.lua`, which checks that every station parses, uses defined voices, loops over whole bars and stays in a sensible note range.

The Lua game code itself (menus, saving, radio playback, sounds) is checked by running it in the Playdate Simulator.

## Performance and tuning

Real-device frame times are unknown until the game has been run on hardware. Use the Q and fps readout on the dashboard. If the device can't hold 30 fps:

- lower the draw distances or column resolution in the `QL` table in [src/terrain.c](src/terrain.c)
- lower `SLUMP_BUDGET` in [Source/main.lua](Source/main.lua)

Other tunable constants live at the top of each file: machine speed, slope limits and tipping angles in `excavator.lua`, arm geometry, bucket capacity and dig/dump radii in `arm.lua`, blade size and rate in `blade.lua`, repose angle and blade slope in `terrain.h`.

## Known limitations

- The arm is drawn over the scene, so a bucket below ground level still appears in front of it.
- The bucket is a simple box and the cab is a plain frame.
- Piles can look spiky with slumping off.
- With slumping on you can't keep a deep narrow hole open, since the walls collapse to a stable angle (turn slumping off in Settings for trenches).
- Radio stations from your own files are found when the game starts, so add them before launching. The menu list is fixed after that.
- A 512 cell field is the heaviest option. Its memory use is fine, but how well it runs on a real device is untested.
- The synth stations and machine sounds have been confirmed to start without errors in the simulator but have not been listened to critically or tuned.

## Roadmap

- [x] **Phase 1:** terrain renderer and driving
- [x] **Phase 2:** arm, dig and dump with limited bucket load
- [x] **Phase 3:** grade blade, ramps, optional slumping
- [x] **Phase 4:** system menu and settings (terrain size, resets, slumping, arm scheme, radio station), auto-save of terrain and position, and the cab radio
- [ ] Next: tune on real hardware, occlude the arm against the ground, a nicer bucket and cab
