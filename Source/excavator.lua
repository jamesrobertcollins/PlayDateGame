-- Excavator body: driving, terrain following, tilt and tipping.

Excavator = {}
Excavator.__index = Excavator

local TRACK_LEN, TRACK_GAUGE = 3.4, 2.6
local MAX_SPEED, ACCEL = 3.5, 7.0
local TURN_RATE = 1.1
local EYE_HEIGHT = 2.3
local EYE_FORWARD = 0.5
local CAM_PITCH = -0.30

-- Slope rules (radians)
local CLIMB_MAX = math.rad(32)  -- steeper uphill is blocked
local ROLL_BLOCK = math.rad(38) -- driving onto a steeper side slope is blocked
local TIP_PITCH = math.rad(48)  -- nose/tail-down beyond this tips the machine
local TIP_ROLL = math.rad(44)
Excavator.WARN_FRACTION = 0.7

local EDGE_MARGIN = 10.0 -- keeps the machine out of the tree band

local function samplePose(x, y, yaw)
	local c, s = math.cos(yaw), math.sin(yaw)
	local hl, hw = TRACK_LEN / 2, TRACK_GAUGE / 2
	local function h(f, l)
		return terrain.height(x + c * f - s * l, y + s * f + c * l)
	end
	local fl, fr, bl, br = h(hl, hw), h(hl, -hw), h(-hl, hw), h(-hl, -hw)
	local z = (fl + fr + bl + br) / 4
	local pitch = math.atan((fl + fr - bl - br) / 2, TRACK_LEN)
	local roll = math.atan((fl + bl - fr - br) / 2, TRACK_GAUGE) -- positive: right side down
	return z, pitch, roll
end

function Excavator.new()
	local self = setmetatable({}, Excavator)
	self:reset()
	return self
end

function Excavator:reset()
	local world = terrain.worldSize()
	self.x, self.y = world / 2, world / 2
	self.yaw = 0
	self.speed = 0
	self.tipped = false
	self.z, self.pitch, self.roll = samplePose(self.x, self.y, self.yaw)
	self.vz, self.vpitch, self.vroll = self.z, self.pitch, self.roll
end

function Excavator:update(dt)
	if self.tipped then
		return
	end

	local turn = 0
	if playdate.buttonIsPressed(playdate.kButtonLeft) then turn += 1 end
	if playdate.buttonIsPressed(playdate.kButtonRight) then turn -= 1 end
	local drive = 0
	if playdate.buttonIsPressed(playdate.kButtonUp) then drive += 1 end
	if playdate.buttonIsPressed(playdate.kButtonDown) then drive -= 1 end

	self.yaw += turn * TURN_RATE * dt

	local target = drive * MAX_SPEED
	if self.speed < target then
		self.speed = math.min(target, self.speed + ACCEL * dt)
	elseif self.speed > target then
		self.speed = math.max(target, self.speed - ACCEL * dt)
	end

	local world = terrain.worldSize()
	local nx = self.x + math.cos(self.yaw) * self.speed * dt
	local ny = self.y + math.sin(self.yaw) * self.speed * dt
	nx = math.max(EDGE_MARGIN, math.min(world - EDGE_MARGIN, nx))
	ny = math.max(EDGE_MARGIN, math.min(world - EDGE_MARGIN, ny))

	local z, pitch, roll = samplePose(nx, ny, self.yaw)
	local dir = self.speed >= 0 and 1 or -1
	local moved = nx ~= self.x or ny ~= self.y
	if moved and (pitch * dir > CLIMB_MAX or math.abs(roll) > ROLL_BLOCK) then
		-- too steep to climb: stay put
		self.speed = 0
		z, pitch, roll = samplePose(self.x, self.y, self.yaw)
	else
		self.x, self.y = nx, ny
	end
	self.z, self.pitch, self.roll = z, pitch, roll

	if math.abs(pitch) > TIP_PITCH or math.abs(roll) > TIP_ROLL then
		self.tipped = true
		self.speed = 0
	end

	local k = math.min(1, dt * 8)
	self.vz += (self.z - self.vz) * k
	self.vpitch += (self.pitch - self.vpitch) * k
	self.vroll += (self.roll - self.vroll) * k
end

-- Fraction (0..1+) of the way to tipping over; used for the HUD warning.
function Excavator:tiltRatio()
	return math.max(math.abs(self.pitch) / TIP_PITCH, math.abs(self.roll) / TIP_ROLL)
end

function Excavator:camera()
	local c, s = math.cos(self.yaw), math.sin(self.yaw)
	return self.x + c * EYE_FORWARD, self.y + s * EYE_FORWARD, self.vz + EYE_HEIGHT,
		self.yaw, self.vpitch + CAM_PITCH, self.vroll
end
