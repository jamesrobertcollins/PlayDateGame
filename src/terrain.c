/*
 * terrain.c - heightfield terrain: generation, editing and the voxel-space renderer.
 *
 * Layout of this file:
 *   1. constants, quality levels and module state
 *   2. small helpers (hash noise, dither table, per-cell shading)
 *   3. generation (terrain_init, tree placement)
 *   4. editing (dig, dump, grade blade, slumping) and the shading/slump work queues
 *   5. adaptive quality
 *   6. the renderer (ground columns, sky, billboard trees)
 */
#include "terrain.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------------------------------------ */
/* 1. Constants and state                                                                      */
/* ------------------------------------------------------------------------------------------ */

#define FOCAL 230.0f          /* focal length in pixels; must match FOCAL in Source/view.lua */
#define NEAR_T 2.0f           /* closest ray distance rendered, meters */
#define BILINEAR_DIST 22.0f   /* inside this distance ground height is interpolated, else nearest */
#define MAXSTEPS 256          /* upper bound on ray steps per column */
#define FOG_V 238             /* brightness distant terrain fades towards (matches the sky) */
#define MAX_TREES 2048
#define MAX_VISIBLE 512       /* trees drawn per frame */
#define ADAPT_HIGH_MS 22.0f   /* above this average frame cost, drop quality */
#define ADAPT_LOW_MS 13.0f    /* below this, quality may rise */

#define SLUMP_QUEUE_CAP 8192  /* cells waiting to be relaxed */
#define SHADE_LIST_CAP 2048   /* cells waiting to be re-lit */
#define F_QUEUED 1            /* per-cell flag: already in the slump queue */
#define F_SHADE 2             /* per-cell flag: already in the shade list */
#define F_MOD 4               /* per-cell flag: edited at some point (saved explicitly) */

#define SAVE_MAGIC "XCV1"     /* file signature + format version */
#define SAVE_HEADER_BYTES 10  /* magic, u16 size, u32 seed */
#define SAVE_BUF 1024         /* streaming buffer for save and load */

void* (*terrain_realloc)(void*, size_t) = realloc;

typedef struct {
	float x, y;
	float h, r;   /* total height and canopy radius, meters */
	int16_t gcm;  /* ground height under the trunk, cm */
} Tree;

/* One quality level: horizontal resolution (1 = every column, 2 = every other column, each drawn
   two pixels wide) and how far rays travel. The adaptive controller moves between these. */
typedef struct {
	int colStep;
	float maxDist;
} QLevel;

static const QLevel QL[QUALITY_LEVELS] = {
	{2, 45.0f}, {2, 70.0f}, {2, 100.0f}, {1, 60.0f}, {1, 85.0f}, {1, 110.0f},
};

static TCell* g_cells;       /* g_n * g_n cells, row major */
static uint8_t* g_flags;     /* F_* bits per cell, same indexing as g_cells */
static int g_n;              /* cells per side */
static int g_lo, g_hi;       /* editable cell index range, inclusive (inside the tree band) */
static Tree g_trees[MAX_TREES];
static int g_ntrees;
static uint8_t g_thr[64];    /* 8x8 ordered-dither thresholds, row major, scaled to 0..255 */
static uint32_t g_seed;

static int g_slump;                          /* slumping enabled */
static uint32_t g_queue[SLUMP_QUEUE_CAP];    /* ring buffer of cell indices */
static int g_qhead, g_qcount;
static uint32_t g_shadeList[SHADE_LIST_CAP]; /* unique cells whose lighting is stale */
static int g_nshade;
static float g_gradeResid;                   /* rounding remainder carried between grade steps */
static int g_dirty;                          /* ground changed since the last save/load */

/* Adaptive quality state. */
static int g_q = 1;
static int g_manualQ;
static float g_avgMs = 16.0f;
static int g_upCount;
static int g_failLevel = -1;
static int g_failTimer;

/* Per-quality ray step table, rebuilt whenever the quality changes. */
static float s_T[MAXSTEPS];       /* distance of each step */
static float s_INV[MAXSTEPS];     /* FOCAL / (distance in cm): converts a height difference to pixels */
static uint8_t s_fog[MAXSTEPS];   /* fog amount 0..255 at each step */
static int s_steps;
static int s_nearSteps;           /* steps that still use bilinear height */
static int s_builtQ = -1;
/* For every drawn column and step, the screen row the ground occluded down to at that step.
   Trees use it to clip themselves behind nearer terrain. */
static uint8_t s_hist[SCREEN_W * MAXSTEPS];

/* Direction towards the sun, used for the baked slope lighting. */
static const float LIGHT_X = -0.45f, LIGHT_Y = 0.35f, LIGHT_Z = 0.82f;

/* ------------------------------------------------------------------------------------------ */
/* 2. Helpers                                                                                  */
/* ------------------------------------------------------------------------------------------ */

/* Cheap integer hash used for deterministic noise and tree placement. */
static uint32_t hash2(int x, int y, uint32_t s)
{
	uint32_t h = (uint32_t)x * 374761393u + (uint32_t)y * 668265263u + s * 2246822519u;
	h = (h ^ (h >> 13)) * 1274126177u;
	return h ^ (h >> 16);
}

/* Smooth value noise in 0..1; period is the feature size in cells. */
static float vnoise(float x, float y, float period, uint32_t seed)
{
	x /= period;
	y /= period;
	int ix = (int)floorf(x), iy = (int)floorf(y);
	float tx = x - (float)ix, ty = y - (float)iy;
	tx = tx * tx * (3.0f - 2.0f * tx); /* smoothstep so cell borders blend without creases */
	ty = ty * ty * (3.0f - 2.0f * ty);
	float a = (float)(hash2(ix, iy, seed) & 0xFFFF) / 65535.0f;
	float b = (float)(hash2(ix + 1, iy, seed) & 0xFFFF) / 65535.0f;
	float c = (float)(hash2(ix, iy + 1, seed) & 0xFFFF) / 65535.0f;
	float d = (float)(hash2(ix + 1, iy + 1, seed) & 0xFFFF) / 65535.0f;
	return (a + (b - a) * tx) * (1.0f - ty) + (c + (d - c) * tx) * ty;
}

