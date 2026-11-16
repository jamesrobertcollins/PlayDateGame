import "CoreLibs/graphics"
import "excavator"
import "cab"

local TERRAIN_SIZE <const> = 256
local TERRAIN_SEED <const> = 12345

playdate.display.setRefreshRate(30)

terrain.init(TERRAIN_SIZE, TERRAIN_SEED)
local excavator = Excavator.new()
local lastMs = playdate.getCurrentTimeMilliseconds()

function playdate.update()
	local now = playdate.getCurrentTimeMilliseconds()
	local dt = math.min((now - lastMs) / 1000, 0.1)
	lastMs = now

	if excavator.tipped and playdate.buttonJustPressed(playdate.kButtonB) then
		excavator:reset()
	end

	excavator:update(dt)
	terrain.render(excavator:camera())
	Cab.draw(excavator)
end
