-- sfx.lua
--
-- Machine sounds: an engine whose pitch and loudness follow how hard the machine is working, and
-- short noise effects for digging, spilling dirt, the blade scraping, and tipping over.
-- (The radio is separate: see radio.lua.)

local snd <const> = playdate.sound

Sfx = {}

local IDLE_HZ <const> = 58       -- engine pitch at idle
local WORK_HZ <const> = 52       -- extra pitch at full effort
local IDLE_VOLUME <const> = 0.10
local WORK_VOLUME <const> = 0.17 -- extra volume at full effort
local MAX_SPEED <const> = 3.5    -- excavator top speed, for scaling

local engine, noise
local engineOn = false
local effort = 0      -- smoothed 0..1 measure of how hard the machine is working
local lastHz = 0
local timers = { dig = 0, spill = 0, blade = 0 }
local wasTipped = false

function Sfx.init()
	-- a sawtooth with legato phrasing: changing the note while it is held glides the pitch
	-- instead of restarting the sound
	engine = snd.synth.new(snd.kWaveSawtooth)
	engine:setADSR(0.25, 0, 1, 0.3)
	engine:setLegato(true)
	engine:setVolume(0)

	noise = snd.synth.new(snd.kWaveNoise)
	noise:setADSR(0.004, 0.06, 0.4, 0.06)
end

local function engineStop()
	if engineOn then
		engine:noteOff()
		engineOn = false
	end
end

-- Silences the machine (used while paused in a menu or while the field is being generated).
function Sfx.silence()
	engineStop()
end

-- Call once per game frame. `active` is false while the game is not running (menus, loading).
function Sfx.update(dt, ex, arm, blade, active)
	if not active then
		engineStop()
		return
	end

	-- tipping over: stop the engine and play one crash
	if ex.tipped then
		engineStop()
		if not wasTipped then noise:playNote(80, 0.9, 0.7) end
		wasTipped = true
		return
	end
	wasTipped = false

	-- how hard the machine is working: driving, turning, or moving dirt with the bucket
	local turning = (playdate.buttonIsPressed(playdate.kButtonLeft) or playdate.buttonIsPressed(playdate.kButtonRight)) and 0.5 or 0
	local target = math.max(math.abs(ex.speed) / MAX_SPEED, turning, (arm.digging or arm.spilling) and 0.7 or 0)
	effort += (target - effort) * math.min(1, dt * 4)

	local hz = IDLE_HZ + WORK_HZ * effort
	engine:setVolume(IDLE_VOLUME + WORK_VOLUME * effort)
	if not engineOn then
		engine:playNote(hz, 1)
		engineOn = true
		lastHz = hz
	elseif math.abs(hz - lastHz) > 1 then
		engine:playNote(hz, 1) -- legato: glides to the new pitch
		lastHz = hz
	end

	-- throttled one-shot effects: noise bursts, shaped by volume and length
	for k in pairs(timers) do timers[k] = math.max(0, timers[k] - dt) end
	if arm.digging and timers.dig == 0 then
		noise:playNote(200, 0.55, 0.10)
		timers.dig = 0.13
	end
	if arm.spilling and timers.spill == 0 then
		noise:playNote(200, 0.35, 0.08)
		timers.spill = 0.10
	end
	if blade.active and math.abs(ex.speed) > 0.3 and timers.blade == 0 then
		noise:playNote(200, 0.22, 0.05)
		timers.blade = 0.09
	end
end