/* 8x8 Bayer matrix. A brightness v (0..255) lights a pixel where v exceeds the threshold, which
   turns grey levels into the stipple patterns a 1-bit screen can show. */
static void build_dither(void)
{
	static const uint8_t bayer[64] = {
		0, 32, 8, 40, 2, 34, 10, 42, 48, 16, 56, 24, 50, 18, 58, 26,
		12, 44, 4, 36, 14, 46, 6, 38, 60, 28, 52, 20, 62, 30, 54, 22,
		3, 35, 11, 43, 1, 33, 9, 41, 51, 19, 59, 27, 49, 17, 57, 25,
		15, 47, 7, 39, 13, 45, 5, 37, 63, 31, 55, 23, 61, 29, 53, 21,
	};
	for (int i = 0; i < 64; i++)
		g_thr[i] = (uint8_t)(bayer[i] * 4 + 2);
}

/* Recomputes a cell's baked brightness from its material and the slope around it (central
   differences of the neighbouring heights, Lambert-style against LIGHT_*). Slope contrast is
   exaggerated so dug holes and piles read clearly in 1-bit. */
static void shade_cell(int i, int j)
{
	int n = g_n;
	int im = i > 0 ? i - 1 : i, ip = i < n - 1 ? i + 1 : i;
	int jm = j > 0 ? j - 1 : j, jp = j < n - 1 ? j + 1 : j;
	TCell* c = &g_cells[j * n + i];
	float dx = (float)(g_cells[j * n + ip].h - g_cells[j * n + im].h) * (0.01f / ((float)(ip - im) * CELL_M));
	float dy = (float)(g_cells[jp * n + i].h - g_cells[jm * n + i].h) * (0.01f / ((float)(jp - jm) * CELL_M));
	float inv = 1.0f / sqrtf(dx * dx + dy * dy + 1.0f);
	float shade = 1.0f + (((-dx * LIGHT_X - dy * LIGHT_Y + LIGHT_Z) * inv) / LIGHT_Z - 1.0f) * 2.2f;
	if (shade < 0.35f) shade = 0.35f;
	if (shade > 1.4f) shade = 1.4f;

	float base;
	int noise;
	uint32_t hv = hash2(i, j, 77u);
	switch (c->m) {
	case MAT_DIRT: base = 88.0f; noise = (int)(hv & 15) - 8; break;
	case MAT_ROCK: base = 72.0f; noise = (int)(hv & 15) - 8; break;
	default:
		/* per-cell speckle plus low-frequency patches so open grass isn't a flat tone */
		base = 150.0f;
		noise = (int)(hv & 31) - 16 + (int)((vnoise((float)i, (float)j, 4.0f, g_seed + 31u) - 0.5f) * 56.0f);
		break;
	}
	int v = (int)(base * shade) + noise;
	c->c = (uint8_t)(v < 0 ? 0 : (v > 255 ? 255 : v));
}

/* ------------------------------------------------------------------------------------------ */
/* 3. Generation                                                                               */
/* ------------------------------------------------------------------------------------------ */

/* Fills a band TREE_ZONE_M deep along every edge with jittered, randomly thinned trees. Trees
   are billboards: only a position, size and the ground height under the trunk are kept. */
static void place_trees(uint32_t seed)
{
	const float spacing = 3.0f;
	float world = terrain_world_size();
	int gn = (int)(world / spacing);
	g_ntrees = 0;
	for (int gy = 0; gy < gn; gy++) {
		for (int gx = 0; gx < gn; gx++) {
			float cx = ((float)gx + 0.5f) * spacing, cy = ((float)gy + 0.5f) * spacing;
			float edge = cx < world - cx ? cx : world - cx;
			float edgeY = cy < world - cy ? cy : world - cy;
			if (edgeY < edge) edge = edgeY;
			if (edge > TREE_ZONE_M) continue;

			uint32_t h1 = hash2(gx, gy, seed + 1u), h2 = hash2(gx, gy, seed + 2u), h3 = hash2(gx, gy, seed + 3u);
			if ((h1 & 15) == 0) continue; /* leave an occasional gap */
			if (g_ntrees >= MAX_TREES) return;
			Tree* t = &g_trees[g_ntrees++];
			t->x = cx + ((float)(h1 >> 8 & 255) / 255.0f - 0.5f) * 2.4f;
			t->y = cy + ((float)(h2 >> 8 & 255) / 255.0f - 0.5f) * 2.4f;
			t->h = 7.0f + (float)(h3 & 255) / 255.0f * 5.0f;
			t->r = 1.4f + (float)(h3 >> 8 & 255) / 255.0f * 0.9f;
			t->gcm = (int16_t)(terrain_height(t->x, t->y) * 100.0f);
		}
	}
}

/* Ground height of the untouched field, in centimeters. Two octaves of noise give gentle rolling
   ground (about +-0.9 m). This is deterministic in (i, j, seed), which is what lets a save file
   store only the difference from it. */
static int16_t base_height(int i, int j, uint32_t seed)
{
	float n = (vnoise((float)i, (float)j, 22.0f, seed) * 2.0f - 1.0f) * 70.0f
	        + (vnoise((float)i, (float)j, 7.0f, seed + 9u) * 2.0f - 1.0f) * 16.0f;
	return (int16_t)n;
}

/* Allocates the grid and fills it with the untouched field (no lighting, no trees yet). */
static int generate(int size, uint32_t seed)
{
	terrain_free();
	build_dither();
	g_cells = (TCell*)terrain_realloc(NULL, (size_t)size * (size_t)size * sizeof(TCell));
	g_flags = (uint8_t*)terrain_realloc(NULL, (size_t)size * (size_t)size);
	if (!g_cells || !g_flags) {
		terrain_free();
		return 0;
	}
	memset(g_flags, 0, (size_t)size * (size_t)size);
	g_n = size;
	g_seed = seed;
	g_lo = (int)ceilf(EDIT_MARGIN_M / CELL_M);
	g_hi = size - 1 - g_lo;
	g_qhead = g_qcount = g_nshade = 0;
	g_gradeResid = 0.0f;

	for (int j = 0; j < size; j++) {
		for (int i = 0; i < size; i++) {
			TCell* c = &g_cells[j * size + i];
			c->h = base_height(i, j, seed);
			c->m = MAT_GRASS;
			c->c = 150;
		}
	}
	return 1;
}

