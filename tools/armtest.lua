-- armtest.lua
--
-- Host-side check of the arm drawing (Source/arm.lua + Source/view.lua) with the Playdate graphics
-- API replaced by stubs that record what would be drawn. Run from the repository root with a
-- standard Lua 5.4:   lua tools/armtest.lua      (build.ps1 -HostTest does this when lua is on PATH)
--
-- It checks that:
--   * a convex box shows only its camera-facing faces (never more than three)
--   * every visible polygon is drawn after a terrain.occlusion call for its group, and the stencil
--     is cleared afterwards (so nothing else is clipped by it)
--   * the three groups (boom, stick, bucket) are drawn in that order
--   * nothing is drawn when the whole arm is behind the camera
-- Exits non-zero on any failure.

-- ---- stubs ----------------------------------------------------------------------------------
local calls = {}
local function rec(name) return function(...) calls[#calls + 1] = { name = name, args = { ... } } end end

local gfx = {
	kColorBlack = "black", kColorWhite = "white", kColorClear = "clear",
	image = { kDitherTypeBayer8x8 = "bayer", new = function() return { draw = function() end } end },
}
for _, n in ipairs({ "setColor", "setLineWidth", "setDitherPattern", "fillPolygon", "drawPolygon",
	"drawLine", "fillCircleAtPoint", "setStencilImage", "clearStencil" }) do
	gfx[n] = rec(n)
end
playdate = { graphics = gfx }

-- Playdate's Lua has compound assignment (x += 1); standard Lua does not, so rewrite it on load.
local function loadSource(path)
	local f = assert(io.open(path, "rb"))
	local src = f:read("a")
	f:close()
	src = src:gsub("([%w_%.%[%]]+)%s*([%+%-%*/])=%s*([^;\n]+)", "%1 = %1 %2 (%3)")
	return assert(load(src, "@" .. path))()
end
function import(name) loadSource("Source/" .. name .. ".lua") end
terrain = { occlusion = rec("occlusion") }

loadSource("Source/view.lua")
loadSource("Source/arm.lua")

local failures = 0
local function check(cond, fmt, ...)
	print((cond and "  ok   " or "  FAIL ") .. string.format(fmt, ...))
	if not cond then failures = failures + 1 end
end

-- A level excavator at the origin facing +x, camera where the game puts it.
local function body()
	return { x = 0, y = 0, yaw = 0, vz = 0, vpitch = 0, vroll = 0 }
end
local function setCamera(x, y, z, yaw)
	View.set(x, y, z, yaw or 0, -0.30, 0)
end

local function count(name)
	local n = 0
	for _, c in ipairs(calls) do if c.name == name then n = n + 1 end end
	return n
end

print("arm drawing")

-- boom raised well above the camera: its underside shows; lowered below it: the top shows
local function draw(boomT)
	calls = {}
	local arm = Arm.new()
	arm.boom, arm.stick = boomT, boomT
	arm.boomTarget, arm.stickTarget = boomT, boomT
	arm:draw(body())
end

setCamera(0.5, 0.7, 2.3)
draw(0)
local raised = count("fillPolygon")
check(raised > 0, "a raised arm draws polygons (%d)", raised)
check(count("occlusion") == 3, "one occlusion mask per group: boom, stick, bucket (%d)", count("occlusion"))
check(count("setStencilImage") == count("clearStencil") and count("clearStencil") == 3,
	"each stencil is set once and cleared once (%d / %d)", count("setStencilImage"), count("clearStencil"))

-- ordering: occlusion -> stencil -> drawing -> clear, three times, with nothing drawn outside
local inside, outsideDraws, order = false, 0, {}
for _, c in ipairs(calls) do
	if c.name == "setStencilImage" then inside = true
	elseif c.name == "clearStencil" then inside = false
	elseif (c.name == "fillPolygon" or c.name == "drawLine") and not inside then outsideDraws = outsideDraws + 1 end
	if c.name == "occlusion" then order[#order + 1] = c.args[2] end
end
check(outsideDraws == 0, "no arm polygon or line is drawn outside a stencil")

-- the occlusion depth of each group must be inside the view and increase from boom to bucket
check(#order == 3 and order[1] > 0 and order[1] < order[3], "group depths run boom %.1f, stick %.1f, bucket %.1f m",
	order[1] or 0, order[2] or 0, order[3] or 0)

-- every box face drawn is camera-facing: a box can show at most 3 of its 6 faces, and only 4 of
-- its faces are modelled, so the boom contributes at most 3 polygons
calls = {}
local arm = Arm.new()
arm.boom, arm.stick = 0.5, 0.5
arm:draw(body())
local polys = count("fillPolygon") / 2 -- each visible face is filled twice (white, then shade)
check(polys >= 3 and polys < 40, "a mid-height arm draws a sensible number of faces (%d)", polys)

-- behind the camera: nothing to draw
setCamera(40, 0, 2.3, 0)
draw(0.5)
check(count("fillPolygon") == 0 and count("occlusion") == 0, "an arm behind the camera draws nothing")

-- polygons are clipped to the near plane instead of being dropped
setCamera(0.5, 0.7, 2.3)
local flat = View.projectPolygon({ { 0.0, 0.0, 1.0 }, { 3.0, 0.0, 1.0 }, { 3.0, 1.0, 1.0 }, { 0.0, 1.0, 1.0 } })
check(flat ~= nil and #flat >= 6, "a quad crossing the near plane is clipped, not dropped")
check(View.projectPolygon({ { -5, 0, 1 }, { -4, 0, 1 }, { -4, 1, 1 } }) == nil, "a polygon fully behind the camera is dropped")

-- sweep many poses and both schemes: drawing must never raise an error, whatever the arm does
local sweepErrors, sweepFirst = 0, nil
for _, scheme in ipairs({ Arm.SCHEME_ARC, Arm.SCHEME_JOINTS }) do
	for boomT = 0, 1, 0.125 do
		for stickT = 0, 1, 0.25 do
			for _, bucket in ipairs({ -0.61, 0.09, 0.7, 1.92 }) do
				calls = {}
				local a = Arm.new()
				a.scheme = scheme
				a.boom, a.stick, a.bucketAngle = boomT, stickT, bucket
				a.load = (boomT > 0.5) and 1.0 or 0
				a.dumping = bucket > 1.5
				a.tip = { 5, 0, 1 }
				local ok, err = pcall(a.draw, a, body())
				if not ok then
					sweepErrors = sweepErrors + 1
					sweepFirst = sweepFirst or string.format("scheme %d boom %.2f stick %.2f bucket %.2f: %s", scheme, boomT, stickT, bucket, err)
				end
			end
		end
	end
end
check(sweepErrors == 0, "drawing never errors across the pose sweep%s", sweepFirst and (" - first: " .. sweepFirst) or "")

print(failures == 0 and "ALL PASSED (0 failures)" or ("FAILED (" .. failures .. " failures)"))

-- ARM_DUMP=1 prints what the arm draws for one pose, to help tune the shading
if os.getenv("ARM_DUMP") then
	setCamera(0.5, 0.7, 2.3)
	calls = {}
	local a = Arm.new()
	a.boom, a.stick = 0.5, 0.5
	a:draw(body())
	local shade = nil
	for _, c in ipairs(calls) do
		if c.name == "setDitherPattern" then shade = c.args[1] end
		if c.name == "occlusion" then print(string.format("group depth %.1f m", c.args[2])) end
		if c.name == "fillPolygon" and shade then
			print(string.format("  polygon with %d points, shade %.2f", #c.args // 2, shade))
			shade = nil
		end
	end
end
os.exit(failures == 0 and 0 or 1)
