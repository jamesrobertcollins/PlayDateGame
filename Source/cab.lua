-- cab.lua
--
-- The cab: window frame, dashboard and instruments drawn over the 3D view.
--
-- The static parts (pillars, roof header, dash housing, instrument bezels) are painted once into
-- images and then only blitted, which is much cheaper than redrawing the shapes every frame. The
-- live parts are drawn on top each frame:
--   left LCD       speed
--   BLADE / TILT   lamps (TILT blinks as the machine nears its tipping angle)
--   gauge          artificial-horizon style pitch and roll indicator
--   status boxes   which joint the crank drives, and the render quality level
--   radio          the current station
--   levers         the left one follows the drive and turn buttons, the right one the arm
--   roof           frame rate
-- plus short notices (radio / arm changes), a TILT! warning and the "tipped over" prompt.

local gfx <const> = playdate.graphics

Cab = {}

local BAYER <const> = gfx.image.kDitherTypeBayer8x8
local BLACK <const>, WHITE <const> = gfx.kColorBlack, gfx.kColorWhite

-- Dash geometry. DASH_EDGE is the dash's top edge, a shallow arch.
local DASH_EDGE <const> = { { 0, 215 }, { 34, 208 }, { 110, 204 }, { 290, 204 }, { 366, 208 }, { 400, 215 } }
local GAUGE_X, GAUGE_Y, GAUGE_R <const> = 200, 222, 12

local smallFont = gfx.font.new("/System/Fonts/Roobert-10-Bold") -- nil if the font is missing
local defaultFont = gfx.getFont()

local noticeText, noticeUntil = nil, 0

-- Shows a short message at the top of the view for a couple of seconds (radio and arm changes).
function Cab.notify(text)
	noticeText = text
	noticeUntil = playdate.getCurrentTimeMilliseconds() + 2500
end

-- ---------------------------------------------------------------------------------------------
-- Static artwork
-- ---------------------------------------------------------------------------------------------

-- One A-pillar. It leans inwards towards the roof, has a white edge line and a stippled rubber
-- seal along the window side, a sheen, and rivets. `mirror` draws the right-hand one.
local function paintPillar(mirror)
	local function X(x) return mirror and 400 - x or x end
	gfx.setColor(BLACK)
	gfx.fillPolygon(X(0), 0, X(30), 0, X(13), 206, X(0), 214)

	gfx.setColor(WHITE)
	gfx.drawLine(X(31), 15, X(14), 206)
	gfx.setColor(BLACK)
	gfx.setDitherPattern(0.55, BAYER)
	gfx.fillPolygon(X(32), 15, X(37), 15, X(20), 206, X(15), 206)

	-- with white selected the dither value is inverted: 0.85 gives sparse white dots
	gfx.setColor(WHITE)
	gfx.setDitherPattern(0.85, BAYER)
	gfx.fillPolygon(X(3), 0, X(9), 0, X(6), 206, X(1), 206)

	gfx.setColor(WHITE)
	for _, y in ipairs({ 50, 100, 150 }) do
		gfx.fillCircleAtPoint(X(30 - 17 * (y / 206) - 7), y, 1.5)
	end
	gfx.setColor(BLACK)
end

local function paintRoof()
	gfx.setColor(BLACK)
	gfx.fillPolygon(0, 0, 400, 0, 400, 13, 372, 15, 300, 12, 100, 12, 28, 15, 0, 13)
	gfx.setColor(WHITE)
	gfx.drawLine(28, 16, 100, 13)
	gfx.drawLine(100, 13, 300, 13)
	gfx.drawLine(300, 13, 372, 16)
	-- stippled rubber seal under the header
	gfx.setColor(BLACK)
	gfx.setDitherPattern(0.5, BAYER)
	gfx.fillPolygon(28, 16, 100, 13, 300, 13, 372, 16, 372, 19, 300, 16, 100, 16, 28, 19)
	gfx.setColor(BLACK)
end