/* Lighting needs every height to exist first, so it is a pass of its own. */
static void shade_all(void)
{
	for (int j = 0; j < g_n; j++)
		for (int i = 0; i < g_n; i++)
			shade_cell(i, j);
}

int terrain_init(int size, uint32_t seed)
{
	if (!generate(size, seed)) return 0;
	shade_all();
	place_trees(seed);
	s_builtQ = -1;
	g_dirty = 1; /* the file on disk (if any) no longer matches */
	return 1;
}

void terrain_free(void)
{
	if (g_cells) terrain_realloc(g_cells, 0);
	if (g_flags) terrain_realloc(g_flags, 0);
	g_cells = NULL;
	g_flags = NULL;
	g_n = 0;
	g_ntrees = 0;
	g_qhead = g_qcount = g_nshade = 0;
}

int terrain_size(void) { return g_n; }
float terrain_world_size(void) { return (float)g_n * CELL_M; }

float terrain_height(float x, float y)
{
	if (!g_cells) return 0.0f;
	float fx = x * (1.0f / CELL_M), fy = y * (1.0f / CELL_M);
	if (fx < 0.0f || fy < 0.0f || fx >= (float)(g_n - 1) || fy >= (float)(g_n - 1)) return 0.0f;
	int ix = (int)fx, iy = (int)fy;
	float tx = fx - (float)ix, ty = fy - (float)iy;
	const TCell* p = &g_cells[iy * g_n + ix];
	float a = (float)p[0].h, b = (float)p[1].h, c = (float)p[g_n].h, d = (float)p[g_n + 1].h;
	return ((a + (b - a) * tx) * (1.0f - ty) + (c + (d - c) * tx) * ty) * 0.01f;
}

double terrain_total_volume(void)
{
	double sum = 0.0;
	for (int k = 0; k < g_n * g_n; k++) sum += g_cells[k].h;
	return sum * 0.01 * (double)(CELL_M * CELL_M);
}

/* ------------------------------------------------------------------------------------------ */
/* 3b. Saving and loading                                                                      */
/* ------------------------------------------------------------------------------------------ */

/* File format (little endian):
     "XCV1"  u16 size  u32 seed
     then run-length records covering the grid in row-major order:
       u16 count  i16 diff  u8 material
   `diff` is the cell's height minus the untouched field's height. Cells that were never edited
   are all diff 0 / grass, so a mostly untouched field is a handful of bytes, and saving only
   has to recompute the untouched height for cells flagged F_MOD. Loading regenerates the field
   from the seed and applies the differences on top. */

typedef struct {
	TerrainSink sink;
	void* ctx;
	uint8_t buf[SAVE_BUF];
	int n;
	int ok;
} Out;

static void out_flush(Out* o)
{
	if (o->n > 0 && o->ok) o->ok = o->sink(o->ctx, o->buf, (size_t)o->n);
	o->n = 0;
}

static void out_bytes(Out* o, const uint8_t* d, int len)
{
	for (int k = 0; k < len; k++) {
		if (o->n == SAVE_BUF) out_flush(o);
		o->buf[o->n++] = d[k];
	}
}

static void out_record(Out* o, int count, int diff, uint8_t mat)
{
	uint8_t r[5] = { (uint8_t)(count & 255), (uint8_t)(count >> 8),
	                 (uint8_t)(diff & 255), (uint8_t)((diff >> 8) & 255), mat };
	out_bytes(o, r, 5);
}

int terrain_save(TerrainSink sink, void* ctx)
{
	if (!g_cells || !sink) return 0;
	static Out o; /* static: the buffer is too big for the small device stack */
	o.sink = sink;
	o.ctx = ctx;
	o.n = 0;
	o.ok = 1;

	uint8_t hdr[SAVE_HEADER_BYTES] = { 'X', 'C', 'V', '1', (uint8_t)(g_n & 255), (uint8_t)(g_n >> 8),
	                                   (uint8_t)(g_seed & 255), (uint8_t)((g_seed >> 8) & 255),
	                                   (uint8_t)((g_seed >> 16) & 255), (uint8_t)(g_seed >> 24) };
	out_bytes(&o, hdr, SAVE_HEADER_BYTES);

	const int total = g_n * g_n;
	int run = 0, runDiff = 0;
	uint8_t runMat = MAT_GRASS;
	for (int k = 0; k < total; k++) {
		int diff = 0;
		uint8_t mat = MAT_GRASS;
		if (g_flags[k] & F_MOD) {
			diff = g_cells[k].h - base_height(k % g_n, k / g_n, g_seed);
			mat = g_cells[k].m;
		}
		if (run > 0 && diff == runDiff && mat == runMat && run < 65535) {
			run++;
		} else {
			if (run > 0) out_record(&o, run, runDiff, runMat);
			run = 1;
			runDiff = diff;
			runMat = mat;
		}
	}
	if (run > 0) out_record(&o, run, runDiff, runMat);
	out_flush(&o);
	if (o.ok) g_dirty = 0;
	return o.ok;
}

typedef struct {
	TerrainSource src;
	void* ctx;
	uint8_t buf[SAVE_BUF];
	int pos, len;
} In;

/* Reads exactly n bytes through the buffer; returns 0 at end of data. */
static int in_get(In* in, uint8_t* out, int n)
{
	for (int k = 0; k < n; k++) {
		if (in->pos == in->len) {
			in->len = (int)in->src(in->ctx, in->buf, SAVE_BUF);
			in->pos = 0;
			if (in->len <= 0) {
				in->len = 0;
				return 0;
			}
		}
		out[k] = in->buf[in->pos++];
	}
	return 1;
}

