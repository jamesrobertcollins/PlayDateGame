-- Camera projection that matches the C terrain renderer exactly, so 3D overlays (the arm)
-- line up with the rendered ground. FOCAL must equal FOCAL in terrain.c.

View = {}

local FOCAL <const> = 230
local HALF_W <const> = 200
local HALF_H <const> = 120
local NEAR <const> = 0.35

View.FOCAL = FOCAL
View.NEAR = NEAR

local camX, camY, camZ = 0, 0, 0
local cosY, sinY = 1, 0
local horBase, rollK = HALF_H, 0

function View.set(x, y, z, yaw, pitch, roll)
	camX, camY, camZ = x, y, z
	cosY, sinY = math.cos(yaw), math.sin(yaw)
	horBase = HALF_H + FOCAL * math.tan(pitch)
	rollK = math.tan(roll)
end

-- Distance along the camera's forward axis.
function View.depth(wx, wy)
	return (wx - camX) * cosY + (wy - camY) * sinY
end

-- Returns screen x, y and depth. Callers must make sure depth >= NEAR.
function View.project(wx, wy, wz)
	local dx, dy = wx - camX, wy - camY
	local d = dx * cosY + dy * sinY
	if d < NEAR then d = NEAR end
	local sx = HALF_W + (dx * sinY - dy * cosY) * FOCAL / d
	local sy = horBase - rollK * (sx - HALF_W) - (wz - camZ) * FOCAL / d
	return sx, sy, d
end

-- Projects segment a-b (each {x, y, z}) after clipping it to the near plane.
-- Returns sx1, sy1, sx2, sy2, midDepth or nil if it is entirely behind the camera.
function View.projectSegment(a, b)
	local da, db = View.depth(a[1], a[2]), View.depth(b[1], b[2])
	if da < NEAR and db < NEAR then return nil end
	local ax, ay, az, bx, by, bz = a[1], a[2], a[3], b[1], b[2], b[3]
	if da < NEAR then
		local t = (NEAR - da) / (db - da)
		ax, ay, az = ax + (bx - ax) * t, ay + (by - ay) * t, az + (bz - az) * t
	elseif db < NEAR then
		local t = (NEAR - db) / (da - db)
		bx, by, bz = bx + (ax - bx) * t, by + (ay - by) * t, bz + (az - bz) * t
	end
	local x1, y1, d1 = View.project(ax, ay, az)
	local x2, y2, d2 = View.project(bx, by, bz)
	return x1, y1, x2, y2, (d1 + d2) / 2
end
