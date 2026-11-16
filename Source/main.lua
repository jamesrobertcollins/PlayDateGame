-- main.lua
--
-- Entry point. Loads the saved settings and field, creates the excavator, arm and blade, adds the
-- system-menu items, and runs the per-frame loop. Rendering and terrain edits are native (the
-- `terrain` table comes from the C extension in src/main.c); everything else is Lua.
--
-- Saving: the terrain edits (terrain.bin) and settings plus machine position (the "settings"
-- datastore file) are written whenever the game is paused (opening the Menu), exited, or put to
-- sleep, and right after a terrain reset or size change. Both live in the game's Data folder.

import "CoreLibs/graphics"
import "CoreLibs/ui"
import "excavator"
import "arm"
import "blade"
import "cab"
import "radio"
import "sfx"
import "settings"

local gfx <const> = playdate.graphics

local TERRAIN_SEED <const> = 12345
local TERRAIN_FILE <const> = "terrain.bin"
local SETTINGS_FILE <const> = "settings"
local SLUMP_BUDGET <const> = 48 -- slump cells relaxed per frame; bounds the cost

local DEFAULTS <const> = { size = 256, slumping = true, arm = "Arc", station = Radio.OFF }

playdate.display.setRefreshRate(30)

-- ---------------------------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------------------------

Radio.scan() -- must run before the saved station is validated

-- Reads the saved settings, falling back to the defaults for anything missing or invalid (for
-- example a station whose file has since been removed).
local function loadConfig()
	local saved = playdate.datastore.read(SETTINGS_FILE) or {}
	local cfg = {}
	for key, default in pairs(DEFAULTS) do
		if saved[key] ~= nil then cfg[key] = saved[key] else cfg[key] = default end
	end

	local sizeOk = false
	for _, size in ipairs(Settings.SIZES) do sizeOk = sizeOk or size == cfg.size end
	if not sizeOk then cfg.size = DEFAULTS.size end
	if cfg.arm ~= "Arc" and cfg.arm ~= "Joints" then cfg.arm = DEFAULTS.arm end
	if type(cfg.slumping) ~= "boolean" then cfg.slumping = DEFAULTS.slumping end
	if not Radio.has(cfg.station) then cfg.station = Radio.OFF end

	-- the machine position is only meaningful for the field size it was saved with
	if saved.posSize == cfg.size and type(saved.x) == "number" and type(saved.y) == "number" then
		cfg.x, cfg.y, cfg.yaw = saved.x, saved.y, type(saved.yaw) == "number" and saved.yaw or 0
	end
	return cfg
end

local cfg = loadConfig()

-- ---------------------------------------------------------------------------------------------
-- World state
-- ---------------------------------------------------------------------------------------------

local excavator          -- created once the field exists
local arm = Arm.new()
local blade = Blade.new()
local lastMs = playdate.getCurrentTimeMilliseconds()
local settingsOpen = false

-- A "busy" job shows a message for one frame and runs on the next, so slow work (generating a
-- big field) never happens while the screen shows stale content.
local busy = nil
local function runBusy(text, fn)
	busy = { text = text, fn = fn, shown = false }
end

local function drawBusy(text)
	gfx.clear(gfx.kColorBlack)
	gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
	gfx.drawTextAligned(text, 200, 112, kTextAlignment.center)
	gfx.setImageDrawMode(gfx.kDrawModeCopy)
end

-- Writes the edits (only if the ground changed) and the settings and position. Cheap enough to
-- call whenever the game pauses.
local function saveAll()
	if not excavator then return end
	if terrain.dirty() then terrain.save(TERRAIN_FILE) end
	cfg.x, cfg.y, cfg.yaw, cfg.posSize = excavator.x, excavator.y, excavator.yaw, cfg.size
	playdate.datastore.write(cfg, SETTINGS_FILE)
end

-- Builds the field: from the save if useSave is set and a matching one exists, else fresh.
-- Returns true if a save was applied.
local function buildField(size, useSave)
	local loaded = false
	if useSave then
		loaded = terrain.load(size, TERRAIN_SEED, TERRAIN_FILE)
	elseif not terrain.init(size, TERRAIN_SEED) then
		-- not enough memory for this size: fall back to the smallest field rather than crash
		size = Settings.SIZES[1]
		cfg.size = size
		terrain.init(size, TERRAIN_SEED)
	end
	terrain.setSlumping(cfg.slumping)
	return loaded
