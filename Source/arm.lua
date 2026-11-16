-- arm.lua
--
-- The excavator arm: turns crank and A/B input into joint angles, runs the bucket (curl steps,
-- dump), digs and dumps through the terrain engine, and draws the arm in perspective.
--
-- Input
--   crank   sets the arm position directly (absolute), with eased end stops
--   A tap   steps the bucket curl: open -> half -> closed -> open
--   A hold  dumps the load (see TAP_TIME)
--   B tap   in the "Joints" scheme, switches the joint the crank controls (boom <-> stick)
--
-- Two control schemes (menu option "Arm"):
--   Arc     the crank drives boom and stick together along a preset digging arc
--   Joints  the crank drives one joint at a time, switched with a B tap

import "view"

Arm = {}
Arm.__index = Arm

local gfx <const> = playdate.graphics
local rad <const> = math.rad

-- Geometry in the body's vertical plane: f = forward, u = up (from the track ground contact).
local PIVOT_F, PIVOT_U = 1.0, 1.3                      -- boom pivot on the body
local BOOM_LEN, STICK_LEN, BUCKET_LEN = 3.6, 2.2, 0.9  -- link lengths, meters
local BUCKET_HALF_WIDTH = 0.6
local HEEL_LEN = 0.55                                  -- distance from the stick end to the bucket's rear edge

-- Bucket angle relative to the stick for each curl step, and for dumping.
local CURL_ANGLES <const> = { rad(40), rad(5), rad(-35) } -- open, half, fully curled
local CURL_CLOSED <const> = 3                              -- index of the fully curled step
local DUMP_ANGLE <const> = rad(110)
local DUMP_THRESHOLD <const> = rad(80)                     -- bucket must tilt past this to spill

local CAPACITY <const> = 1.6   -- bucket volume, m^3
local DUMP_RATE <const> = 1.2  -- m^3 released per second while dumping
local DIG_RADIUS <const> = 0.7
local DUMP_RADIUS <const> = 1.2
local DIG_STEP <const> = 0.35  -- max tip travel between dig samples, so fast swings don't skip ground

local JOINT_SPEED <const> = 1.6  -- boom/stick travel (fraction of full range) per second
local BUCKET_SPEED <const> = 3.5 -- bucket rotation, rad/s
local TAP_TIME <const> = 0.25    -- a button held longer than this is a "hold", not a tap

local CRANK_RANGE <const> = 300 -- degrees of crank that cover the full stroke

Arm.SCHEME_ARC, Arm.SCHEME_JOINTS = 1, 2
Arm.TAP_TIME = TAP_TIME

local function clamp(v, lo, hi)
	return math.max(lo, math.min(hi, v))
end

-- Crank angle (0..360) -> arm position 0..1, with eased (smoothstep-blended) end stops.
-- The crank has no physical stops, so the unused part of the circle past CRANK_RANGE snaps to
-- the nearer end instead of whipping the arm across its whole range.
local function crankMap(angle)
	local s
	if angle <= CRANK_RANGE then
		s = angle / CRANK_RANGE
	elseif angle >= (CRANK_RANGE + 360) / 2 then
		s = 0
	else
		s = 1
	end
	return 0.5 * s + 0.5 * s * s * (3 - 2 * s)
end

-- Moves v towards target by at most maxStep.
local function approach(v, target, maxStep)
	if v < target then return math.min(target, v + maxStep) end
	return math.max(target, v - maxStep)
end

function Arm.new()
	local self = setmetatable({}, Arm)
	self.scheme = Arm.SCHEME_ARC
	self:reset()
	return self
end

function Arm:reset()
	self.boom, self.stick = 0, 0           -- current joint positions, 0..1
	self.boomTarget, self.stickTarget = 0, 0
	self.active = 1                        -- joint the crank drives in the joints scheme (1 boom, 2 stick)
	self.crankOffset = 0                   -- keeps a joint from jumping when the crank is re-assigned
	self.curl = 1                          -- index into CURL_ANGLES
	self.bucketAngle = CURL_ANGLES[1]
	self.load = 0                          -- dirt in the bucket, m^3
	self.dumping = false
	self.clock = 0                         -- seconds, for tap/hold timing and effects
	self.aDown, self.bDown = 0, 0          -- clock value when A / B were pressed
	self.prevTip = nil                     -- previous bucket tip position, for continuous digging
end

function Arm:setScheme(scheme)
	if scheme == self.scheme then return end
	self.scheme = scheme
	if scheme == Arm.SCHEME_ARC then
		self.stick, self.stickTarget = self.boom, self.boomTarget
	else
		self.active = 1
		self.crankOffset = self.boom - crankMap(playdate.getCrankPosition())
	end
