/*
 * hosttest.c - host-side test harness for the terrain core (src/terrain.c).
 *
 * Builds and runs on the PC without the Playdate SDK, which makes the terrain logic quick to
 * test. It checks that dirt is conserved by dig / dump / grade / slump, that slumping enforces
 * the angle of repose, that a graded ramp is drivable, and that edits cannot reach the tree
 * band. It also renders frames to build/ as .raw files (convert them with tools/raw2png.py to look at
 * them) and prints host timings.
 *
 * Run from the repository root:  .\build.ps1 -HostTest
 * Exits non-zero if any check fails.
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "../src/terrain.h"

static int g_failures;

#define CHECK(cond, ...)                                  \
	do {                                                  \
		if (cond) {                                       \
			printf("  ok   ");                            \
		} else {                                          \
			printf("  FAIL ");                            \
			g_failures++;                                 \
		}                                                 \
		printf(__VA_ARGS__);                              \
		printf("\n");                                     \
	} while (0)

static double now_ms(void)
{
	return (double)clock() * 1000.0 / CLOCKS_PER_SEC;
}

static uint8_t g_frame[ROW_BYTES * SCREEN_H];

/* Renders one view and writes the raw 1-bit frame buffer to build/<name>.raw. */
static void dump_frame(const char* name, const float cam[6])
{
	char path[128];
	memset(g_frame, 0, sizeof g_frame);
	terrain_render(g_frame, cam);
	snprintf(path, sizeof path, "build/%s.raw", name);
	FILE* f = fopen(path, "wb");
	if (!f) return;
	fwrite(g_frame, 1, sizeof g_frame, f);
	fclose(f);
}

/* Height of one cell in centimeters (the bilinear sample is exact on cell corners). */
static int cell_cm(int i, int j)
{
	return (int)lrintf(terrain_height((float)i * CELL_M, (float)j * CELL_M) * 100.0f);
}

/* Largest height difference between 4-neighbour cells in the editable field. */
static int max_neighbour_diff(void)
{
	int n = terrain_size(), lo = (int)ceilf(EDIT_MARGIN_M / CELL_M), hi = n - 1 - lo, worst = 0;
	for (int j = lo; j < hi; j++) {
		for (int i = lo; i < hi; i++) {
			int h = cell_cm(i, j);
			int dx = abs(h - cell_cm(i + 1, j)), dy = abs(h - cell_cm(i, j + 1));
			if (dx > worst) worst = dx;
			if (dy > worst) worst = dy;
		}
	}
	return worst;
}

/* Piles about 3 m^3 of dirt in a steep cone at (x, y) by dumping in small amounts. */
static float build_pile(float x, float y)
{
	float total = 0.0f;
	for (int k = 0; k < 80; k++) total += terrain_dump(x, y, 2.0f, 1.2f, 0.05f);
	return total;
}

static void test_rendering(void)
{
	printf("rendering\n");
	float world = terrain_world_size();
	const float cam[6] = { world * 0.5f, world * 0.5f, 2.3f, 0.0f, -0.30f, 0.0f };
	static uint8_t frame[ROW_BYTES * SCREEN_H];
	for (int q = 0; q < QUALITY_LEVELS; q++) {
		terrain_set_quality(q);
		terrain_render(frame, cam); /* warm up: builds the step table */
		double t0 = now_ms();
		for (int r = 0; r < 20; r++) terrain_render(frame, cam);
		printf("  quality %d: %.2f ms/frame (host)\n", q, (now_ms() - t0) / 20.0);
	}
	terrain_set_quality(2);
	dump_frame("host_center", cam);
	const float trees[6] = { world - 14.0f, world * 0.5f, 2.3f, 0.0f, -0.30f, 0.0f };
	dump_frame("host_trees", trees);
	const float tilted[6] = { world * 0.5f, world * 0.5f, 2.3f, 0.8f, -0.20f, 0.25f };
	dump_frame("host_tilted", tilted);
}

static void test_dig_dump(void)
{
	printf("dig and dump\n");
	terrain_set_slumping(0);
	float cx = terrain_world_size() * 0.5f, cy = cx;
	double v0 = terrain_total_volume();

	float dug = 0.0f;
	for (int k = 0; k < 40; k++) dug += terrain_dig(cx + 6.0f, cy, -5.0f, 0.7f, 100.0f);
	CHECK(fabsf(terrain_height(cx + 6.0f, cy) - (-3.0f)) < 0.02f, "pit stops at bedrock (%.2f m)", terrain_height(cx + 6.0f, cy));
	CHECK(fabs(v0 - terrain_total_volume() - dug) < 0.01, "dug volume matches the ground lost (%.3f m3)", dug);

	/* a request larger than the bucket is scaled back to maxVol */
	float capped = terrain_dig(cx - 6.0f, cy, -1.0f, 1.2f, 0.2f);
	CHECK(capped > 0.15f && capped <= 0.21f, "dig respects maxVol (%.3f of 0.200 m3)", capped);

	float dumped = 0.0f, left = dug;
	for (int k = 0; k < 400 && left > 0.0f; k++) {
		float d = terrain_dump(cx + 6.0f, cy - 2.5f, 2.0f, 1.2f, left < 0.05f ? left : 0.05f);
		dumped += d;
		left -= d;
	}
	CHECK(fabsf(dumped - dug) < 0.05f, "dumped volume matches dug volume (%.3f vs %.3f m3)", dumped, dug);
	CHECK(terrain_height(cx + 6.0f, cy - 2.5f) <= 2.001f, "pile is capped at topZ (%.2f m)", terrain_height(cx + 6.0f, cy - 2.5f));

	const float cam[6] = { cx, cy, 2.3f, 0.0f, -0.30f, 0.0f };
	dump_frame("host_edit", cam);

	float before = terrain_height(6.0f, 6.0f);
	CHECK(terrain_dig(6.0f, 6.0f, -3.0f, 1.0f, 5.0f) == 0.0f && terrain_height(6.0f, 6.0f) == before,
	      "edits cannot reach the tree band");
}

