/*
 * terrain.h - heightfield terrain: generation, editing (dig / dump / grade / slump) and rendering.
 *
 * The world is a square grid of cells. Each cell stores a height in centimeters, a material and a
 * precomputed brightness. The renderer is a "voxel space" (Comanche style) column raycaster that
 * draws straight into the Playdate's 1-bit frame buffer, so editing the ground is just changing
 * cell heights - there is no mesh to rebuild.
 *
 * Coordinates: x and y are horizontal world meters, z is up. yaw 0 faces +x and a positive yaw
 * turns towards +y (counter-clockwise seen from above).
 */
#ifndef TERRAIN_H
#define TERRAIN_H

#include <stdint.h>
#include <stddef.h>

#define SCREEN_W 400
#define SCREEN_H 240
#define ROW_BYTES 52 /* the frame buffer is 1 bit per pixel, 52 bytes per 400 pixel row */

#define CELL_M 0.5f          /* world meters per terrain cell */
#define BEDROCK_CM (-300)    /* undiggable floor, 3 m below the original ground */
#define MAX_HEIGHT_CM 900    /* tallest hill that can be piled up */
#define TREE_ZONE_M 8.0f     /* depth of the tree band along each edge */
/* Edits are confined to the field inside the tree band (plus a margin for the tree canopies) so
   the ground under a trunk never changes. */
#define EDIT_MARGIN_M (TREE_ZONE_M + 1.5f)

/* Grade blade: the largest ramp slope (rise over run) it will ever cut. Kept below the
   excavator's climb limit so graded ramps are always drivable. */
#define GRADE_MAX_SLOPE 0.55f

/* Dirt slumping: the steepest height difference (cm) allowed between 4-neighbour cells.
   32 cm over a 0.5 m cell is about 33 degrees - the "angle of repose" of loose dirt. */
#define REPOSE_CM 32

#define MAT_GRASS 0
#define MAT_DIRT 1
#define MAT_ROCK 2

typedef struct {
	int16_t h;  /* height in centimeters */
	uint8_t c;  /* precomputed base brightness 0..255 (material + lighting) */
	uint8_t m;  /* material: MAT_* */
} TCell;

#define QUALITY_LEVELS 6

/* Allocator hook. main.c points it at the Playdate allocator; hosts default to realloc. */
extern void* (*terrain_realloc)(void* ptr, size_t size);

/* Creates a new size x size field (flat-ish rolling grass ringed by trees). Returns 0 on failure. */
int terrain_init(int size, uint32_t seed);
void terrain_free(void);
int terrain_size(void);
float terrain_world_size(void);

/* Terrain height in meters, bilinear. Outside the field it is 0. */
float terrain_height(float x, float y);

/* Sum of all cell heights as a volume in m^3. A diagnostic used to check that edits conserve dirt. */
double terrain_total_volume(void);

/* ---- Persistence ----
   Only the edits are stored, as run-length encoded differences from the generated field (see
   terrain.c), so the file is tiny unless the whole field has been reshaped. The terrain code does
   no file I/O itself: the caller supplies a sink / source, which keeps it testable on the host. */

/* Receives a chunk of the save file. Return 1 on success, 0 on failure. */
typedef int (*TerrainSink)(void* ctx, const void* data, size_t len);
/* Fills buf with up to len bytes of the save file. Return the byte count, 0 at end, <0 on error. */
typedef int (*TerrainSource)(void* ctx, void* buf, size_t len);

/* Writes the current ground. Clears the dirty flag on success. Returns 1 on success. */
int terrain_save(TerrainSink sink, void* ctx);

/* Builds a size x size field for `seed` and applies the saved edits on top. Returns 1 if a save
   was applied. Returns 0 if the data is missing, truncated, or was made for another size or seed;
   in every case the terrain is left as a valid field (a fresh one on failure). */
int terrain_load(int size, uint32_t seed, TerrainSource src, void* ctx);

/* True when the ground has changed since the last successful save or load. */
int terrain_dirty(void);

/* Removes dirt around (x, y) down to a bowl-shaped profile whose lowest point is tipZ,
   never deeper than bedrock and never more than maxVol m^3. Returns the volume removed. */
float terrain_dig(float x, float y, float tipZ, float radius, float maxVol);

/* Deposits up to vol m^3 in a cone around (x, y), never raising ground above topZ.
   Returns the volume actually deposited. */
float terrain_dump(float x, float y, float topZ, float radius, float vol);

/* Grade blade. Levels the ground inside a rectangle centred on (cx, cy), oriented along yaw
   (halfLen along the heading, halfWid across it). The target is the best-fit straight ramp
   along the heading, level across it, so blading a pile onto flat ground leaves a clean slope.
   The ramp's mean height is unchanged (dirt is redistributed, not created) and its slope is
   capped at GRADE_MAX_SLOPE. blend (0..1) is how far to move towards the target this call. */
void terrain_grade(float cx, float cy, float yaw, float halfLen, float halfWid, float blend);

/* Optional slumping: steep dirt relaxes towards REPOSE_CM per cell over following frames. */
void terrain_set_slumping(int enabled);
int terrain_get_slumping(void);
/* Relaxes at most `budget` queued cells (bounds the per-frame cost). Returns cells that moved. */
int terrain_slump_step(int budget);

/* cam = {x, y, z, yaw, pitch, roll}. Draws the ground, sky and trees into a 1-bit frame buffer. */
void terrain_render(uint8_t* frame, const float cam[6]);

/* Ground occlusion, for drawing things (the excavator arm) over the finished frame.
   After terrain_render, this fills the rectangle x0..x1, y0..y1 (inclusive, screen pixels) of a
   1-bit stencil bitmap (same packing as the frame buffer, 1 = white): pixels that the nearer
   ground hides from the camera at the given depth (meters along the view direction) become
   black, the rest white. Pixels outside the rectangle are left alone. Used as a stencil image,
   it lets Lua draw an object only where it is not buried behind or under terrain. */
void terrain_occlusion_mask(uint8_t* data, int rowBytes, float depth, int x0, int y0, int x1, int y1);

int terrain_get_quality(void);
/* level >= 0 pins the quality; level < 0 returns to automatic adaptation. */
void terrain_set_quality(int level);
/* Feeds the measured frame cost in ms; returns the (possibly adjusted) quality level. */
int terrain_adapt(float render_ms);

#endif