end

local function resetMachine()
	excavator:reset()
	arm:reset()
	blade:reset()
end

-- ---------------------------------------------------------------------------------------------
-- Settings panel actions
-- ---------------------------------------------------------------------------------------------

Settings.init({
	getSize = function() return cfg.size end,
	getSlumping = function() return cfg.slumping end,
	setSlumping = function(enabled)
		cfg.slumping = enabled
		terrain.setSlumping(enabled)
	end,
	applySize = function(size)
		runBusy("Generating terrain...", function()
			cfg.size = size
			buildField(size, false)
			resetMachine()
			saveAll()
		end)
	end,
	resetPosition = function()
		resetMachine()
	end,
	resetTerrain = function()
		runBusy("Resetting terrain...", function()
			buildField(cfg.size, false)
			resetMachine()
			saveAll()
		end)
	end,
})

-- ---------------------------------------------------------------------------------------------
-- System menu (the platform allows only three custom items)
-- ---------------------------------------------------------------------------------------------

local menu = playdate.getSystemMenu()
menu:addOptionsMenuItem("Radio", Radio.names(), cfg.station, function(choice)
	cfg.station = choice
	Radio.play(choice)
	Cab.notify(choice == Radio.OFF and "Radio off" or ("Radio: " .. choice))
end)
menu:addOptionsMenuItem("Arm", { "Arc", "Joints" }, cfg.arm, function(choice)
	cfg.arm = choice
	arm:setScheme(choice == "Arc" and Arm.SCHEME_ARC or Arm.SCHEME_JOINTS)
	Cab.notify("Arm: " .. choice)
end)
menu:addMenuItem("Settings", function()
	settingsOpen = true
	Settings.open()
end)

-- ---------------------------------------------------------------------------------------------
-- Saving hooks
-- ---------------------------------------------------------------------------------------------

function playdate.gameWillPause() saveAll() end
function playdate.gameWillTerminate() saveAll() end
function playdate.deviceWillSleep() saveAll() end

-- ---------------------------------------------------------------------------------------------
-- Start up (the first frame shows a message while the field is built or loaded)
-- ---------------------------------------------------------------------------------------------

playdate.ui.crankIndicator:start() -- shows the "turn the crank" prompt whenever the crank is docked
Sfx.init()

runBusy("Loading terrain...", function()
	buildField(cfg.size, true)
	excavator = Excavator.new()
	if cfg.x then excavator:setPose(cfg.x, cfg.y, cfg.yaw) end
	arm:setScheme(cfg.arm == "Arc" and Arm.SCHEME_ARC or Arm.SCHEME_JOINTS)
	Radio.play(cfg.station)
end)

-- ---------------------------------------------------------------------------------------------
-- Frame loop
-- ---------------------------------------------------------------------------------------------

function playdate.update()
	if busy then
		if busy.shown then
			local job = busy.fn
			busy = nil
			job()
			lastMs = playdate.getCurrentTimeMilliseconds() -- don't count the job as game time
		else
			drawBusy(busy.text)
			busy.shown = true
		end
		Sfx.silence()
		return
	end

	if settingsOpen then
		if Settings.update() then settingsOpen = false else Settings.draw() end
		Sfx.silence()
		return
	end

	-- real frame time, capped so a long stall can't launch the machine across the field
	local now = playdate.getCurrentTimeMilliseconds()
	local dt = math.min((now - lastMs) / 1000, 0.1)
	lastMs = now

	if excavator.tipped and playdate.buttonJustPressed(playdate.kButtonB) then
		resetMachine()
	end

	excavator:update(dt)
	if not excavator.tipped then
		arm:update(dt, excavator)
		blade:update(dt, excavator)
	end
	terrain.slump(SLUMP_BUDGET)
	Sfx.update(dt, excavator, arm, blade, true)

	-- draw: ground first, then the arm and cab over it
	local x, y, z, yaw, pitch, roll = excavator:camera()
	terrain.render(x, y, z, yaw, pitch, roll)
	View.set(x, y, z, yaw, pitch, roll)
	arm:draw(excavator)
	Cab.draw(excavator, arm, blade, cfg.station)

	if playdate.isCrankDocked() then
		playdate.ui.crankIndicator:draw()
	end
end
