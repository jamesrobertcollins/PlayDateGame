-- radiotest.lua
--
-- Host-side check of the radio song data. Run with a standard Lua 5.4 interpreter from the
-- repository root:   lua tools/radiotest.lua      (build.ps1 -HostTest does this when lua is on PATH)
--
-- It verifies that every station's tracks parse, use known voices, have the same length (so the
-- loop is seamless), and stay in a sensible note range. Exits non-zero on any failure.

dofile("Source/radiodata.lua")

local failures = 0
local function check(cond, fmt, ...)
	print((cond and "  ok   " or "  FAIL ") .. string.format(fmt, ...))
	if not cond then failures = failures + 1 end
end

print("radio data")

-- the note parser itself
check(RadioData.noteToMidi("C4") == 60, "C4 is MIDI 60")
check(RadioData.noteToMidi("A4") == 69, "A4 is MIDI 69")
check(RadioData.noteToMidi("F#5") == 78 and RadioData.noteToMidi("Gb5") == 78, "sharps and flats agree")
check(RadioData.noteToMidi("H4") == nil, "an unknown note name is rejected")
check(not pcall(RadioData.parse, "C4:x"), "a malformed token raises an error")
local notes, steps = RadioData.parse("C4:2 -:2 E4:4")
check(#notes == 2 and steps == 8 and notes[2].step == 5, "rests advance the step counter (steps start at 1)")

for _, st in ipairs(RadioData.stations) do
	local lengths = {}
	local ok = true
	local lowest, highest = 127, 0
	local count = 0
	for _, track in ipairs(st.tracks) do
		local parsed, len = RadioData.parse(track.notes)
		lengths[#lengths + 1] = len
		ok = ok and RadioData.voices[track.voice] ~= nil
		count = count + #parsed
		for _, n in ipairs(parsed) do
			lowest = math.min(lowest, n.note)
			highest = math.max(highest, n.note)
		end
	end
	local same = true
	for _, l in ipairs(lengths) do same = same and l == lengths[1] end
	check(same and lengths[1] % 16 == 0, "%s: all %d tracks are %d steps (whole bars)", st.name, #lengths, lengths[1])
	check(ok, "%s: every track uses a defined voice", st.name)
	check(lowest >= 24 and highest <= 96, "%s: notes within range (%d to %d), %d notes", st.name, lowest, highest, count)
	check(st.tempo >= 3 and st.tempo <= 16, "%s: tempo %d steps/s", st.name, st.tempo)
end

print(failures == 0 and "ALL PASSED (0 failures)" or ("FAILED (" .. failures .. " failures)"))
os.exit(failures == 0 and 0 or 1)
