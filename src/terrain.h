#ifndef TERRAIN_H
#define TERRAIN_H

#include <stdint.h>
#include <stddef.h>

#define SCREEN_W 400
#define SCREEN_H 240
#define ROW_BYTES 52

#define CELL_M 0.5f          /* world meters per terrain cell */
#define BEDROCK_CM (-300)    /* undiggable floor, 3 m below the original ground */
#define TREE_ZONE_M 8.0f     /* depth of the tree band along each edge */

#define MAT_GRASS 0
#define MAT_DIRT 1
#define MAT_ROCK 2

typedef struct {
	int16_t h;  /* height in centimeters */
	uint8_t c;  /* precomputed base brightness 0..255 (material + lighting) */
	uint8_t m;  /* material */
} TCell;

#define QUALITY_LEVELS 6

/* Optional allocator hook (defaults to realloc). */
extern void* (*terrain_realloc)(void* ptr, size_t size);

int terrain_init(int size, uint32_t seed);
void terrain_free(void);
int terrain_size(void);
float terrain_world_size(void);

/* Terrain height in meters, bilinear. Outside the field it is 0. */
float terrain_height(float x, float y);

/* cam = {x, y, z, yaw, pitch, roll}; yaw 0 faces +x, positive yaw turns left (towards +y). */
void terrain_render(uint8_t* frame, const float cam[6]);

int terrain_get_quality(void);
void terrain_set_quality(int level);
/* Feeds the measured render time; returns the (possibly adjusted) quality level. */
int terrain_adapt(float render_ms);

#endif
