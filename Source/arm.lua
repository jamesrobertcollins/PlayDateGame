-- arm.lua
--
-- The excavator arm: turns crank and A/B input into joint angles, runs the bucket (curl steps,
-- dump), digs and dumps through the terrain engine, and draws the arm in perspective (solid
-- shapes with face shading, hydraulic cylinders, and occlusion against the ground).
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
	self.digging, self.spilling = false, false -- this frame's dig / spill events (for sound)
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

	-- event flags for this frame, read by the sound effects
	self.digging, self.spilling = false, false

	if self.dumping then
		-- spill only once the bucket is tipped far enough, and never more than it holds
		if self.bucketAngle >= DUMP_THRESHOLD and self.load > 0 then
			local want = math.min(self.load, DUMP_RATE * dt)
			local dropped = terrain.dump(tx, ty, tz, DUMP_RADIUS, want)
			self.load -= dropped
			self.spilling = dropped > 0
			if self.load < 0.001 then self.load = 0 end
		end
	elseif self.curl < CURL_CLOSED and self.load < CAPACITY and self.prevTip then
		-- dig along the path the tip travelled this frame, in steps of at most DIG_STEP
		local px, py, pz = self.prevTip[1], self.prevTip[2], self.prevTip[3]
		local dist = math.sqrt((tx - px) ^ 2 + (ty - py) ^ 2 + (tz - pz) ^ 2)
		local steps = math.max(1, math.ceil(dist / DIG_STEP))
		for i = 1, steps do
			local t = i / steps
			local dug = terrain.dig(px + (tx - px) * t, py + (ty - py) * t, pz + (tz - pz) * t,
				DIG_RADIUS, CAPACITY - self.load)
			self.load += dug
			if dug > 0 then self.digging = true end
		end
	end
	self.prevTip = { tx, ty, tz }
end

-- ---------------------------------------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------------------------------------
--
-- The arm is built from solid shapes (tapered boxes for the boom and stick, a convex wedge for the
-- bucket) placed in the world with the body's pose, so they are projected with exactly the same
-- camera as the ground. Each shape is split into faces; back-facing faces are skipped and the rest
-- are filled with a dither shade and outlined. The parts are drawn in three groups (boom, stick,
-- bucket). Each group goes through a stencil that hides the pixels the ground in front of it
-- covers (terrain.occlusion, see src/terrain.c), so a bucket sunk into a pit disappears into it
-- instead of floating over the ground.

local BAYER <const> = gfx.image.kDitherTypeBayer8x8

local stencil = nil -- 400x240 white image that terrain.occlusion fills for each group

-- Link dimensions: half widths and thicknesses at each end (meters).
local BOOM_HALF_W, BOOM_T0, BOOM_T1 = 0.30, 0.55, 0.40
local STICK_HALF_W, STICK_T0, STICK_T1 = 0.22, 0.38, 0.28

-- Face shades as black coverage (0 = white, 1 = black): top, bottom, left side, right side. Dark
-- enough to stand out from the light grass, with the top face still the brightest.
local BOX_SHADES <const> = { 0.45, 0.88, 0.62, 0.74 }
-- Which corners make up each face of a link box (see linkCorners for the corner numbering).
local BOX_FACES <const> = { { 1, 2, 6, 5 }, { 3, 4, 8, 7 }, { 4, 1, 5, 8 }, { 2, 3, 7, 6 } }

-- The bucket's side profile in its own frame: x along the bucket axis (towards the tip), y
-- perpendicular to it (negative towards the heel). Convex, so face culling works on it.
-- Points: pivot, two points on the curved back, tip, heel, rear.
local PROFILE <const> = { { 0, 0 }, { 0.32, 0.10 }, { 0.65, 0.09 }, { 0.90, 0 }, { -0.095, -0.54 }, { -0.14, -0.22 } }
local BUCKET_EDGE_SHADES <const> = { 0.55, 0.55, 0.62, false, 0.88, 0.78 } -- false = the open mouth
local BUCKET_PLATE_SHADE <const> = 0.65
local TEETH <const> = 4

-- Body-plane point {f, u} on the link a-b: fraction s along it, offset off to its "up" side.
local function onLink(a, b, s, off)
	local df, du = b[1] - a[1], b[2] - a[2]
	local len = math.sqrt(df * df + du * du)
	return { a[1] + df * s - du / len * off, a[2] + du * s + df / len * off }
end

-- A group collects the draw operations of several parts plus their combined screen bounds and
-- mean depth, which select the occlusion stencil.
local function newGroup()
	return { recs = {}, dsum = 0, dn = 0, x0 = math.huge, y0 = math.huge, x1 = -math.huge, y1 = -math.huge }
end