static int clamp_cm(int h)
{
	return h < BEDROCK_CM ? BEDROCK_CM : (h > MAX_HEIGHT_CM ? MAX_HEIGHT_CM : h);
}

int terrain_load(int size, uint32_t seed, TerrainSource src, void* ctx)
{
	static In in;
	uint8_t hdr[SAVE_HEADER_BYTES];
	in.src = src;
	in.ctx = ctx;
	in.pos = in.len = 0;

	/* The header is checked before anything is generated, so a missing or stale file costs only
	   one normal field generation. */
	int ok = src && in_get(&in, hdr, SAVE_HEADER_BYTES) && memcmp(hdr, SAVE_MAGIC, 4) == 0;
	if (ok) {
		int fileSize = hdr[4] | (hdr[5] << 8);
		uint32_t fileSeed = (uint32_t)hdr[6] | ((uint32_t)hdr[7] << 8) | ((uint32_t)hdr[8] << 16) | ((uint32_t)hdr[9] << 24);
		ok = fileSize == size && fileSeed == seed;
	}
	if (!ok) {
		terrain_init(size, seed);
		return 0;
	}

	if (!generate(size, seed)) return 0;
	const int total = size * size;
	int k = 0;
	while (k < total) {
		uint8_t r[5];
		if (!in_get(&in, r, 5)) break;
		int count = r[0] | (r[1] << 8);
		int diff = (int16_t)(r[2] | (r[3] << 8));
		uint8_t mat = r[4];
		if (count == 0 || k + count > total || mat > MAT_ROCK) break;
		if (diff != 0 || mat != MAT_GRASS) {
			for (int e = k; e < k + count; e++) {
				g_cells[e].h = (int16_t)clamp_cm(g_cells[e].h + diff);
				g_cells[e].m = mat;
				g_flags[e] |= F_MOD;
			}
		}
		k += count;
	}
	if (k != total) {
		/* truncated or corrupt: fall back to a clean field rather than a half-loaded one */
		terrain_init(size, seed);
		return 0;
	}
	shade_all();
	place_trees(seed);
	s_builtQ = -1;
	g_dirty = 0;
	return 1;
}

int terrain_dirty(void) { return g_dirty; }

/* ------------------------------------------------------------------------------------------ */
/* 4. Editing                                                                                  */
/* ------------------------------------------------------------------------------------------ */

/* Queues a cell for re-lighting (once - F_SHADE de-duplicates). If the list is full the cell is
   lit immediately instead so no update is ever lost. */
static void mark_shade(int i, int j)
{
	int idx = j * g_n + i;
	if (g_flags[idx] & F_SHADE) return;
	if (g_nshade < SHADE_LIST_CAP) {
		g_flags[idx] |= F_SHADE;
		g_shadeList[g_nshade++] = (uint32_t)idx;
	} else {
		shade_cell(i, j);
	}
}

/* Re-lights every queued cell. Called once at the end of each edit so a cell touched many times
   in one edit is only lit once. */
static void flush_shade(void)
{
	for (int k = 0; k < g_nshade; k++) {
		uint32_t idx = g_shadeList[k];
		shade_cell((int)(idx % (uint32_t)g_n), (int)(idx / (uint32_t)g_n));
		g_flags[idx] &= (uint8_t)~F_SHADE;
	}
	g_nshade = 0;
}

/* Adds a cell to the slump queue (no-op when slumping is off, the cell is already queued, or the
   queue is full - a dropped cell simply is not relaxed). */
static void queue_slump(int i, int j)
{
	if (!g_slump || i < g_lo || i > g_hi || j < g_lo || j > g_hi) return;
	int idx = j * g_n + i;
	if ((g_flags[idx] & F_QUEUED) || g_qcount >= SLUMP_QUEUE_CAP) return;
	g_flags[idx] |= F_QUEUED;
	g_queue[(g_qhead + g_qcount) % SLUMP_QUEUE_CAP] = (uint32_t)idx;
	g_qcount++;
}

/* Must be called whenever a cell's height changes. Its lighting (and its neighbours', which read
   its height) becomes stale, and the cell plus its 4 neighbours may now be too steep. */
static void cell_changed(int i, int j)
{
	for (int dj = -1; dj <= 1; dj++) {
		for (int di = -1; di <= 1; di++) {
			int ni = i + di, nj = j + dj;
			if (ni >= 0 && nj >= 0 && ni < g_n && nj < g_n) mark_shade(ni, nj);
		}
	}
	queue_slump(i, j);
	queue_slump(i - 1, j);
	queue_slump(i + 1, j);
	queue_slump(i, j - 1);
	queue_slump(i, j + 1);
}

/* Cell rectangle covering a circle of the given radius, clamped to the editable field.
   Returns 0 when the circle does not touch any editable cell. */
static int edit_bounds(float x, float y, float radius, int* i0, int* j0, int* i1, int* j1)
{
	*i0 = (int)floorf((x - radius) * (1.0f / CELL_M));
	*i1 = (int)ceilf((x + radius) * (1.0f / CELL_M));
	*j0 = (int)floorf((y - radius) * (1.0f / CELL_M));
	*j1 = (int)ceilf((y + radius) * (1.0f / CELL_M));
	if (*i0 < g_lo) *i0 = g_lo;
	if (*j0 < g_lo) *j0 = g_lo;
	if (*i1 > g_hi) *i1 = g_hi;
	if (*j1 > g_hi) *j1 = g_hi;
	return *i0 <= *i1 && *j0 <= *j1;
}

/* Rock where the ground has been dug down to the bedrock floor, dirt elsewhere. */
static uint8_t material_for(int h)
{
	return h <= BEDROCK_CM + 6 ? MAT_ROCK : MAT_DIRT;
}

/* Sets a cell's height and material after an edit and schedules the follow-up work. */
static void set_cell(int i, int j, int newH, uint8_t mat)
{
	int idx = j * g_n + i;
	TCell* c = &g_cells[idx];
	c->h = (int16_t)newH;
	c->m = mat;
	g_flags[idx] |= F_MOD; /* the save file must store this cell explicitly */
	g_dirty = 1;
	cell_changed(i, j);
}

