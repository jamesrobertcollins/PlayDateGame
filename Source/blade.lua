-- blade.lua
--
-- The grade blade: hold B (longer than a tap) and a blade at the front of the tracks levels and
-- smooths the ground ahead of the machine. Driving forward with it down turns piles and lips
-- into clean ramps (the maths lives in terrain_grade in src/terrain.c).
--
-- A quick B tap is not a hold, so it still works for the arm's joint switch (see arm.lua).

import "arm" -- for Arm.TAP_TIME, the tap/hold threshold shared by A and B

Blade = {}
Blade.__index = Blade

-- The graded strip starts just past the front of the tracks (their half length is 1.7 m).
local BLADE_START <const> = 1.9
local BLADE_LENGTH <const> = 4.5      -- meters along the heading
local BLADE_HALF_WIDTH <const> = 1.6  -- a little wider than the 2.6 m track gauge
local BLADE_RATE <const> = 5          -- how quickly cells move to the target, per second

function Blade.new()
	local self = setmetatable({}, Blade)
	self:reset()
	return self
end

function Blade:reset()
	self.heldFor = 0     -- seconds B has been held continuously
	self.active = false  -- true while the blade is cutting (read by the HUD)
end

-- Call once per frame after the excavator has moved.
function Blade:update(dt, ex)
	if playdate.buttonIsPressed(playdate.kButtonB) then
		self.heldFor += dt
	else
		self.heldFor = 0
	end
	self.active = self.heldFor > Arm.TAP_TIME and not ex.tipped
	if not self.active then
		return
	end

	local c, s = math.cos(ex.yaw), math.sin(ex.yaw)
	local mid = BLADE_START + BLADE_LENGTH / 2
	-- frame-rate independent blend factor: the same ground speed at 20, 30 or 50 fps
	local blend = 1 - math.exp(-BLADE_RATE * dt)
	terrain.grade(ex.x + c * mid, ex.y + s * mid, ex.yaw, BLADE_LENGTH / 2, BLADE_HALF_WIDTH, blend)
end