local function paintDash()
	-- housing
	gfx.setColor(BLACK)
	local body = {}
	for _, p in ipairs(DASH_EDGE) do
		body[#body + 1] = p[1]
		body[#body + 1] = p[2]
	end
	body[#body + 1] = 400
	body[#body + 1] = 240
	body[#body + 1] = 0
	body[#body + 1] = 240
	gfx.fillPolygon(table.unpack(body))

	-- bright top edge and a stippled "padded" band below it
	gfx.setColor(WHITE)
	for i = 1, #DASH_EDGE - 1 do
		local a, b = DASH_EDGE[i], DASH_EDGE[i + 1]
		gfx.drawLine(a[1], a[2] + 1, b[1], b[2] + 1)
	end
	gfx.setDitherPattern(0.8, BAYER)
	local band = {}
	for _, p in ipairs(DASH_EDGE) do
		band[#band + 1] = p[1]
		band[#band + 1] = p[2] + 3
	end
	for i = #DASH_EDGE, 1, -1 do
		band[#band + 1] = DASH_EDGE[i][1]
		band[#band + 1] = DASH_EDGE[i][2] + 8
	end
	gfx.fillPolygon(table.unpack(band))

	-- speed LCD: a white window with a dark inner border
	gfx.setColor(WHITE)
	gfx.drawRoundRect(50, 211, 80, 27, 4)
	gfx.fillRoundRect(52, 213, 76, 23, 3)
	gfx.setColor(BLACK)
	gfx.drawRoundRect(54, 215, 68, 19, 2)

	-- lamp and status boxes
	gfx.setColor(WHITE)
	for _, b in ipairs({ { 136, 210 }, { 136, 225 }, { 222, 210 }, { 222, 225 } }) do
		gfx.drawRoundRect(b[1], b[2], 44, 13, 2)
	end

	-- gauge bezel
	gfx.setColor(WHITE)
	gfx.drawCircleAtPoint(GAUGE_X, GAUGE_Y, GAUGE_R + 4)
	gfx.drawCircleAtPoint(GAUGE_X, GAUGE_Y, GAUGE_R + 3)

	-- radio: frame and speaker grille
	gfx.drawRoundRect(272, 210, 94, 28, 3)
	for i = 0, 4 do
		gfx.drawLine(349 + i * 3, 215, 349 + i * 3, 233)
	end

	-- lever boots
	for _, bx in ipairs({ 34, 382 }) do
		gfx.setColor(WHITE)
		gfx.fillCircleAtPoint(bx, 230, 8)
		gfx.setColor(BLACK)
		gfx.fillCircleAtPoint(bx, 230, 6)
		gfx.setColor(WHITE)
		gfx.drawCircleAtPoint(bx, 230, 3)
	end
	gfx.setColor(BLACK)
end

-- A faint diagonal glare on the glass, as a few sparse white dots.
local function paintGlare()
	gfx.setColor(WHITE)
	gfx.setDitherPattern(0.9, BAYER)
	gfx.fillPolygon(52, 20, 70, 20, 44, 96, 34, 96)
	gfx.fillPolygon(76, 20, 82, 20, 54, 96, 49, 96)
	gfx.setColor(BLACK)
end

local built = nil -- { { image, x, y }, ... }

-- Paints everything once, then cuts it into the regions that are blitted each frame.
local function build()
	local full = gfx.image.new(400, 240, gfx.kColorClear)
	gfx.pushContext(full)
	paintGlare()
	paintPillar(false)
	paintPillar(true)
	paintRoof()
	paintDash()
	gfx.popContext()

	built = {}
	for _, r in ipairs({ { 0, 0, 400, 22 }, { 0, 22, 40, 194 }, { 360, 22, 40, 194 }, { 0, 196, 400, 44 } }) do
		local part = gfx.image.new(r[3], r[4], gfx.kColorClear)
		gfx.pushContext(part)
		full:draw(-r[1], -r[2])
		gfx.popContext()
		built[#built + 1] = { part, r[1], r[2] }
	end
end

-- ---------------------------------------------------------------------------------------------
-- Live instruments
-- ---------------------------------------------------------------------------------------------

-- A small status box: white-on-black normally, black-on-white when lit.
local function lamp(x, y, label, lit, font)
	if lit then
		gfx.setColor(WHITE)
		gfx.fillRoundRect(x + 1, y + 1, 42, 11, 2)
		gfx.setImageDrawMode(gfx.kDrawModeCopy)
	else
		gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
	end
	gfx.drawTextAligned(label, x + 22, y + (13 - font:getHeight()) // 2, kTextAlignment.center)
	gfx.setImageDrawMode(gfx.kDrawModeCopy)
	gfx.setColor(BLACK)
end

-- Attitude indicator: sky above, ground (stippled) below a horizon that tilts with roll and
-- shifts with pitch, exactly the way the real horizon moves in the window.
local function drawGauge(ex)
	local cx, cy, R = GAUGE_X, GAUGE_Y, GAUGE_R
	gfx.setColor(WHITE)
	gfx.fillCircleAtPoint(cx, cy, R)

	local off = math.max(-R, math.min(R, ex.pitch * 22)) -- horizon offset below the centre, pixels
	local alpha = math.acos(off / R)                       -- half the arc of ground that shows
	if alpha > 0.01 then
		local phi = math.atan(math.cos(-ex.roll), -math.sin(-ex.roll)) -- direction of "down" in the gauge
		local pts = {}
		for i = 0, 10 do
			local a = phi - alpha + 2 * alpha * i / 10
			pts[#pts + 1] = cx + R * math.cos(a)
			pts[#pts + 1] = cy + R * math.sin(a)
		end
		gfx.setColor(BLACK)
		gfx.setDitherPattern(1 - 0.7, BAYER) -- the dither value is how transparent the fill is
		gfx.fillPolygon(table.unpack(pts))
	end

	-- fixed aircraft-style marker
	gfx.setColor(BLACK)
	gfx.setLineWidth(3)
	gfx.drawLine(cx - 8, cy, cx - 3, cy)
	gfx.drawLine(cx + 3, cy, cx + 8, cy)
	gfx.setLineWidth(1)
	gfx.setColor(WHITE)
	gfx.drawLine(cx - 7, cy, cx - 4, cy)
	gfx.drawLine(cx + 4, cy, cx + 7, cy)
	gfx.setColor(BLACK)
	gfx.fillCircleAtPoint(cx, cy, 2)
	gfx.setColor(WHITE)
	gfx.fillCircleAtPoint(cx, cy, 1)
	gfx.setColor(BLACK)
end

-- A control lever from its boot at (bx, by) to a knob at (kx, ky).
local function drawLever(bx, by, kx, ky)
	gfx.setColor(WHITE)
	gfx.setLineWidth(6)
	gfx.drawLine(bx, by, kx, ky)
	gfx.setColor(BLACK)
	gfx.setLineWidth(4)
	gfx.drawLine(bx, by, kx, ky)
	gfx.setLineWidth(1)
	gfx.setColor(WHITE)
	gfx.fillCircleAtPoint(kx, ky, 6)
	gfx.setColor(BLACK)
	gfx.fillCircleAtPoint(kx, ky, 4)
	gfx.setColor(WHITE)
	gfx.fillCircleAtPoint(kx - 1, ky - 1, 1)
	gfx.setColor(BLACK)
end

-- Shortens text with ".." until it fits in `width` pixels.
local function fit(font, text, width)
	while #text > 1 and font:getTextWidth(text) > width do
		text = text:sub(1, -2)
	end
	return text
end

function Cab.draw(ex, arm, blade, station)
	if not built then build() end
	for _, b in ipairs(built) do
		b[1]:draw(b[2], b[3])
	end

	local font = smallFont or defaultFont
	gfx.setFont(font)

	-- frame rate in the roof
	gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
	gfx.drawTextAligned(string.format("%d fps", playdate.getFPS()), 340, 0, kTextAlignment.right)
	gfx.setImageDrawMode(gfx.kDrawModeCopy)

	-- speed on the LCD (black on its white window)
	gfx.drawTextAligned(string.format("%.1f m/s", math.abs(ex.speed)), 90, 213 + (23 - font:getHeight()) // 2,
		kTextAlignment.center)

	-- lamps and status boxes
	local warning = not ex.tipped and ex:tiltRatio() > Excavator.WARN_FRACTION
	local blink = (playdate.getCurrentTimeMilliseconds() // 250) % 2 == 0
	lamp(136, 210, "BLADE", blade.active, font)
	lamp(136, 225, "TILT", warning and blink, font)
	local mode = arm.scheme == Arm.SCHEME_ARC and "ARC" or (arm.active == 1 and "BOOM" or "STICK")
	lamp(222, 210, mode, false, font)
	lamp(222, 225, "Q" .. terrain.quality(), false, font)

	drawGauge(ex)

	-- radio: a caption and the station name
	gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
	gfx.drawText("RADIO", 277, 212)
	local name = station == Radio.OFF and "OFF" or station
	gfx.drawText(fit(font, name, 68), 277, 224)
	gfx.setImageDrawMode(gfx.kDrawModeCopy)

	-- levers: the left one follows drive/turn, the right one the arm (boom height, curl, dump)
	local lx, ly = 0, 0
	if playdate.buttonIsPressed(playdate.kButtonLeft) then lx -= 7 end
	if playdate.buttonIsPressed(playdate.kButtonRight) then lx += 7 end
	if playdate.buttonIsPressed(playdate.kButtonUp) then ly -= 5 end
	if playdate.buttonIsPressed(playdate.kButtonDown) then ly += 5 end
	drawLever(34, 230, 34 + lx, 197 + ly)
	local rx = (0.5 - arm.boom) * 14
	local ry = (arm.curl - 1) * 2 + (arm.dumping and 5 or 0)
	drawLever(382, 230, 382 + rx, 197 + ry)

	gfx.setFont(defaultFont)

	-- blinking warning over the view as the machine nears its tipping angle
	if warning and blink then
		gfx.setColor(BLACK)
		gfx.fillRoundRect(168, 176, 64, 22, 5)
		gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
		gfx.drawTextAligned("TILT!", 200, 180, kTextAlignment.center)
		gfx.setImageDrawMode(gfx.kDrawModeCopy)
	end

	-- transient notice (radio station, arm scheme)
	if noticeText and playdate.getCurrentTimeMilliseconds() < noticeUntil then
		gfx.setColor(BLACK)
		gfx.fillRoundRect(110, 20, 180, 24, 6)
		gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
		gfx.drawTextAligned(noticeText, 200, 25, kTextAlignment.center)
		gfx.setImageDrawMode(gfx.kDrawModeCopy)
	end

	if ex.tipped then
		gfx.setColor(WHITE)
		gfx.fillRoundRect(80, 84, 240, 56, 6)
		gfx.setColor(BLACK)
		gfx.drawRoundRect(80, 84, 240, 56, 6)
		gfx.drawTextAligned("*Tipped over!*", 200, 94, kTextAlignment.center)
		gfx.drawTextAligned("Press B to reset position", 200, 116, kTextAlignment.center)
	end
end
