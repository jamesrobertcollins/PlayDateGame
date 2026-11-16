#include "terrain.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#define FOCAL 230.0f
#define NEAR_T 2.0f
#define BILINEAR_DIST 22.0f
#define MAXSTEPS 256
#define FOG_V 238
#define MAX_TREES 2048
#define MAX_VISIBLE 512
#define ADAPT_HIGH_MS 22.0f
#define ADAPT_LOW_MS 13.0f

void* (*terrain_realloc)(void*, size_t) = realloc;

typedef struct {
	float x, y;
	float h, r;   /* total height and canopy radius, meters */
	int16_t gcm;  /* ground height under the trunk, cm */
} Tree;

typedef struct {
	int colStep;
	float maxDist;
} QLevel;

static const QLevel QL[QUALITY_LEVELS] = {
	{2, 45.0f}, {2, 70.0f}, {2, 100.0f}, {1, 60.0f}, {1, 85.0f}, {1, 110.0f},
};

static TCell* g_cells;
static int g_n;
static Tree g_trees[MAX_TREES];
static int g_ntrees;
static uint8_t g_thr[64];
static uint32_t g_seed;

static int g_q = 1;
static int g_manualQ;
static float g_avgMs = 16.0f;
static int g_upCount;
static int g_failLevel = -1;
static int g_failTimer;

static float s_T[MAXSTEPS];
static float s_INV[MAXSTEPS];
static uint8_t s_fog[MAXSTEPS];
static int s_steps;
static int s_nearSteps;
static int s_builtQ = -1;
static uint8_t s_hist[SCREEN_W * MAXSTEPS];

static const float LIGHT_X = -0.45f, LIGHT_Y = 0.35f, LIGHT_Z = 0.82f;

static uint32_t hash2(int x, int y, uint32_t s)
{
	uint32_t h = (uint32_t)x * 374761393u + (uint32_t)y * 668265263u + s * 2246822519u;
	h = (h ^ (h >> 13)) * 1274126177u;
	return h ^ (h >> 16);
}

static float vnoise(float x, float y, float period, uint32_t seed)
{
	x /= period;
	y /= period;
	int ix = (int)floorf(x), iy = (int)floorf(y);
	float tx = x - (float)ix, ty = y - (float)iy;
	tx = tx * tx * (3.0f - 2.0f * tx);
	ty = ty * ty * (3.0f - 2.0f * ty);
	float a = (float)(hash2(ix, iy, seed) & 0xFFFF) / 65535.0f;
	float b = (float)(hash2(ix + 1, iy, seed) & 0xFFFF) / 65535.0f;
	float c = (float)(hash2(ix, iy + 1, seed) & 0xFFFF) / 65535.0f;
	float d = (float)(hash2(ix + 1, iy + 1, seed) & 0xFFFF) / 65535.0f;
	return (a + (b - a) * tx) * (1.0f - ty) + (c + (d - c) * tx) * ty;
}

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
			if ((h1 & 15) == 0) continue;
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

int terrain_init(int size, uint32_t seed)
{
	terrain_free();
	build_dither();
	g_cells = (TCell*)terrain_realloc(NULL, (size_t)size * (size_t)size * sizeof(TCell));
	if (!g_cells) return 0;
	g_n = size;
	g_seed = seed;

	for (int j = 0; j < size; j++) {
		for (int i = 0; i < size; i++) {
			float n = (vnoise((float)i, (float)j, 22.0f, seed) * 2.0f - 1.0f) * 70.0f
			        + (vnoise((float)i, (float)j, 7.0f, seed + 9u) * 2.0f - 1.0f) * 16.0f;
			TCell* c = &g_cells[j * size + i];
			c->h = (int16_t)n;
			c->m = MAT_GRASS;
			c->c = 150;
		}
	}
	for (int j = 0; j < size; j++)
		for (int i = 0; i < size; i++)
			shade_cell(i, j);

	place_trees(seed);
	s_builtQ = -1;
	return 1;
}

