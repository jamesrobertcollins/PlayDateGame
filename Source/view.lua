-- view.lua
--
-- A camera projection that matches the C terrain renderer exactly, so 3D overlays (the arm) line
-- up with the rendered ground. View.set receives the same camera the renderer used each frame;
-- FOCAL must equal FOCAL in src/terrain.c.
--
-- Conventions: yaw 0 looks along +x and positive yaw turns towards +y; screen is 400x240 with
-- the horizon at the centre when pitch and roll are zero.

View = {}

local FOCAL <const> = 230
local HALF_W <const> = 200
local HALF_H <const> = 120
local NEAR <const> = 0.35 -- closest distance that is drawn; nearer geometry is clipped or skipped

View.FOCAL = FOCAL
View.NEAR = NEAR

local camX, camY, camZ = 0, 0, 0
local cosY, sinY = 1, 0
local horBase, rollK = HALF_H, 0 -- horizon row at the screen centre, and its slope per pixel

-- Stores the camera for the projection calls below.
function View.set(x, y, z, yaw, pitch, roll)
	camX, camY, camZ = x, y, z
	cosY, sinY = math.cos(yaw), math.sin(yaw)
	horBase = HALF_H + FOCAL * math.tan(pitch)
	rollK = math.tan(roll)
end

-- Distance along the camera's forward axis (negative behind the camera).
function View.depth(wx, wy)
	return (wx - camX) * cosY + (wy - camY) * sinY
end

-- Projects a world point to screen x, y plus its depth. Callers must make sure depth >= NEAR
-- (the depth is clamped here only to avoid dividing by zero).
function View.project(wx, wy, wz)
	local dx, dy = wx - camX, wy - camY
	local d = dx * cosY + dy * sinY
	if d < NEAR then d = NEAR end
	local sx = HALF_W + (dx * sinY - dy * cosY) * FOCAL / d
	-- roll shears the horizon: screen y shifts in proportion to the distance from screen centre
	local sy = horBase - rollK * (sx - HALF_W) - (wz - camZ) * FOCAL / d
	return sx, sy, d
end

-- Projects segment a-b (each {x, y, z}) after clipping it to the near plane.
-- Returns sx1, sy1, sx2, sy2, midDepth, or nil if it is entirely behind the camera.
function View.projectSegment(a, b)
	local da, db = View.depth(a[1], a[2]), View.depth(b[1], b[2])
	if da < NEAR and db < NEAR then return nil end
	local ax, ay, az, bx, by, bz = a[1], a[2], a[3], b[1], b[2], b[3]
	if da < NEAR then
		local t = (NEAR - da) / (db - da) -- where the segment crosses the near plane
		ax, ay, az = ax + (bx - ax) * t, ay + (by - ay) * t, az + (bz - az) * t
	elseif db < NEAR then
		local t = (NEAR - db) / (da - db)
		bx, by, bz = bx + (ax - bx) * t, by + (ay - by) * t, bz + (az - bz) * t
	end
	local x1, y1, d1 = View.project(ax, ay, az)
	local x2, y2, d2 = View.project(bx, by, bz)
	return x1, y1, x2, y2, (d1 + d2) / 2
end
