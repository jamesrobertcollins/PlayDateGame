#include <stdint.h>
#include <string.h>

#include "pd_api.h"
#include "terrain.h"

static PlaydateAPI* pd;

/* terrain.init(sizeCells, seed) -> ok */
static int l_init(lua_State* L)
{
	(void)L;
	int size = pd->lua->getArgInt(1);
	int seed = pd->lua->getArgCount() >= 2 ? pd->lua->getArgInt(2) : 1;
	if (size < 32) size = 32;
	if (size > 1024) size = 1024;
	pd->lua->pushBool(terrain_init(size, (uint32_t)seed));
	return 1;
}

/* terrain.worldSize() -> meters */
static int l_worldSize(lua_State* L)
{
	(void)L;
	pd->lua->pushFloat(terrain_world_size());
	return 1;
}

/* terrain.height(x, y) -> meters */
static int l_height(lua_State* L)
{
	(void)L;
	float x = pd->lua->getArgFloat(1), y = pd->lua->getArgFloat(2);
	pd->lua->pushFloat(terrain_height(x, y));
	return 1;
}

/* terrain.render(x, y, z, yaw, pitch, roll) */
static int l_render(lua_State* L)
{
	(void)L;
	float cam[6];
	for (int i = 0; i < 6; i++) cam[i] = pd->lua->getArgFloat(i + 1);

	unsigned int t0 = pd->system->getCurrentTimeMilliseconds();
	terrain_render(pd->graphics->getFrame(), cam);
	pd->graphics->markUpdatedRows(0, SCREEN_H - 1);
	terrain_adapt((float)(pd->system->getCurrentTimeMilliseconds() - t0));
	return 0;
}

/* terrain.setQuality(level) -- level < 0 selects automatic adaptation */
static int l_setQuality(lua_State* L)
{
	(void)L;
	terrain_set_quality(pd->lua->getArgInt(1));
	return 0;
}

/* terrain.quality() -> current level */
static int l_quality(lua_State* L)
{
	(void)L;
	pd->lua->pushInt(terrain_get_quality());
	return 1;
}

static void reg(lua_CFunction f, const char* name)
{
	const char* err;
	if (!pd->lua->addFunction(f, name, &err))
		pd->system->logToConsole("addFunction %s failed: %s", name, err);
}

#ifdef _WINDLL
__declspec(dllexport)
#endif
int eventHandler(PlaydateAPI* playdate, PDSystemEvent event, uint32_t arg)
{
	(void)arg;
	if (event == kEventInit) {
		pd = playdate;
		terrain_realloc = pd->system->realloc;
	} else if (event == kEventInitLua) {
		reg(l_init, "terrain.init");
		reg(l_worldSize, "terrain.worldSize");
		reg(l_height, "terrain.height");
		reg(l_render, "terrain.render");
		reg(l_setQuality, "terrain.setQuality");
		reg(l_quality, "terrain.quality");
	}
	return 0;
}
