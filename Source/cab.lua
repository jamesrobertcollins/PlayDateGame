-- cab.lua
--
-- The cab frame and dashboard HUD drawn over the 3D view: window pillars, speed, the active
-- crank joint, the blade indicator, a tilt gauge with a tipping warning, the render quality and
-- frame rate (handy while tuning for the device), short notices, and the "tipped over" prompt.

local gfx <const> = playdate.graphics

Cab = {}

local DASH_Y = 212 -- top of the dashboard strip

local noticeText, noticeUntil = nil, 0

-- Shows a short message at the top of the view for a couple of seconds (radio and arm changes).
function Cab.notify(text)
	noticeText = text
	noticeUntil = playdate.getCurrentTimeMilliseconds() + 2500
end

-- Artificial-horizon style gauge: a line that rotates with roll and shifts with pitch.
local function drawTiltGauge(cx, cy, ex)
	gfx.setColor(gfx.kColorWhite)
	gfx.drawCircleAtPoint(cx, cy, 11)
	local r = ex.roll
	local off = math.max(-8, math.min(8, -ex.pitch * 14))
	local dx, dy = math.cos(r) * 10, math.sin(r) * 10
	gfx.drawLine(cx - dx, cy - dy + off, cx + dx, cy + dy + off)
	gfx.fillCircleAtPoint(cx, cy, 1)
end

function Cab.draw(ex, arm, blade)
	-- roof bar, two window pillars and the dashboard
	gfx.setColor(gfx.kColorBlack)
	gfx.fillRect(0, 0, 400, 10)
	gfx.fillPolygon(0, 0, 26, 0, 12, DASH_Y, 0, DASH_Y)
	gfx.fillPolygon(400, 0, 374, 0, 388, DASH_Y, 400, DASH_Y)
	gfx.fillRect(0, DASH_Y, 400, 240 - DASH_Y)
	gfx.setColor(gfx.kColorWhite)
	gfx.drawLine(12, DASH_Y, 388, DASH_Y)

	-- dashboard text is white on black
	gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
	gfx.drawText(string.format("%.1f m/s", math.abs(ex.speed)), 20, DASH_Y + 6)
	if arm.scheme == Arm.SCHEME_JOINTS then
		gfx.drawText(arm.active == 1 and "Crank: BOOM" or "Crank: STICK", 80, DASH_Y + 6)
	end
	if blade.active then
		gfx.drawText("BLADE", 232, DASH_Y + 6)
	end
	gfx.drawText(string.format("Q%d  %dfps", terrain.quality(), playdate.getFPS()), 300, DASH_Y + 6)
	gfx.setImageDrawMode(gfx.kDrawModeCopy)

	drawTiltGauge(200, DASH_Y + 14, ex)

	-- transient notice (radio station, arm scheme)
	if noticeText and playdate.getCurrentTimeMilliseconds() < noticeUntil then
		gfx.setColor(gfx.kColorBlack)
		gfx.fillRoundRect(110, 14, 180, 24, 6)
		gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
		gfx.drawTextAligned(noticeText, 200, 19, kTextAlignment.center)
		gfx.setImageDrawMode(gfx.kDrawModeCopy)
	end
	-- blinking warning as the machine nears its tipping angle
	if not ex.tipped and ex:tiltRatio() > Excavator.WARN_FRACTION then
		if (playdate.getCurrentTimeMilliseconds() // 250) % 2 == 0 then
			gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
			gfx.drawTextAligned("TILT!", 200, DASH_Y - 22, kTextAlignment.center)
			gfx.setImageDrawMode(gfx.kDrawModeCopy)
		end
	end

	if ex.tipped then
		gfx.setColor(gfx.kColorWhite)
		gfx.fillRoundRect(80, 84, 240, 56, 6)
		gfx.setColor(gfx.kColorBlack)
		gfx.drawRoundRect(80, 84, 240, 56, 6)
		gfx.drawTextAligned("*Tipped over!*", 200, 94, kTextAlignment.center)
		gfx.drawTextAligned("Press B to reset position", 200, 116, kTextAlignment.center)
	end
end