/* Dig: carves a shallow bowl (lowest at the bucket tip, rising 40 cm to the rim) and removes
   whatever lies above it. If that is more than maxVol the cut is scaled back proportionally so
   the bucket never takes more than it can hold. Two passes: measure, then apply. */
float terrain_dig(float x, float y, float tipZ, float radius, float maxVol)
{
	int i0, j0, i1, j1;
	if (!g_cells || maxVol <= 0.0f || !edit_bounds(x, y, radius, &i0, &j0, &i1, &j1)) return 0.0f;
	const float r2 = radius * radius;
	const float tipcm = tipZ * 100.0f;
	const float cellVol = 0.01f * CELL_M * CELL_M; /* m^3 per centimeter of height in one cell */

	float total = 0.0f; /* total cm of dirt above the bowl, summed over cells */
	for (int j = j0; j <= j1; j++) {
		for (int i = i0; i <= i1; i++) {
			float dx = (float)i * CELL_M - x, dy = (float)j * CELL_M - y;
			float d2 = dx * dx + dy * dy;
			if (d2 > r2) continue;
			float t = tipcm + 40.0f * (d2 / r2);
			if (t < (float)BEDROCK_CM) t = (float)BEDROCK_CM;
			float excess = (float)g_cells[j * g_n + i].h - t;
			if (excess > 0.0f) total += excess;
		}
	}
	if (total * cellVol <= 1e-4f) return 0.0f;
	float scale = total * cellVol > maxVol ? maxVol / (total * cellVol) : 1.0f;

	int removedCm = 0;
	for (int j = j0; j <= j1; j++) {
		for (int i = i0; i <= i1; i++) {
			float dx = (float)i * CELL_M - x, dy = (float)j * CELL_M - y;
			float d2 = dx * dx + dy * dy;
			if (d2 > r2) continue;
			float t = tipcm + 40.0f * (d2 / r2);
			if (t < (float)BEDROCK_CM) t = (float)BEDROCK_CM;
			float excess = (float)g_cells[j * g_n + i].h - t;
			if (excess <= 0.0f) continue;
			int rm = (int)(excess * scale + 0.5f);
			if (rm <= 0) continue;
			set_cell(i, j, g_cells[j * g_n + i].h - rm, material_for(g_cells[j * g_n + i].h - rm));
			removedCm += rm;
		}
	}
	flush_shade();
	return (float)removedCm * cellVol;
}

/* Dump: spreads vol over a cone (tallest in the middle) by giving each cell a share proportional
   to its weight. Cells already at the cap (topZ or MAX_HEIGHT_CM) take nothing, so the returned
   volume can be less than requested and the caller keeps the remainder in the bucket. */
float terrain_dump(float x, float y, float topZ, float radius, float vol)
{
	int i0, j0, i1, j1;
	if (!g_cells || vol <= 0.0f || !edit_bounds(x, y, radius, &i0, &j0, &i1, &j1)) return 0.0f;
	const float capcm = topZ * 100.0f < (float)MAX_HEIGHT_CM ? topZ * 100.0f : (float)MAX_HEIGHT_CM;
	const float cellVol = 0.01f * CELL_M * CELL_M;

	float sumW = 0.0f; /* total cone weight over cells that can still receive dirt */
	for (int j = j0; j <= j1; j++) {
		for (int i = i0; i <= i1; i++) {
			float dx = (float)i * CELL_M - x, dy = (float)j * CELL_M - y;
			float d = sqrtf(dx * dx + dy * dy);
			if (d >= radius || (float)g_cells[j * g_n + i].h >= capcm) continue;
			sumW += 1.0f - d / radius;
		}
	}
	if (sumW <= 0.0f) return 0.0f;
	float cmPerWeight = vol / (cellVol * sumW);

	int addedCm = 0;
	for (int j = j0; j <= j1; j++) {
		for (int i = i0; i <= i1; i++) {
			float dx = (float)i * CELL_M - x, dy = (float)j * CELL_M - y;
			float d = sqrtf(dx * dx + dy * dy);
			int h = g_cells[j * g_n + i].h;
			if (d >= radius || (float)h >= capcm) continue;
			int add = (int)(cmPerWeight * (1.0f - d / radius) + 0.5f);
			if ((float)(h + add) > capcm) add = (int)(capcm - (float)h);
			if (add <= 0) continue;
			set_cell(i, j, h + add, MAT_DIRT);
			addedCm += add;
		}
	}
	flush_shade();
	return (float)addedCm * cellVol;
}

/* Grade blade. Fits a straight line (height against distance u along the heading) through the
   cells in the rectangle by least squares, then moves each cell a fraction `blend` of the way to
   that line. Because the line passes through the mean height of the cells, high spots and low
   spots trade dirt and the total is unchanged (up to centimeter rounding and the clamps below).
   The slope is clamped to GRADE_MAX_SLOPE; the line is level across the heading so ramps are
   flat from side to side. */