static void test_slump(void)
{
	printf("slumping\n");
	float cx = terrain_world_size() * 0.5f, cy = cx;
	terrain_set_slumping(1);
	build_pile(cx, cy);
	int steepBefore = max_neighbour_diff();
	double v0 = terrain_total_volume();

	int idle = 0, calls = 0;
	while (idle < 50 && calls < 20000) {
		idle = terrain_slump_step(48) == 0 ? idle + 1 : 0;
		calls++;
	}
	int steepAfter = max_neighbour_diff();
	CHECK(steepBefore > REPOSE_CM, "fresh pile is steeper than repose (%d cm/cell)", steepBefore);
	CHECK(steepAfter <= REPOSE_CM, "settled pile obeys repose (%d <= %d cm/cell, %d steps)", steepAfter, REPOSE_CM, calls);
	CHECK(fabs(terrain_total_volume() - v0) < 1e-6, "slumping conserves dirt exactly");
	CHECK(terrain_height(cx, cy) < 2.0f, "pile top came down (%.2f m)", terrain_height(cx, cy));

	const float cam[6] = { cx - 9.0f, cy, 2.3f, 0.0f, -0.30f, 0.0f };
	dump_frame("host_slump", cam);

	terrain_set_slumping(0);
	build_pile(cx + 10.0f, cy + 10.0f);
	CHECK(terrain_slump_step(48) == 0, "nothing moves while slumping is off");
}

static void test_grade(void)
{
	printf("grade blade\n");
	float world = terrain_world_size(), cx = world * 0.5f, cy = cx;
	terrain_set_slumping(0);
	const float pileX = cx + 8.0f;
	build_pile(pileX, cy);

	const float cam[6] = { cx - 2.0f, cy, 2.3f, 0.0f, -0.30f, 0.0f };
	dump_frame("host_ramp_before", cam);

	/* sweep the machine towards the pile with the blade down, as the game does each frame:
	   strip starts 1.9 m ahead of the machine centre and is 4.5 m long, 3.2 m wide */
	double v0 = terrain_total_volume();
	for (float mx = cx - 4.0f; mx < pileX - 2.0f; mx += 0.12f)
		for (int pass = 0; pass < 2; pass++)
			terrain_grade(mx + 1.9f + 2.25f, cy, 0.0f, 2.25f, 1.6f, 0.15f);
	double v1 = terrain_total_volume();
	CHECK(fabs(v1 - v0) < 0.06, "grading moves dirt without creating it (change %.4f m3)", v1 - v0);

	/* drivability: pitch of a 3.4 m long machine at every point along the ramp */
	float worstPitch = 0.0f, topBefore = 2.0f;
	for (float x = cx - 2.0f; x < pileX + 4.0f; x += 0.25f) {
		float rise = fabsf(terrain_height(x + 1.7f, cy) - terrain_height(x - 1.7f, cy)) / 3.4f;
		if (rise > worstPitch) worstPitch = rise;
	}
	CHECK(worstPitch < 0.62f, "ramp is within the 32 degree climb limit (worst slope %.2f)", worstPitch);
	CHECK(terrain_height(pileX, cy) < topBefore - 0.05f, "pile top was cut down (%.2f m)", terrain_height(pileX, cy));

	float lateral = fabsf(terrain_height(pileX - 4.0f, cy - 1.0f) - terrain_height(pileX - 4.0f, cy + 1.0f));
	CHECK(lateral < 0.08f, "ramp is level side to side (%.3f m)", lateral);

	dump_frame("host_ramp_after", cam);
}

int main(int argc, char** argv)
{
	int size = argc > 1 ? atoi(argv[1]) : 256;
	if (!terrain_init(size, 12345u)) return 2;
	printf("size=%d world=%.1fm\n", size, (double)terrain_world_size());
	test_rendering();

	terrain_init(size, 12345u);
	test_dig_dump();
	terrain_init(size, 777u);
	test_slump();
	terrain_init(size, 4242u);
	test_grade();

	printf("%s (%d failures)\n", g_failures ? "FAILED" : "ALL PASSED", g_failures);
	return g_failures ? 1 : 0;
}
