-- radio.lua
--
-- The cab radio. Stations come from two places:
--   1. Built-in synth stations: the songs in radiodata.lua, played by the Playdate sequencer.
--   2. Your own audio: any .mp3 or .pda files in a "radio" folder. Put them in Source/radio/
--      before building (a .wav or .aiff there is converted to .pda by the build), or copy .mp3 /
--      .pda files into the game's Data/<bundleID>/radio/ folder at any time, with no rebuild.
--      Each file becomes a station named after the file and loops.
--
-- Radio.names() lists the stations for the system menu; Radio.play(name) switches station.

import "radiodata"

Radio = {}

local snd <const> = playdate.sound

local RADIO_DIR <const> = "radio"
local FILE_VOLUME <const> = 0.7
local MAX_NAME <const> = 18 -- keeps long file names usable in the menu

Radio.OFF = "Off"

local WAVES <const> = {
	sine = snd.kWaveSine,
	square = snd.kWaveSquare,
	triangle = snd.kWaveTriangle,
	sawtooth = snd.kWaveSawtooth,
	noise = snd.kWaveNoise,
}

local fileStations = {} -- { name = "my song", path = "radio/my song" }, found by Radio.scan
local current = nil     -- what is playing: { name, sequence, synths } or { name, player }

-- Looks for audio files in the radio folder (the app bundle and the Data folder are both searched
-- by listFiles). Safe to call when the folder does not exist.
function Radio.scan()
	fileStations = {}
	local ok, files = pcall(playdate.file.listFiles, RADIO_DIR)
	if not ok or not files then return end
	table.sort(files)
	local seen = {}
	for _, file in ipairs(files) do
		local base, ext = file:match("^(.+)%.(%w+)$")
		if base and (ext:lower() == "mp3" or ext:lower() == "pda") and not seen[base] then
			seen[base] = true
			fileStations[#fileStations + 1] = { name = base:sub(1, MAX_NAME), path = RADIO_DIR .. "/" .. base }
		end
	end
end

-- Station names in menu order: Off, the built-in stations, then your files.
function Radio.names()
	local names = { Radio.OFF }
	for _, st in ipairs(RadioData.stations) do names[#names + 1] = st.name end
	for _, st in ipairs(fileStations) do names[#names + 1] = st.name end
	return names
end

-- Builds a looping sequence for a built-in station: one synth per track, each on its own track.
-- The synths must stay referenced for as long as the sequence plays, so they are returned too.
local function buildSequence(def)
	local sequence = snd.sequence.new()
	sequence:setTempo(def.tempo)
	local synths, length = {}, 0
	for _, t in ipairs(def.tracks) do
		local voice = RadioData.voices[t.voice]
		local synth = snd.synth.new(WAVES[voice.wave])
		synth:setADSR(table.unpack(voice.adsr))
		synth:setVolume(voice.volume)
		local notes, steps = RadioData.parse(t.notes)
		local track = snd.track.new()
		track:setInstrument(synth)
		track:setNotes(notes)
		sequence:addTrack(track)
		synths[#synths + 1] = synth
		length = math.max(length, steps)
	end
	sequence:setLoops(1, length, 0) -- 0 = repeat forever
	return sequence, synths
end

function Radio.stop()
	if not current then return end
	if current.sequence then
		current.sequence:stop()
		current.sequence:allNotesOff()
	end
	if current.player then current.player:stop() end
	current = nil
end

-- Switches to the named station ("Off" or an unknown name just stops the radio).
function Radio.play(name)
	Radio.stop()
	if name == Radio.OFF then return end

	for _, def in ipairs(RadioData.stations) do
		if def.name == name then
			local sequence, synths = buildSequence(def)
			sequence:play()
			current = { name = name, sequence = sequence, synths = synths }
			return
		end
	end
	for _, st in ipairs(fileStations) do
		if st.name == name then
			local player = snd.fileplayer.new(st.path)
			if player then
				player:setVolume(FILE_VOLUME)
				player:play(0) -- 0 = loop forever
				current = { name = name, player = player }
			end
			return
		end
	end
end

-- True if `name` can be selected (used to validate a saved station).
function Radio.has(name)
	for _, n in ipairs(Radio.names()) do
		if n == name then return true end
	end
	return false
end
