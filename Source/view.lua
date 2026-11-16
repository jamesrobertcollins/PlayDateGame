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

-- The camera position set by View.set (used to decide which faces of a solid face the viewer).
function View.cameraPosition()
	return camX, camY, camZ
end

-- Clips a polygon (a list of {x, y, z} world points) to the near plane and projects it.
-- Returns a flat list of screen coordinates {x1, y1, x2, y2, ...} ready for fillPolygon, plus the
-- polygon's mean depth and its screen bounds (minX, minY, maxX, maxY); or nil if nothing is left
-- in front of the camera.
function View.projectPolygon(points)
	local n = #points
	local kept = {}
	for i = 1, n do
		local a, b = points[i], points[i % n + 1]
		local da, db = View.depth(a[1], a[2]), View.depth(b[1], b[2])
		local aIn, bIn = da >= NEAR, db >= NEAR
		if aIn then kept[#kept + 1] = a end
		if aIn ~= bIn then
			-- the edge crosses the near plane: keep the crossing point
			local t = (NEAR - da) / (db - da)
			kept[#kept + 1] = { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t }
		end
	end
	if #kept < 3 then return nil end

	local flat, depthSum = {}, 0
	local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
	for _, p in ipairs(kept) do
		local sx, sy, d = View.project(p[1], p[2], p[3])
		flat[#flat + 1] = sx
		flat[#flat + 1] = sy
		depthSum += d
		if sx < minX then minX = sx end
		if sx > maxX then maxX = sx end
		if sy < minY then minY = sy end
		if sy > maxY then maxY = sy end
	end
	return flat, depthSum / #kept, minX, minY, maxX, maxY
end
