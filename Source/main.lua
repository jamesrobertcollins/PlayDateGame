-- main.lua
--
-- Entry point. Creates the field, the excavator, arm and blade, adds the system-menu options,
-- and runs the per-frame loop. Rendering and terrain edits are native (the `terrain` table is
-- provided by the C extension in src/main.c); everything else is Lua.

import "CoreLibs/graphics"
import "CoreLibs/ui"
import "excavator"
import "arm"
import "blade"
import "cab"

local TERRAIN_SIZE <const> = 256   -- cells per side (0.5 m each, so a 128 m field)
local TERRAIN_SEED <const> = 12345
local SLUMP_BUDGET <const> = 48    -- slump cells relaxed per frame; bounds the cost

playdate.display.setRefreshRate(30)

terrain.init(TERRAIN_SIZE, TERRAIN_SEED)
terrain.setSlumping(true)

local excavator = Excavator.new()
local arm = Arm.new()
local blade = Blade.new()
local lastMs = playdate.getCurrentTimeMilliseconds()

-- System menu (the Menu button): choose how the crank drives the arm, and toggle slumping.
local menu = playdate.getSystemMenu()
menu:addOptionsMenuItem("Arm", { "Arc", "Joints" }, "Arc", function(choice)
	arm:setScheme(choice == "Arc" and Arm.SCHEME_ARC or Arm.SCHEME_JOINTS)
end)
menu:addCheckmarkMenuItem("Slumping", true, function(enabled)
	terrain.setSlumping(enabled)
end)

-- shows the "turn the crank" prompt whenever the crank is docked
playdate.ui.crankIndicator:start()

function playdate.update()
	-- real frame time, capped so a long stall can't launch the machine across the field
	local now = playdate.getCurrentTimeMilliseconds()
	local dt = math.min((now - lastMs) / 1000, 0.1)
	lastMs = now

	if excavator.tipped and playdate.buttonJustPressed(playdate.kButtonB) then
		excavator:reset()
		arm:reset()
		blade:reset()
	end

	excavator:update(dt)
	if not excavator.tipped then
		arm:update(dt, excavator)
		blade:update(dt, excavator)
	end
	terrain.slump(SLUMP_BUDGET)

	-- draw: ground first, then the arm and cab over it
	local x, y, z, yaw, pitch, roll = excavator:camera()
	terrain.render(x, y, z, yaw, pitch, roll)
	View.set(x, y, z, yaw, pitch, roll)
	arm:draw(excavator)
	Cab.draw(excavator, arm, blade)

	if playdate.isCrankDocked() then
		playdate.ui.crankIndicator:draw()
	end
end
