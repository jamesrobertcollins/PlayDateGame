-- radiodata.lua
--
-- Song data for the cab radio: a tiny note notation, the synth voices, and the built-in stations.
-- This file is plain Lua with no Playdate calls, so tools/radiotest.lua can check it on a PC.
-- radio.lua turns it into Playdate sequences.
--
-- Notation: a track is a string of tokens separated by spaces. A token is "NOTE:STEPS", for
-- example "E5:2" (E in octave 5, two steps long) or "F#4:1" / "Bb3:4". "-:N" is a rest of N steps.
-- A step is a 16th note at the station's tempo (steps per second). Every track of a station must
-- add up to the same number of steps; the sequence loops over that length.
--
-- All of the tunes below are original and written for this game.

RadioData = {}

local SEMITONE = { C = 0, D = 2, E = 4, F = 5, G = 7, A = 9, B = 11 }

-- "C4" -> 60. Accepts sharps (#) and flats (b). Returns nil for anything it does not understand.
function RadioData.noteToMidi(name)
	local letter, accidental, octave = name:match("^([A-G])([#b]?)(%d)$")
	if not letter then return nil end
	local n = 12 * (tonumber(octave) + 1) + SEMITONE[letter]
	if accidental == "#" then n = n + 1 elseif accidental == "b" then n = n - 1 end
	return n
end

-- Parses a track string into a list of { step, note, length } (steps start at 1, as the Playdate
-- sequencer expects) and the total number of steps. Raises an error on a malformed token so a typo
-- in a tune is caught by the host test instead of silently dropping notes.
function RadioData.parse(str)
	local notes, step = {}, 1
	for token in str:gmatch("%S+") do
		local name, len = token:match("^([^:]+):(%d+)$")
		if not name then error("bad token '" .. token .. "'") end
		len = tonumber(len)
		if name ~= "-" then
			local midi = RadioData.noteToMidi(name)
			if not midi then error("bad note '" .. name .. "'") end
			notes[#notes + 1] = { step = step, note = midi, length = len, velocity = 1.0 }
		end
		step = step + len
	end
	return notes, step - 1
end

-- Synth voices: waveform name, envelope (attack, decay, sustain level, release) and volume.
RadioData.voices = {
	lead  = { wave = "square",   adsr = { 0.005, 0.10, 0.55, 0.08 }, volume = 0.26 },
	pluck = { wave = "square",   adsr = { 0.002, 0.09, 0.00, 0.06 }, volume = 0.28 },
	bass  = { wave = "triangle", adsr = { 0.005, 0.10, 0.70, 0.05 }, volume = 0.40 },
	pad   = { wave = "triangle", adsr = { 0.020, 0.20, 0.50, 0.30 }, volume = 0.28 },
	bell  = { wave = "sine",     adsr = { 0.010, 0.40, 0.20, 0.50 }, volume = 0.25 },
	kick  = { wave = "sine",     adsr = { 0.001, 0.13, 0.00, 0.02 }, volume = 0.55 },
	snare = { wave = "noise",    adsr = { 0.001, 0.10, 0.00, 0.02 }, volume = 0.30 },
	hat   = { wave = "noise",    adsr = { 0.001, 0.03, 0.00, 0.01 }, volume = 0.12 },
}

local function rep(str, n) return string.rep(str, n) end

RadioData.stations = {
	-- Bright chiptune in C major: C - Am - F - G, 120 BPM.
	{
		name = "Gravel FM",
		tempo = 8,
		tracks = {
			{ voice = "lead", notes =
				"E5:2 G5:2 E5:2 C5:2 E5:4 G5:4 " ..
				"A4:2 C5:2 E5:2 C5:2 A4:4 E5:4 " ..
				"F5:2 A5:2 F5:2 C5:2 F5:4 A4:4 " ..
				"G4:2 B4:2 D5:2 B4:2 G5:4 -:4" },
			{ voice = "bass", notes =
				"C3:2 C3:2 G3:2 C3:2 C3:2 C3:2 G3:2 E3:2 " ..
				"A2:2 A2:2 E3:2 A2:2 A2:2 A2:2 E3:2 C3:2 " ..
				"F2:2 F2:2 C3:2 F2:2 F2:2 F2:2 C3:2 A2:2 " ..
				"G2:2 G2:2 D3:2 G2:2 G2:2 G2:2 D3:2 B2:2" },
			{ voice = "kick",  notes = rep("C2:1 -:7 C2:1 -:1 C2:1 -:5 ", 4) },
			{ voice = "snare", notes = rep("-:4 C4:1 -:7 C4:1 -:3 ", 4) },
			{ voice = "hat",   notes = rep("-:1 C4:1 ", 32) },
		},
	},

	-- Boom-chick country two-step in G: G - C - G - D.
	{
		name = "Hardhat Country",
		tempo = 9,
		tracks = {
			{ voice = "pluck", notes =
				"B4:2 D5:2 G5:4 D5:2 B4:2 G4:4 " ..
				"C5:2 E5:2 G5:4 E5:2 C5:2 E5:4 " ..
				"B4:2 D5:2 G5:2 B5:2 A5:4 G5:4 " ..
				"A4:2 D5:2 F#5:4 E5:2 D5:2 D5:2 -:2" },
			{ voice = "bass", notes =
				rep("G2:2 D3:2 ", 4) .. rep("C3:2 G3:2 ", 4) ..
				rep("G2:2 D3:2 ", 4) .. rep("D3:2 A3:2 ", 4) },
			{ voice = "kick",  notes = rep("C2:1 -:7 C2:1 -:7 ", 4) },
			{ voice = "snare", notes = rep("-:4 C4:1 -:7 C4:1 -:3 ", 4) },
		},
	},

	-- Slow late-night drive in A minor: Am - F - C - G, 75 BPM.
	{
		name = "Night Shift",
		tempo = 5,
		tracks = {
			{ voice = "pad", notes =
				"A3:2 C4:2 E4:2 A4:2 E4:2 C4:2 A3:2 E4:2 " ..
				"F3:2 A3:2 C4:2 F4:2 C4:2 A3:2 F3:2 C4:2 " ..
				"C4:2 E4:2 G4:2 C5:2 G4:2 E4:2 C4:2 G4:2 " ..
				"G3:2 B3:2 D4:2 G4:2 D4:2 B3:2 G3:2 D4:2" },
			{ voice = "bell", notes =
				"E5:6 D5:2 C5:8 " ..
				"A4:4 C5:4 F5:8 " ..
				"G5:8 E5:4 C5:4 " ..
				"D5:6 B4:2 G4:8" },
			{ voice = "bass", notes = "A2:16 F2:16 C3:16 G2:16" },
		},
	},
}
