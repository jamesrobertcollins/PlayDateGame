-- settings.lua
--
-- The in-game settings panel. The Playdate system menu only allows three custom items, so the
-- system menu holds Radio, Arm and a "Settings" entry, and everything else lives here:
--   Terrain size   128 / 256 / 512 cells per side (a 64 / 128 / 256 m field). Left/Right choose,
--                  A applies. Changing the size starts a new, untouched field.
--   Slumping       dirt settles to a natural angle (on) or stays put exactly (off)
--   Reset position put the machine back in the middle of the field
--   Reset terrain  throw away all digging (asks for a second A press to confirm)
--
-- main.lua supplies the actions through Settings.init and calls Settings.update / Settings.draw
-- while the panel is open; the game itself is paused meanwhile.

local gfx <const> = playdate.graphics

Settings = {}

Settings.SIZES = { 128, 256, 512 }

local ROW_SIZE, ROW_SLUMP, ROW_POSITION, ROW_TERRAIN = 1, 2, 3, 4
local ROW_COUNT <const> = 4

-- panel geometry
local PX, PY, PW, PH <const> = 40, 30, 320, 180
local ROW_H <const> = 28
local FIRST_ROW_Y <const> = PY + 40

local actions        -- { getSize, getSlumping, applySize, setSlumping, resetPosition, resetTerrain }
local selected = ROW_SIZE
local pendingSize    -- size shown in the first row; only applied with A
local confirming = false

-- `acts` is a table of functions supplied by main.lua (see the fields above).
function Settings.init(acts)
	actions = acts
end

-- Called when the panel opens.
function Settings.open()
	selected = ROW_SIZE
	pendingSize = actions.getSize()
	confirming = false
end

local function sizeIndex(size)
	for i, s in ipairs(Settings.SIZES) do
		if s == size then return i end
	end
	return 2
end

-- Handles input. Returns true when the panel should close.
function Settings.update()
	if playdate.buttonJustPressed(playdate.kButtonB) then
		return true
	end

	if playdate.buttonJustPressed(playdate.kButtonUp) then
		selected = (selected - 2) % ROW_COUNT + 1
		confirming = false
	elseif playdate.buttonJustPressed(playdate.kButtonDown) then
		selected = selected % ROW_COUNT + 1
		confirming = false
	end

	local left = playdate.buttonJustPressed(playdate.kButtonLeft)
	local right = playdate.buttonJustPressed(playdate.kButtonRight)
	local a = playdate.buttonJustPressed(playdate.kButtonA)

	if selected == ROW_SIZE then
		local i = sizeIndex(pendingSize)
		if left then i = math.max(1, i - 1) end
		if right then i = math.min(#Settings.SIZES, i + 1) end
		pendingSize = Settings.SIZES[i]
		if a and pendingSize ~= actions.getSize() then
			actions.applySize(pendingSize)
			return true
		end
	elseif selected == ROW_SLUMP then
		if left or right or a then actions.setSlumping(not actions.getSlumping()) end
	elseif selected == ROW_POSITION then
		if a then
			actions.resetPosition()
			return true
		end
	elseif selected == ROW_TERRAIN then
		if a then
			if confirming then
				actions.resetTerrain()
				return true
			end
			confirming = true
		end
	end
	return false
end

-- Text shown on the right of each row.
local function valueText(row)
	if row == ROW_SIZE then
		local world = pendingSize // 2
		local text = string.format("< %d  (%d m) >", pendingSize, world)
		if pendingSize ~= actions.getSize() then text = text .. "  A: apply" end
		return text
	elseif row == ROW_SLUMP then
		return actions.getSlumping() and "On" or "Off"
	elseif row == ROW_TERRAIN and confirming then
		return "A again to erase"
	end
	return ""
end

local LABELS <const> = { "Terrain size", "Slumping", "Reset position", "Reset terrain" }

function Settings.draw()
	gfx.setColor(gfx.kColorWhite)
	gfx.fillRoundRect(PX, PY, PW, PH, 8)
	gfx.setColor(gfx.kColorBlack)
	gfx.setLineWidth(2)
	gfx.drawRoundRect(PX, PY, PW, PH, 8)
	gfx.setLineWidth(1)
	gfx.drawTextAligned("*Settings*", PX + PW // 2, PY + 10, kTextAlignment.center)

	for row = 1, ROW_COUNT do
		local y = FIRST_ROW_Y + (row - 1) * ROW_H
		if row == selected then
			-- the selected row is drawn inverted
			gfx.fillRect(PX + 8, y - 3, PW - 16, ROW_H - 4)
			gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
		end
		gfx.drawText(LABELS[row], PX + 16, y)
		gfx.drawTextAligned(valueText(row), PX + PW - 16, y, kTextAlignment.right)
		gfx.setImageDrawMode(gfx.kDrawModeCopy)
	end

	gfx.drawTextAligned("B: back", PX + PW // 2, PY + PH - 22, kTextAlignment.center)
end
