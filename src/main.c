/*
 * main.c - Playdate entry point. Exposes the terrain engine to Lua as the global `terrain` table.
 *
 * The game is a hybrid: all game logic lives in Lua (the .lua files in Source/) and this C extension supplies
 * the heavy lifting (heightfield renderer and terrain edits). Because no update callback is set
 * in kEventInit, the system starts Lua and calls us again with kEventInitLua, which is where the
 * functions below are registered. They become available before main.lua runs.
 *
 * Lua API (all heights in meters, angles in radians):
 *   terrain.init(sizeCells, seed)           -> ok
 *   terrain.worldSize()                     -> field size in meters
 *   terrain.height(x, y)                    -> ground height
 *   terrain.render(x, y, z, yaw, pitch, roll)
 *   terrain.dig(x, y, tipZ, radius, maxVol) -> volume removed
 *   terrain.dump(x, y, topZ, radius, vol)   -> volume deposited
 *   terrain.grade(cx, cy, yaw, halfLen, halfWid, blend)
 *   terrain.setSlumping(enabled)
 *   terrain.slump(budget)                   -> cells that moved
 *   terrain.setQuality(level) / terrain.quality()
 */
#include <stdint.h>
#include <string.h>

#include "pd_api.h"
#include "terrain.h"

static PlaydateAPI* pd;

/* Milliseconds spent this frame on edits other than rendering. It is added to the render time
   when feeding the adaptive quality controller, so heavy digging also lowers quality. */
static unsigned int s_extraMs;

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

/* terrain.dig(x, y, tipZ, radius, maxVol) -> volume removed (m^3) */
static int l_dig(lua_State* L)
{
	(void)L;
	float x = pd->lua->getArgFloat(1), y = pd->lua->getArgFloat(2), z = pd->lua->getArgFloat(3);
	float r = pd->lua->getArgFloat(4), vol = pd->lua->getArgFloat(5);
	pd->lua->pushFloat(terrain_dig(x, y, z, r, vol));
	return 1;
}

/* terrain.dump(x, y, topZ, radius, vol) -> volume deposited (m^3) */
static int l_dump(lua_State* L)
{
	(void)L;
	float x = pd->lua->getArgFloat(1), y = pd->lua->getArgFloat(2), z = pd->lua->getArgFloat(3);
	float r = pd->lua->getArgFloat(4), vol = pd->lua->getArgFloat(5);
	pd->lua->pushFloat(terrain_dump(x, y, z, r, vol));
	return 1;
}

/* terrain.grade(cx, cy, yaw, halfLen, halfWid, blend) */
static int l_grade(lua_State* L)
{
	(void)L;
	float cx = pd->lua->getArgFloat(1), cy = pd->lua->getArgFloat(2), yaw = pd->lua->getArgFloat(3);
	float hl = pd->lua->getArgFloat(4), hw = pd->lua->getArgFloat(5), blend = pd->lua->getArgFloat(6);
	unsigned int t0 = pd->system->getCurrentTimeMilliseconds();
	terrain_grade(cx, cy, yaw, hl, hw, blend);
	s_extraMs += pd->system->getCurrentTimeMilliseconds() - t0;
	return 0;
}

/* terrain.setSlumping(enabled) */
static int l_setSlumping(lua_State* L)
{
	(void)L;
	terrain_set_slumping(pd->lua->getArgBool(1));
	return 0;
}

/* terrain.slump(budget) -> number of cells that moved this step */
static int l_slump(lua_State* L)
{
	(void)L;
	int budget = pd->lua->getArgCount() >= 1 ? pd->lua->getArgInt(1) : 48;
	unsigned int t0 = pd->system->getCurrentTimeMilliseconds();
	int moved = terrain_slump_step(budget);
	s_extraMs += pd->system->getCurrentTimeMilliseconds() - t0;
	pd->lua->pushInt(moved);
	return 1;
}

/* terrain.render(x, y, z, yaw, pitch, roll) - draws into the system frame buffer */
static int l_render(lua_State* L)
{
	(void)L;
	float cam[6];
	for (int i = 0; i < 6; i++) cam[i] = pd->lua->getArgFloat(i + 1);

	unsigned int t0 = pd->system->getCurrentTimeMilliseconds();
	terrain_render(pd->graphics->getFrame(), cam);
	pd->graphics->markUpdatedRows(0, SCREEN_H - 1);
	terrain_adapt((float)(pd->system->getCurrentTimeMilliseconds() - t0 + s_extraMs));
	s_extraMs = 0;
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

/* Registers one native function, logging (not aborting) if the runtime rejects it. */
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
		terrain_realloc = pd->system->realloc; /* route allocations through the Playdate heap */
	} else if (event == kEventInitLua) {
		reg(l_init, "terrain.init");
		reg(l_worldSize, "terrain.worldSize");
		reg(l_height, "terrain.height");
		reg(l_dig, "terrain.dig");
		reg(l_dump, "terrain.dump");
		reg(l_grade, "terrain.grade");
		reg(l_setSlumping, "terrain.setSlumping");
		reg(l_slump, "terrain.slump");
		reg(l_render, "terrain.render");
		reg(l_setQuality, "terrain.setQuality");
		reg(l_quality, "terrain.quality");
	}
	return 0;
}