void terrain_grade(float cx, float cy, float yaw, float halfLen, float halfWid, float blend)
{
	int i0, j0, i1, j1;
	if (!g_cells || blend <= 0.0f) return;
	if (!edit_bounds(cx, cy, halfLen + halfWid, &i0, &j0, &i1, &j1)) return;
	const float c = cosf(yaw), s = sinf(yaw);

	/* pass 1: accumulate the sums for the regression of h on u */
	int cnt = 0;
	float su = 0.0f, sh = 0.0f, suu = 0.0f, suh = 0.0f;
	for (int j = j0; j <= j1; j++) {
		for (int i = i0; i <= i1; i++) {
			float dx = (float)i * CELL_M - cx, dy = (float)j * CELL_M - cy;
			float u = dx * c + dy * s;   /* along the heading */
			float v = -dx * s + dy * c;  /* across it */
			if (fabsf(u) > halfLen || fabsf(v) > halfWid) continue;
			float h = (float)g_cells[j * g_n + i].h;
			cnt++;
			su += u;
			sh += h;
			suu += u * u;
			suh += u * h;
		}
	}
	if (cnt < 4) return;

	const float meanU = su / (float)cnt, meanH = sh / (float)cnt;
	const float varU = suu - (float)cnt * meanU * meanU;
	const float covUH = suh - (float)cnt * meanU * meanH;
	float slope = varU > 1e-3f ? covUH / varU : 0.0f; /* cm of height per meter along heading */
	const float maxSlope = GRADE_MAX_SLOPE * 100.0f;
	if (slope > maxSlope) slope = maxSlope;
	if (slope < -maxSlope) slope = -maxSlope;

	/* pass 2: ease every cell towards the target line. Heights are whole centimeters, so each
	   step is rounded; the rounding remainder is carried to the next cell (error diffusion,
	   persisted between calls) so tiny per-cell steps still add up and the net change in dirt
	   stays within half a centimeter instead of drifting. */
	for (int j = j0; j <= j1; j++) {
		for (int i = i0; i <= i1; i++) {
			float dx = (float)i * CELL_M - cx, dy = (float)j * CELL_M - cy;
			float u = dx * c + dy * s;
			float v = -dx * s + dy * c;
			if (fabsf(u) > halfLen || fabsf(v) > halfWid) continue;
			int h = g_cells[j * g_n + i].h;
			float target = meanH + slope * (u - meanU);
			if (target < (float)BEDROCK_CM) target = (float)BEDROCK_CM;
			if (target > (float)MAX_HEIGHT_CM) target = (float)MAX_HEIGHT_CM;
			float want = (target - (float)h) * blend + g_gradeResid;
			int step = (int)lrintf(want);
			g_gradeResid = want - (float)step;
			if (step != 0) set_cell(i, j, h + step, step > 0 ? MAT_DIRT : material_for(h + step));
		}
	}
	flush_shade();
}

void terrain_set_slumping(int enabled)
{
	g_slump = enabled != 0;
	if (!g_slump) {
		/* drop pending work so a later re-enable starts clean */
		while (g_qcount > 0) {
			g_flags[g_queue[g_qhead]] &= (uint8_t)~F_QUEUED;
			g_qhead = (g_qhead + 1) % SLUMP_QUEUE_CAP;
			g_qcount--;
		}
	}
}

int terrain_get_slumping(void) { return g_slump; }

/* Angle-of-repose relaxation. Pops up to `budget` cells; for each of its 4 neighbours that is
   more than REPOSE_CM lower, moves just enough dirt across to bring the pair back within the
   limit. Moving dirt between two cells conserves the total. Changed cells are re-queued, so a
   collapse keeps spreading over the following calls until the slope is stable. */
int terrain_slump_step(int budget)
{
	static const int dI[4] = { 1, -1, 0, 0 };
	static const int dJ[4] = { 0, 0, 1, -1 };
	int moved = 0;
	if (!g_slump || !g_cells) return 0;

	while (budget-- > 0 && g_qcount > 0) {
		uint32_t idx = g_queue[g_qhead];
		g_qhead = (g_qhead + 1) % SLUMP_QUEUE_CAP;
		g_qcount--;
		g_flags[idx] &= (uint8_t)~F_QUEUED;

		int i = (int)(idx % (uint32_t)g_n), j = (int)(idx / (uint32_t)g_n);
		for (int k = 0; k < 4; k++) {
			int ni = i + dI[k], nj = j + dJ[k];
			if (ni < g_lo || ni > g_hi || nj < g_lo || nj > g_hi) continue;
			TCell* from = &g_cells[idx];
			TCell* to = &g_cells[nj * g_n + ni];
			int diff = from->h - to->h;
			if (diff <= REPOSE_CM) continue;
			int mv = (diff - REPOSE_CM + 1) / 2; /* ceil: leaves the pair at or inside the limit */
			set_cell(i, j, from->h - mv, material_for(from->h - mv));
			set_cell(ni, nj, to->h + mv, MAT_DIRT);
			moved++;
		}
	}
	flush_shade();
	return moved;
}

/* ------------------------------------------------------------------------------------------ */
/* 5. Adaptive quality                                                                         */
/* ------------------------------------------------------------------------------------------ */

int terrain_get_quality(void) { return g_q; }

void terrain_set_quality(int level)
{
	if (level < 0) {
		g_manualQ = 0;
		return;
	}
	g_manualQ = 1;
	g_q = level >= QUALITY_LEVELS ? QUALITY_LEVELS - 1 : level;
}

/* Smooths the measured cost, drops a level quickly when it is over budget and raises one slowly
   when there is headroom. After a drop, the level that failed is not retried for ~20 s so the
   controller does not oscillate at the edge of what the device can do. */
int terrain_adapt(float render_ms)
{
	if (g_manualQ) return g_q;
	if (g_failTimer > 0) g_failTimer--;
	g_avgMs = g_avgMs * 0.9f + render_ms * 0.1f;

	if (g_avgMs > ADAPT_HIGH_MS && g_q > 0) {
		g_failLevel = g_q;
		g_failTimer = 600;
		g_q--;
		g_avgMs = (ADAPT_HIGH_MS + ADAPT_LOW_MS) * 0.5f;
		g_upCount = 0;
	} else if (g_avgMs < ADAPT_LOW_MS && g_q < QUALITY_LEVELS - 1) {
		int blocked = (g_q + 1 == g_failLevel) && g_failTimer > 0;
		if (!blocked && ++g_upCount > 60) {
			g_q++;
			g_avgMs = (ADAPT_HIGH_MS + ADAPT_LOW_MS) * 0.5f;
			g_upCount = 0;
		}
	} else {
		g_upCount = 0;
	}
	return g_q;
}

/* ------------------------------------------------------------------------------------------ */
/* 6. Renderer                                                                                 */
/* ------------------------------------------------------------------------------------------ */

/* Builds the table of ray distances for the current quality. Step size grows with distance
   (distant detail is small on screen anyway). Fog is quadratic in distance. */