void terrain_free(void)
{
	if (g_cells) terrain_realloc(g_cells, 0);
	g_cells = NULL;
	g_n = 0;
	g_ntrees = 0;
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

int terrain_get_quality(void) { return g_q; }

static int edit_allowed(float x, float y)
{
	float world = terrain_world_size();
	return x >= TREE_ZONE_M && y >= TREE_ZONE_M && x <= world - TREE_ZONE_M && y <= world - TREE_ZONE_M;
}

static void edit_bounds(float x, float y, float radius, int* i0, int* j0, int* i1, int* j1)
{
	*i0 = (int)floorf((x - radius) * (1.0f / CELL_M));
	*i1 = (int)ceilf((x + radius) * (1.0f / CELL_M));
	*j0 = (int)floorf((y - radius) * (1.0f / CELL_M));
	*j1 = (int)ceilf((y + radius) * (1.0f / CELL_M));
	if (*i0 < 0) *i0 = 0;
	if (*j0 < 0) *j0 = 0;
	if (*i1 > g_n - 1) *i1 = g_n - 1;
	if (*j1 > g_n - 1) *j1 = g_n - 1;
}

/* Lighting depends on neighbouring heights, so reshade one ring beyond the edited area. */
static void reshade_rect(int i0, int j0, int i1, int j1)
{
	if (i0 > 0) i0--;
	if (j0 > 0) j0--;
	if (i1 < g_n - 1) i1++;
	if (j1 < g_n - 1) j1++;
	for (int j = j0; j <= j1; j++)
		for (int i = i0; i <= i1; i++)
			shade_cell(i, j);
}

float terrain_dig(float x, float y, float tipZ, float radius, float maxVol)
{
	if (!g_cells || maxVol <= 0.0f || !edit_allowed(x, y)) return 0.0f;
	int i0, j0, i1, j1;
	edit_bounds(x, y, radius, &i0, &j0, &i1, &j1);
	const float r2 = radius * radius;
	const float tipcm = tipZ * 100.0f;
	const float cellVol = 0.01f * CELL_M * CELL_M;

	float total = 0.0f;
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
			TCell* c = &g_cells[j * g_n + i];
			float excess = (float)c->h - t;
			if (excess <= 0.0f) continue;
			int rm = (int)(excess * scale + 0.5f);
			if (rm <= 0) continue;
			c->h = (int16_t)(c->h - rm);
			c->m = c->h <= BEDROCK_CM + 6 ? MAT_ROCK : MAT_DIRT;
			removedCm += rm;
		}
	}
	reshade_rect(i0, j0, i1, j1);
	return (float)removedCm * cellVol;
}

float terrain_dump(float x, float y, float topZ, float radius, float vol)
{
	if (!g_cells || vol <= 0.0f || !edit_allowed(x, y)) return 0.0f;
	int i0, j0, i1, j1;
	edit_bounds(x, y, radius, &i0, &j0, &i1, &j1);
	const float capcm = topZ * 100.0f < (float)MAX_HEIGHT_CM ? topZ * 100.0f : (float)MAX_HEIGHT_CM;
	const float cellVol = 0.01f * CELL_M * CELL_M;

	float sumW = 0.0f;
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
			TCell* c = &g_cells[j * g_n + i];
			if (d >= radius || (float)c->h >= capcm) continue;
			int add = (int)(cmPerWeight * (1.0f - d / radius) + 0.5f);
			if ((float)(c->h + add) > capcm) add = (int)(capcm - (float)c->h);
			if (add <= 0) continue;
			c->h = (int16_t)(c->h + add);
			c->m = MAT_DIRT;
			addedCm += add;
		}
	}
	reshade_rect(i0, j0, i1, j1);
	return (float)addedCm * cellVol;
}

void terrain_set_quality(int level)
{
	if (level < 0) {
		g_manualQ = 0;
		return;
	}
	g_manualQ = 1;
	g_q = level >= QUALITY_LEVELS ? QUALITY_LEVELS - 1 : level;
}

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

static int vis_cmp(const void* a, const void* b)
{
	float da = ((const VisTree*)a)->d, db = ((const VisTree*)b)->d;
	return da < db ? 1 : (da > db ? -1 : 0);
}

typedef struct {
	float cx, cy, camcm;
	float fx, fy, rx, ry;
	float horBase, rollK;
	int step;
} View;

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
		float dx = vw.fx + vw.rx * u, dy = vw.fy + vw.ry * u;
		float hor = vw.horBase - vw.rollK * xc;
		int ybuf = SCREEN_H;
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
					if (recordHist && i + 1 < s_steps) memset(&hist[i + 1], 0, (size_t)(s_steps - i - 1));
					break;
				}
			}
		}
		if (ybuf > 0) draw_sky(fb, col, ybuf, (int)hor, step);
	}

	if (recordHist) draw_trees(fb, &vw, QL[g_q].maxDist);
}
