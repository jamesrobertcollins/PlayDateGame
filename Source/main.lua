import "CoreLibs/graphics"
import "CoreLibs/ui"
import "excavator"
import "arm"
import "cab"

local TERRAIN_SIZE <const> = 256
local TERRAIN_SEED <const> = 12345

playdate.display.setRefreshRate(30)

terrain.init(TERRAIN_SIZE, TERRAIN_SEED)
local excavator = Excavator.new()
local arm = Arm.new()
local lastMs = playdate.getCurrentTimeMilliseconds()

local menu = playdate.getSystemMenu()
menu:addOptionsMenuItem("Arm", { "Arc", "Joints" }, "Arc", function(choice)
	arm:setScheme(choice == "Arc" and Arm.SCHEME_ARC or Arm.SCHEME_JOINTS)
end)

playdate.ui.crankIndicator:start()

function playdate.update()
	local now = playdate.getCurrentTimeMilliseconds()
	local dt = math.min((now - lastMs) / 1000, 0.1)
	lastMs = now

	if excavator.tipped and playdate.buttonJustPressed(playdate.kButtonB) then
		excavator:reset()
		arm:reset()
	end

	excavator:update(dt)
	if not excavator.tipped then
		arm:update(dt, excavator)
	end

	local x, y, z, yaw, pitch, roll = excavator:camera()
	terrain.render(x, y, z, yaw, pitch, roll)
	View.set(x, y, z, yaw, pitch, roll)
	arm:draw(excavator)
	Cab.draw(excavator, arm)

	if playdate.isCrankDocked() then
		playdate.ui.crankIndicator:draw()
	end
end
