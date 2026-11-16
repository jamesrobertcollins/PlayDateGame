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
 *   terrain.occlusion(image, depth, x0, y0, x1, y1)  fills a stencil: what ground hides at `depth`
 *   terrain.dig(x, y, tipZ, radius, maxVol) -> volume removed
 *   terrain.dump(x, y, topZ, radius, vol)   -> volume deposited
 *   terrain.grade(cx, cy, yaw, halfLen, halfWid, blend)
 *   terrain.setSlumping(enabled)
 *   terrain.slump(budget)                   -> cells that moved
 *   terrain.save(path) -> ok                writes the edits to the Data folder
 *   terrain.load(size, seed, path) -> loaded  always leaves a valid field (fresh if no save)
 *   terrain.dirty() -> bool                 ground changed since the last save/load
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

/* ---- Persistence ---------------------------------------------------------------------- */

/* Adapters from the terrain core's sink / source callbacks to the Playdate file API. */
static int file_sink(void* ctx, const void* data, size_t len)
{
	return pd->file->write((SDFile*)ctx, data, (unsigned int)len) == (int)len;
}

static int file_source(void* ctx, void* buf, size_t len)
{
	return pd->file->read((SDFile*)ctx, buf, (unsigned int)len);
}

/* terrain.save(path) -> ok. Written to a temporary file first and then swapped in, so a crash
   or power loss mid-save leaves the previous save intact. Files live in the game's Data folder. */
static int l_save(lua_State* L)
{
	(void)L;
	const char* path = pd->lua->getArgString(1);
	/* the temp name is built by hand: snprintf would pull the C stdio library into the device
	   build, which the Playdate does not provide */
	char tmp[96];
	size_t plen = strlen(path);
	if (plen + 5 > sizeof tmp) {
		pd->lua->pushBool(0);
		return 1;
	}
	memcpy(tmp, path, plen);
	memcpy(tmp + plen, ".tmp", 5); /* includes the terminating NUL */

	int ok = 0;
	SDFile* f = pd->file->open(tmp, kFileWrite);
	if (f) {
		ok = terrain_save(file_sink, f);
		ok = pd->file->close(f) == 0 && ok;
	}
	if (ok) {
		pd->file->unlink(path, 0);
		ok = pd->file->rename(tmp, path) == 0;
	}
	if (!ok) pd->system->logToConsole("terrain.save(%s) failed: %s", path, pd->file->geterr());
	pd->lua->pushBool(ok);
	return 1;
}

/* terrain.load(size, seed, path) -> loaded. Always leaves a valid field behind: returns false
   when there is no usable save, in which case the field is freshly generated. */
static int l_load(lua_State* L)
{
	(void)L;
	int size = pd->lua->getArgInt(1);
	int seed = pd->lua->getArgInt(2);
	const char* path = pd->lua->getArgString(3);
	if (size < 32) size = 32;
	if (size > 1024) size = 1024;

	/* kFileReadData reads only the Data folder, where saves are written */
	SDFile* f = pd->file->open(path, kFileReadData);
	int loaded = terrain_load(size, (uint32_t)seed, f ? file_source : NULL, f);
	if (f) pd->file->close(f);
	pd->lua->pushBool(loaded);
	return 1;
}

/* terrain.dirty() -> true if the ground changed since the last save or load */
static int l_dirty(lua_State* L)
{
	(void)L;
	pd->lua->pushBool(terrain_dirty());
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

/* terrain.occlusion(image, depth, x0, y0, x1, y1)
   Fills part of a 400x240 stencil image with the ground-occlusion mask for `depth` meters (see
   terrain_occlusion_mask). The image must be a plain 1-bit white image from
   playdate.graphics.image.new(400, 240, playdate.graphics.kColorWhite). */
static int l_occlusion(lua_State* L)
{
	(void)L;
	LCDBitmap* bmp = pd->lua->getBitmap(1);
	float depth = pd->lua->getArgFloat(2);
	int x0 = pd->lua->getArgInt(3), y0 = pd->lua->getArgInt(4);
	int x1 = pd->lua->getArgInt(5), y1 = pd->lua->getArgInt(6);
	int w, h, rowBytes;
	uint8_t *mask, *data;
	if (!bmp) return 0;
	pd->graphics->getBitmapData(bmp, &w, &h, &rowBytes, &mask, &data);
	if (w != SCREEN_W || h != SCREEN_H || !data) return 0;
	terrain_occlusion_mask(data, rowBytes, depth, x0, y0, x1, y1);
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
		reg(l_save, "terrain.save");
		reg(l_load, "terrain.load");
		reg(l_dirty, "terrain.dirty");
		reg(l_render, "terrain.render");
		reg(l_occlusion, "terrain.occlusion");
		reg(l_setQuality, "terrain.setQuality");
		reg(l_quality, "terrain.quality");
	}
	return 0;
}