end

-- Boom angle and stick angle (relative to the boom) for the current scheme.
local function jointAngles(scheme, boom, stick)
	if scheme == Arm.SCHEME_ARC then
		return rad(35 - 60 * boom), rad(-40 - 40 * boom)
	end
	return rad(50 - 90 * boom), rad(-20 - 80 * stick)
end

-- Joint positions as {f, u} pairs in the body plane:
-- pivot, boom end, stick end, bucket tip, bucket heel.
function Arm:localPoints()
	local a1, rel = jointAngles(self.scheme, self.boom, self.stick)
	local a2 = a1 + rel
	local a3 = a2 + self.bucketAngle
	local p0 = { PIVOT_F, PIVOT_U }
	local p1 = { p0[1] + BOOM_LEN * math.cos(a1), p0[2] + BOOM_LEN * math.sin(a1) }
	local p2 = { p1[1] + STICK_LEN * math.cos(a2), p1[2] + STICK_LEN * math.sin(a2) }
	local tip = { p2[1] + BUCKET_LEN * math.cos(a3), p2[2] + BUCKET_LEN * math.sin(a3) }
	local heel = { p2[1] + HEEL_LEN * math.cos(a3 - rad(100)), p2[2] + HEEL_LEN * math.sin(a3 - rad(100)) }
	return p0, p1, p2, tip, heel
end

-- Body-plane point (f forward, l lateral to the left, u up) -> world x, y, z, using the body's
-- smoothed pose (visual pitch and height) so the arm sits on the ground it is drawn over.
local function toWorld(ex, f, l, u)
	local cp, sp = math.cos(ex.vpitch), math.sin(ex.vpitch)
	local ff, uu = f * cp - u * sp, f * sp + u * cp
	local c, s = math.cos(ex.yaw), math.sin(ex.yaw)
	return ex.x + c * ff - s * l, ex.y + s * ff + c * l, ex.vz + uu
end

-- Reads the buttons and crank and updates the joint targets and bucket mode.
function Arm:updateInput(dt)
	self.clock += dt

	if playdate.buttonJustPressed(playdate.kButtonA) then self.aDown = self.clock end
	if playdate.buttonJustPressed(playdate.kButtonB) then self.bDown = self.clock end

	-- hold A past TAP_TIME = dump; releasing A before then was a tap = next curl step
	self.dumping = playdate.buttonIsPressed(playdate.kButtonA) and (self.clock - self.aDown) > TAP_TIME
	if playdate.buttonJustReleased(playdate.kButtonA) and (self.clock - self.aDown) <= TAP_TIME then
		self.curl = self.curl % CURL_CLOSED + 1
	end

	if playdate.buttonJustReleased(playdate.kButtonB) and (self.clock - self.bDown) <= TAP_TIME
		and self.scheme == Arm.SCHEME_JOINTS then
		-- switch the joint under crank control; it keeps its current position
		self.active = 3 - self.active
		local current = self.active == 1 and self.boom or self.stick
		self.crankOffset = current - crankMap(playdate.getCrankPosition())
	end

	-- the crank is only read while undocked; the arm simply holds still otherwise
	if playdate.isCrankDocked() then return end

	local mapped = crankMap(playdate.getCrankPosition())
	if self.scheme == Arm.SCHEME_ARC then
		self.boomTarget, self.stickTarget = mapped, mapped
	else
		local v = clamp(mapped + self.crankOffset, 0, 1)
		if self.active == 1 then self.boomTarget = v else self.stickTarget = v end
	end
end

-- Advances the arm one frame and applies digging or dumping at the bucket tip.
function Arm:update(dt, ex)
	self:updateInput(dt)

	-- joints chase their targets at a limited speed so the crank never makes the arm jump
	self.boom = approach(self.boom, self.boomTarget, JOINT_SPEED * dt)
	self.stick = approach(self.stick, self.stickTarget, JOINT_SPEED * dt)
	local bucketTarget = self.dumping and DUMP_ANGLE or CURL_ANGLES[self.curl]
	self.bucketAngle = approach(self.bucketAngle, bucketTarget, BUCKET_SPEED * dt)

	local _, _, _, tip = self:localPoints()
	local tx, ty, tz = toWorld(ex, tip[1], 0, tip[2])
	self.tip = { tx, ty, tz }

	if self.dumping then
		-- spill only once the bucket is tipped far enough, and never more than it holds
		if self.bucketAngle >= DUMP_THRESHOLD and self.load > 0 then
			local want = math.min(self.load, DUMP_RATE * dt)
			self.load -= terrain.dump(tx, ty, tz, DUMP_RADIUS, want)
			if self.load < 0.001 then self.load = 0 end
		end
	elseif self.curl < CURL_CLOSED and self.load < CAPACITY and self.prevTip then
		-- dig along the path the tip travelled this frame, in steps of at most DIG_STEP
		local px, py, pz = self.prevTip[1], self.prevTip[2], self.prevTip[3]
		local dist = math.sqrt((tx - px) ^ 2 + (ty - py) ^ 2 + (tz - pz) ^ 2)
		local steps = math.max(1, math.ceil(dist / DIG_STEP))
		for i = 1, steps do
			local t = i / steps
			self.load += terrain.dig(px + (tx - px) * t, py + (ty - py) * t, pz + (tz - pz) * t,
				DIG_RADIUS, CAPACITY - self.load)
		end
	end
	self.prevTip = { tx, ty, tz }