static void build_steps(void)
{
	const QLevel* q = &QL[g_q];
	float t = NEAR_T;
	int i = 0;
	s_nearSteps = 0;
	while (t < q->maxDist && i < MAXSTEPS) {
		float f = t / q->maxDist;
		f *= f;
		s_T[i] = t;
		s_INV[i] = FOCAL / (t * 100.0f);
		s_fog[i] = (uint8_t)(f * 255.0f);
		if (t < BILINEAR_DIST) s_nearSteps = i + 1;
		t += 0.25f + t * 0.012f;
		i++;
	}
	s_steps = i;
	s_builtQ = g_q;
}

/* Draws a vertical run of pixels [y0, y1) in column x (and x+1 when step == 2) at brightness v,
   dithered with the Bayer matrix. Writes straight into the 1-bit frame buffer. */
static inline void draw_span(uint8_t* fb, int x, int y0, int y1, int v, int step)
{
	uint8_t* p = fb + y0 * ROW_BYTES + (x >> 3);
	int xa = x & 7;
	if (step == 2) {
		uint8_t keep = (uint8_t)~(0xC0 >> xa), a = (uint8_t)(0x80 >> xa), b = (uint8_t)(0x40 >> xa);
		int xb = (x + 1) & 7;
		for (int y = y0; y < y1; y++) {
			const uint8_t* th = g_thr + ((y & 7) << 3);
			*p = (uint8_t)((*p & keep) | (v > th[xa] ? a : 0) | (v > th[xb] ? b : 0));
			p += ROW_BYTES;
		}
	} else {
		uint8_t m = (uint8_t)(0x80 >> xa);
		for (int y = y0; y < y1; y++) {
			const uint8_t* th = g_thr + ((y & 7) << 3);
			*p = (uint8_t)((*p & ~m) | (v > th[xa] ? m : 0));
			p += ROW_BYTES;
		}
	}
}

/* Sky gradient above the horizon: brightest at the horizon, darkening upwards. hor is the
   horizon row for this column (it moves with pitch and roll). */
static inline void draw_sky(uint8_t* fb, int x, int y1, int hor, int step)
{
	uint8_t* p = fb + (x >> 3);
	int xa = x & 7, xb = (x + 1) & 7;
	uint8_t keep2 = (uint8_t)~(0xC0 >> xa), a = (uint8_t)(0x80 >> xa), b = (uint8_t)(0x40 >> xa);
	for (int y = 0; y < y1; y++) {
		int v = 246 - ((hor - y) >> 1);
		if (v < 150) v = 150;
		if (v > 246) v = 246;
		const uint8_t* th = g_thr + ((y & 7) << 3);
		if (step == 2)
			*p = (uint8_t)((*p & keep2) | (v > th[xa] ? a : 0) | (v > th[xb] ? b : 0));
		else
			*p = (uint8_t)((*p & ~a) | (v > th[xa] ? a : 0));
		p += ROW_BYTES;
	}
}

typedef struct {
	float d;
	int i;
} VisTree;

/* qsort comparator: farthest tree first (painter's algorithm). */
static int vis_cmp(const void* a, const void* b)
{
	float da = ((const VisTree*)a)->d, db = ((const VisTree*)b)->d;
	return da < db ? 1 : (da > db ? -1 : 0);
}

/* Per-frame camera values shared with the tree drawing code. */
typedef struct {
	float cx, cy, camcm;     /* camera position; height in cm */
	float fx, fy, rx, ry;    /* forward and right unit vectors on the ground plane */
	float horBase, rollK;    /* horizon row at screen centre, and its slope per pixel (roll) */
	int step;                /* column step of the current quality level */
} View;

/* Draws one pixel column of one tree: a three-tier conifer canopy over a thin trunk, shaded by
   horizontal offset, fogged by distance, and clipped to the ground that was drawn in front of it
   (si indexes the ray step nearest the tree, s_hist gives that column's occlusion row). */
static void draw_tree_column(uint8_t* fb, const View* vw, const Tree* tr, float d, float sx, float hwpx, int x, int si)
{
	int hc = x & ~(vw->step - 1);
	int ycut = s_hist[hc * MAXSTEPS + si];
	if (ycut <= 0) return;

	float scale = FOCAL / d;
	float horx = vw->horBase - vw->rollK * ((float)x + 0.5f - SCREEN_W * 0.5f);
	float ybase = horx - ((float)tr->gcm - vw->camcm) * scale * 0.01f;
	float trunkH = 1.4f;
	float ycanBot = ybase - trunkH * scale;
	float canopyH = (tr->h - trunkH) * scale;
	float off = ((float)x + 0.5f - sx) / hwpx;
	float a = fabsf(off);
	if (a > 1.0f) return;

	/* three stacked cones: widest at the bottom */
	float edge = 0.0f;
	for (int k = 0; k < 3; k++) {
		float w = 1.0f - 0.24f * (float)k;
		if (a < w) {
			float e = 0.3f * (float)k + 0.55f * (1.0f - a / w);
			if (e > edge) edge = e;
		}
	}
	if (edge > 0.0f) {
		int ytop = (int)(ycanBot - edge * canopyH);
		int ybot = (int)ycanBot;
		if (ytop < 0) ytop = 0;
		if (ybot > ycut) ybot = ycut;
		int fog = s_fog[si];
		int base = 64 - (int)(off * 34.0f);
		uint8_t* p = fb + ytop * ROW_BYTES + (x >> 3);
		uint8_t m = (uint8_t)(0x80 >> (x & 7));
		for (int y = ytop; y < ybot; y++) {
			int v = base + (int)(hash2(x >> 1, y >> 1, 5u) & 31) - 14;
			v += ((FOG_V - v) * fog) >> 8;
			const uint8_t* th = g_thr + ((y & 7) << 3);
			*p = (uint8_t)((*p & ~m) | (v > th[x & 7] ? m : 0));
			p += ROW_BYTES;
		}
	}
	if (a < 0.1f) {
		int ytop = (int)ycanBot, ybot = (int)ybase;
		if (ytop < 0) ytop = 0;
		if (ybot > ycut) ybot = ycut;
		if (ytop < ybot) {
			int v = 55 + (((FOG_V - 55) * s_fog[si]) >> 8);
			draw_span(fb, x, ytop, ybot, v, 1);
		}
	}
}