local function grow(g, d, x0, y0, x1, y1)
	g.dsum += d
	g.dn += 1
	if x0 < g.x0 then g.x0 = x0 end
	if y0 < g.y0 then g.y0 = y0 end
	if x1 > g.x1 then g.x1 = x1 end
	if y1 > g.y1 then g.y1 = y1 end
end

-- Adds a world-space polygon (list of {x, y, z}) filled with the given black coverage.
local function addPoly(g, points, shade)
	local flat, d, x0, y0, x1, y1 = View.projectPolygon(points)
	if not flat then return end
	g.recs[#g.recs + 1] = { flat = flat, shade = shade }
	grow(g, d, x0, y0, x1, y1)
end

-- Adds a thick line between two world points; width is in meters at the line's depth.
local function addLine(g, a, b, width)
	local x1, y1, x2, y2, d = View.projectSegment(a, b)
	if not x1 then return end
	local px = clamp(math.floor(width * View.FOCAL / d), 2, 9)
	g.recs[#g.recs + 1] = { line = { x1, y1, x2, y2 }, width = px }
	grow(g, d, math.min(x1, x2) - px, math.min(y1, y2) - px, math.max(x1, x2) + px, math.max(y1, y2) + px)
end

local function addDot(g, p, radius)
	if View.depth(p[1], p[2]) < View.NEAR then return end
	local sx, sy, d = View.project(p[1], p[2], p[3])
	g.recs[#g.recs + 1] = { dot = { sx, sy }, radius = radius }
	grow(g, d, sx - radius, sy - radius, sx + radius, sy + radius)
end

-- True if a face of a convex solid points towards the camera. The face normal comes from its
-- first three points and is flipped to point away from the solid's centre `c`.
local function facesCamera(pts, c)
	local a, b, p3 = pts[1], pts[2], pts[3]
	local ux, uy, uz = b[1] - a[1], b[2] - a[2], b[3] - a[3]
	local vx, vy, vz = p3[1] - a[1], p3[2] - a[2], p3[3] - a[3]
	local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
	local fx, fy, fz = 0, 0, 0
	for _, p in ipairs(pts) do
		fx += p[1]; fy += p[2]; fz += p[3]
	end
	fx, fy, fz = fx / #pts, fy / #pts, fz / #pts
	if nx * (fx - c[1]) + ny * (fy - c[2]) + nz * (fz - c[3]) < 0 then
		nx, ny, nz = -nx, -ny, -nz
	end
	local camX, camY, camZ = View.cameraPosition()
	return nx * (camX - fx) + ny * (camY - fy) + nz * (camZ - fz) > 0
end

local function centreOf(points)
	local x, y, z = 0, 0, 0
	for _, p in ipairs(points) do
		x += p[1]; y += p[2]; z += p[3]
	end
	return { x / #points, y / #points, z / #points }
end

-- World corners of a tapered link box from body-plane point a to b: thickness ta at a and tb at
-- b, half width w. Corners 1-4 are at a (top +l, top -l, bottom -l, bottom +l), 5-8 the same at b.
local function linkCorners(ex, a, b, ta, tb, w)
	local df, du = b[1] - a[1], b[2] - a[2]
	local len = math.sqrt(df * df + du * du)
	local nf, nu = -du / len, df / len
	local function corner(pt, t, side, l)
		return { toWorld(ex, pt[1] + nf * t * side / 2, l, pt[2] + nu * t * side / 2) }
	end
	return {
		corner(a, ta, 1, w), corner(a, ta, 1, -w), corner(a, ta, -1, -w), corner(a, ta, -1, w),
		corner(b, tb, 1, w), corner(b, tb, 1, -w), corner(b, tb, -1, -w), corner(b, tb, -1, w),
	}
end

local function addBox(g, corners)
	local c = centreOf(corners)
	for i, f in ipairs(BOX_FACES) do
		local face = { corners[f[1]], corners[f[2]], corners[f[3]], corners[f[4]] }
		if facesCamera(face, c) then addPoly(g, face, BOX_SHADES[i]) end
	end
end

-- Draws a group's operations through the ground-occlusion stencil.
local function drawGroup(g)
	if #g.recs == 0 then return end
	stencil = stencil or gfx.image.new(400, 240, gfx.kColorWhite)
	terrain.occlusion(stencil, g.dsum / g.dn,
		math.floor(g.x0) - 4, math.floor(g.y0) - 4, math.ceil(g.x1) + 4, math.ceil(g.y1) + 4)
	gfx.setStencilImage(stencil)

	for _, r in ipairs(g.recs) do
		if r.flat then
			gfx.setColor(gfx.kColorWhite)
			gfx.fillPolygon(table.unpack(r.flat))
			if r.shade > 0 then
				gfx.setColor(gfx.kColorBlack)
				-- the dither value is how transparent the fill is (measured on SDK 3.1.2: 0.1 is
				-- nearly solid, 0.9 nearly clear), so black coverage `shade` is 1 - shade
				gfx.setDitherPattern(1 - r.shade, BAYER)
				gfx.fillPolygon(table.unpack(r.flat))
			end
			gfx.setColor(gfx.kColorBlack)
			gfx.drawPolygon(table.unpack(r.flat))
		elseif r.line then
			-- a hydraulic cylinder: dark body with a bright rod down the middle
			local l = r.line
			gfx.setColor(gfx.kColorBlack)
			gfx.setLineWidth(r.width)
			gfx.drawLine(l[1], l[2], l[3], l[4])
			if r.width >= 4 then
				gfx.setColor(gfx.kColorWhite)
				gfx.setLineWidth(math.max(1, r.width // 3))
				gfx.drawLine(l[1], l[2], l[3], l[4])
			end
		else
			gfx.setColor(gfx.kColorBlack)
			gfx.fillCircleAtPoint(r.dot[1], r.dot[2], r.radius)
		end
	end

	gfx.setLineWidth(1)
	gfx.clearStencil()
	gfx.setColor(gfx.kColorBlack)
end

-- Draws boom, stick, bucket, cylinders and any falling dirt over the 3D view.
function Arm:draw(ex)
	local p0, p1, p2, tip = self:localPoints()
	local function world(p, l) return { toWorld(ex, p[1], l or 0, p[2]) } end

	-- boom: a tapered box with the boom cylinder running from the body up onto it
	local boom = newGroup()
	addBox(boom, linkCorners(ex, p0, p1, BOOM_T0, BOOM_T1, BOOM_HALF_W))
	addLine(boom, world({ PIVOT_F - 0.45, PIVOT_U + 0.45 }), world(onLink(p0, p1, 0.34, BOOM_T0 / 2 + 0.06)), 0.14)

	-- stick, with the stick cylinder from the top of the boom
	local stick = newGroup()
	addBox(stick, linkCorners(ex, p1, p2, STICK_T0, STICK_T1, STICK_HALF_W))
	addLine(stick, world(onLink(p0, p1, 0.66, BOOM_T1 / 2 + 0.08)), world(onLink(p1, p2, 0.22, STICK_T0 / 2 + 0.06)), 0.11)

	-- bucket: side plates, curved back, open mouth and teeth, plus its cylinder
	local bucket = newGroup()
	local a3 = math.atan(tip[2] - p2[2], tip[1] - p2[1])
	local ca, sa = math.cos(a3), math.sin(a3)
	local function bpt(x, y, l)
		return { toWorld(ex, p2[1] + x * ca - y * sa, l, p2[2] + x * sa + y * ca) }
	end
	local hw = BUCKET_HALF_WIDTH
	local left, right = {}, {}
	for i, pr in ipairs(PROFILE) do
		left[i] = bpt(pr[1], pr[2], hw)
		right[i] = bpt(pr[1], pr[2], -hw)
	end
	local all = {}
	for i = 1, #PROFILE do
		all[#all + 1] = left[i]
		all[#all + 1] = right[i]
	end
	local c = centreOf(all)

	if facesCamera(left, c) then addPoly(bucket, left, BUCKET_PLATE_SHADE) end
	if facesCamera(right, c) then addPoly(bucket, right, BUCKET_PLATE_SHADE) end
	for i = 1, #PROFILE do
		local j = i % #PROFILE + 1
		local face = { left[i], left[j], right[j], right[i] }
		if facesCamera(face, c) then
			local shade = BUCKET_EDGE_SHADES[i]
			if shade == false then
				-- the open mouth: a dark cavity when empty, dirt-coloured when loaded
				shade = 0.88 - 0.38 * math.min(1, self.load / CAPACITY)
			end
			addPoly(bucket, face, shade)
		end
	end
	for k = 1, TEETH do
		local l = -hw + (k - 0.5) * (2 * hw / TEETH)
		addPoly(bucket, { bpt(0.90, 0, l - 0.07), bpt(0.90, 0, l + 0.07), bpt(1.08, -0.04, l) }, 1)
	end
	addLine(bucket, world(onLink(p1, p2, 0.74, STICK_T1 / 2 + 0.07)), bpt(0.28, 0.12, 0), 0.10)

	-- a few falling specks under the bucket while it is spilling
	if self.dumping and self.bucketAngle >= DUMP_THRESHOLD and self.load > 0 then
		for k = 1, 6 do
			local jitter = ((self.clock * 9 + k * 1.7) % 1) - 0.5
			addDot(bucket, { self.tip[1] + jitter * 0.3, self.tip[2], self.tip[3] - k * 0.35 - (self.clock * 6 % 0.35) },
				2)
		end
	end

	drawGroup(boom)
	drawGroup(stick)
	drawGroup(bucket)
end