end

-- Draws a boom or stick as a thick black line with a white outline. The width shrinks with depth
-- so near parts of the arm look bigger.
local function drawBeam(a, b, width)
	local x1, y1, x2, y2, depth = View.projectSegment(a, b)
	if not x1 then return end
	local px = clamp(math.floor(width * View.FOCAL / depth), 3, 44)
	gfx.setColor(gfx.kColorWhite)
	gfx.setLineWidth(px + 3)
	gfx.drawLine(x1, y1, x2, y2)
	gfx.setColor(gfx.kColorBlack)
	gfx.setLineWidth(px)
	gfx.drawLine(x1, y1, x2, y2)
	gfx.setLineWidth(1)
end

-- Projects four world points to a flat list of screen coordinates for fillPolygon, or nil if any
-- point is behind the near plane (such a quad is skipped rather than clipped).
local function projectQuad(p1, p2, p3, p4)
	local pts = {}
	for _, p in ipairs({ p1, p2, p3, p4 }) do
		if View.depth(p[1], p[2]) < View.NEAR then return nil end
		local sx, sy = View.project(p[1], p[2], p[3])
		pts[#pts + 1] = sx
		pts[#pts + 1] = sy
	end
	return pts
end

local function fillQuad(pts, outline)
	gfx.setColor(gfx.kColorWhite)
	gfx.fillPolygon(table.unpack(pts))
	if outline then
		gfx.setColor(gfx.kColorBlack)
		gfx.setLineWidth(2)
		gfx.drawPolygon(table.unpack(pts))
		gfx.setLineWidth(1)
	end
end

-- Draws boom, stick, bucket and any falling dirt over the 3D view.
function Arm:draw(ex)
	local p0, p1, p2, tip, heel = self:localPoints()
	local function w(p, l) return { toWorld(ex, p[1], l or 0, p[2]) } end

	drawBeam(w(p0), w(p1), 0.55)
	drawBeam(w(p1), w(p2), 0.42)

	local hw = BUCKET_HALF_WIDTH
	-- the bucket's outer shell (black) first, then its open mouth on top
	local shell = projectQuad(w(p2, hw), w(tip, hw), w(tip, -hw), w(p2, -hw))
	if shell then
		gfx.setColor(gfx.kColorBlack)
		gfx.fillPolygon(table.unpack(shell))
		gfx.setColor(gfx.kColorWhite)
		gfx.setLineWidth(1)
		gfx.drawPolygon(table.unpack(shell))
	end
	local mouth = projectQuad(w(heel, hw), w(tip, hw), w(tip, -hw), w(heel, -hw))
	if mouth then
		fillQuad(mouth, true)
		-- with black selected the dither alpha is black coverage: light when empty, dark when full
		gfx.setColor(gfx.kColorBlack)
		gfx.setDitherPattern(0.2 + 0.6 * self.load / CAPACITY, gfx.image.kDitherTypeBayer8x8)
		gfx.fillPolygon(table.unpack(mouth))
		gfx.setColor(gfx.kColorBlack)
	end

	-- a few falling specks under the bucket while it is spilling
	if self.dumping and self.bucketAngle >= DUMP_THRESHOLD and self.load > 0 then
		gfx.setColor(gfx.kColorBlack)
		for k = 1, 6 do
			local jitter = ((self.clock * 9 + k * 1.7) % 1) - 0.5
			local x, y, z = self.tip[1], self.tip[2], self.tip[3] - k * 0.35 - (self.clock * 6 % 0.35)
			if View.depth(x, y) >= View.NEAR then
				local sx, sy = View.project(x, y, z)
				gfx.fillCircleAtPoint(sx + jitter * 8, sy, 2)
			end
		end
	end
	gfx.setColor(gfx.kColorBlack)
end