/* Collects trees in view, sorts them far to near and draws them column by column. */
static void draw_trees(uint8_t* fb, const View* vw, float maxDist)
{
	static VisTree vis[MAX_VISIBLE];
	int nv = 0;
	for (int i = 0; i < g_ntrees && nv < MAX_VISIBLE; i++) {
		const Tree* t = &g_trees[i];
		float dx = t->x - vw->cx, dy = t->y - vw->cy;
		float d = dx * vw->fx + dy * vw->fy;
		if (d < NEAR_T || d >= maxDist) continue;
		float u = dx * vw->rx + dy * vw->ry;
		float sx = SCREEN_W * 0.5f + u * FOCAL / d;
		float hw = t->r * FOCAL / d;
		if (sx + hw < 0.0f || sx - hw > (float)SCREEN_W) continue;
		vis[nv].d = d;
		vis[nv].i = i;
		nv++;
	}
	qsort(vis, (size_t)nv, sizeof(VisTree), vis_cmp);

	for (int k = 0; k < nv; k++) {
		const Tree* t = &g_trees[vis[k].i];
		float d = vis[k].d;
		/* binary search for the ray step at the tree's distance */
		int lo = 0, hi = s_steps;
		while (lo < hi) {
			int mid = (lo + hi) >> 1;
			if (s_T[mid] < d) lo = mid + 1; else hi = mid;
		}
		if (lo >= s_steps) continue;

		float dx = t->x - vw->cx, dy = t->y - vw->cy;
		float u = dx * vw->rx + dy * vw->ry;
		float sx = SCREEN_W * 0.5f + u * FOCAL / d;
		float hwpx = t->r * FOCAL / d;
		int xl = (int)(sx - hwpx), xr = (int)(sx + hwpx);
		if (xl < 0) xl = 0;
		if (xr > SCREEN_W - 1) xr = SCREEN_W - 1;
		for (int x = xl; x <= xr; x++)
			draw_tree_column(fb, vw, t, d, sx, hwpx, x, lo);
	}
}

/* Voxel-space rendering. For every screen column a ray marches outward over the terrain from
   near to far. At each step the ground height is projected to a screen row; whenever that row is
   above everything drawn so far (ybuf), the newly visible slice of ground is filled in. Pitch
   moves the horizon row, roll shears it across the screen. Then trees are drawn over the top. */
void terrain_render(uint8_t* fb, const float cam[6])
{
	if (!g_cells) return;
	if (s_builtQ != g_q) build_steps();

	const int step = QL[g_q].colStep;
	const int n = g_n;
	const float invC = 1.0f / CELL_M;

	View vw;
	vw.cx = cam[0];
	vw.cy = cam[1];
	vw.camcm = cam[2] * 100.0f;
	vw.fx = cosf(cam[3]);
	vw.fy = sinf(cam[3]);
	vw.rx = vw.fy;
	vw.ry = -vw.fx;
	vw.horBase = SCREEN_H * 0.5f + FOCAL * tanf(cam[4]);
	vw.rollK = tanf(cam[5]);
	vw.step = step;

	const int recordHist = g_ntrees > 0;
	const float invFocal = 1.0f / FOCAL;

	for (int col = 0; col < SCREEN_W; col += step) {
		float xc = (float)col + (float)step * 0.5f - SCREEN_W * 0.5f;
		float u = xc * invFocal;
		float dx = vw.fx + vw.rx * u, dy = vw.fy + vw.ry * u; /* ray direction for this column */
		float hor = vw.horBase - vw.rollK * xc;               /* horizon row for this column */
		int ybuf = SCREEN_H;                                   /* lowest row not yet covered */
		uint8_t* hist = &s_hist[col * MAXSTEPS];

		int i;
		for (i = 0; i < s_steps; i++) {
			if (recordHist) hist[i] = (uint8_t)ybuf;
			float t = s_T[i];
			float wx = vw.cx + dx * t, wy = vw.cy + dy * t;
			float fxx = wx * invC, fyy = wy * invC;
			float hcm;
			int c;
			if (wx >= 0.0f && wy >= 0.0f && fxx < (float)(n - 1) && fyy < (float)(n - 1)) {
				int ix = (int)fxx, iy = (int)fyy;
				const TCell* p = &g_cells[iy * n + ix];
				c = p->c;
				if (i < s_nearSteps) {
					float tx = fxx - (float)ix, ty = fyy - (float)iy;
					float a = (float)p[0].h, b = (float)p[1].h, cc = (float)p[n].h, dd = (float)p[n + 1].h;
					hcm = (a + (b - a) * tx) * (1.0f - ty) + (cc + (dd - cc) * tx) * ty;
				} else {
					hcm = (float)p->h;
				}
			} else {
				/* outside the field: flat, lightly speckled ground */
				hcm = 0.0f;
				c = 135 + (int)(hash2((int)fxx, (int)fyy, 3u) & 15);
			}

			float yf = hor - (hcm - vw.camcm) * s_INV[i];
			if (yf < (float)ybuf) {
				int y0 = yf < 0.0f ? 0 : (int)yf;
				int v = c + (((FOG_V - c) * s_fog[i]) >> 8);
				draw_span(fb, col, y0, ybuf, v, step);
				ybuf = y0;
				if (ybuf <= 0) {
					/* column is full; later steps are fully occluded for tree clipping */
					if (recordHist && i + 1 < s_steps) memset(&hist[i + 1], 0, (size_t)(s_steps - i - 1));
					break;
				}
			}
		}
		if (ybuf > 0) draw_sky(fb, col, ybuf, (int)hor, step);
	}

	if (recordHist) draw_trees(fb, &vw, QL[g_q].maxDist);
}
