/* Host-side harness: renders frames from the terrain core and dumps raw 1-bit buffers. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "../src/terrain.h"

static double now_ms(void)
{
	return (double)clock() * 1000.0 / CLOCKS_PER_SEC;
}

int main(int argc, char** argv)
{
	int size = argc > 1 ? atoi(argv[1]) : 256;
	if (!terrain_init(size, 12345u)) return 1;

	float world = terrain_world_size();
	printf("size=%d world=%.1fm\n", size, world);

	struct { const char* name; float cam[6]; } views[] = {
		{"center", {world * 0.5f, world * 0.5f, 2.3f, 0.0f, -0.30f, 0.0f}},
		{"trees", {world - 14.0f, world * 0.5f, 2.3f, 0.0f, -0.30f, 0.0f}},
		{"tilted", {world * 0.5f, world * 0.5f, 2.3f, 0.8f, -0.20f, 0.25f}},
		{"corner", {118.5f, 64.0f, 2.3f, 0.0f, -0.30f, 0.0f}},
	};

	static uint8_t frame[ROW_BYTES * SCREEN_H];
	for (int q = 0; q < QUALITY_LEVELS; q++) {
		terrain_set_quality(q);
		memset(frame, 0, sizeof frame);
		terrain_render(frame, views[0].cam); /* warm up / build step table */
		double t0 = now_ms();
		for (int r = 0; r < 20; r++) terrain_render(frame, views[0].cam);
		printf("quality %d: %.2f ms/frame (host)\n", q, (now_ms() - t0) / 20.0);
	}

	terrain_set_quality(2);
	for (size_t v = 0; v < sizeof views / sizeof views[0]; v++) {
		char path[128];
		memset(frame, 0, sizeof frame);
		terrain_render(frame, views[v].cam);
		snprintf(path, sizeof path, "build/host_%s.raw", views[v].name);
		FILE* f = fopen(path, "wb");
		fwrite(frame, 1, sizeof frame, f);
		fclose(f);
	}
	terrain_set_quality(5);
	memset(frame, 0, sizeof frame);
	terrain_render(frame, views[1].cam);
	FILE* f = fopen("build/host_trees_hq.raw", "wb");
	fwrite(frame, 1, sizeof frame, f);
	fclose(f);

	/* Edit test: dig a pit 6 m ahead of the centre camera, pile the dirt to the right. */
	float cx = world * 0.5f, cy = world * 0.5f;
	float dug = 0.0f;
	for (int k = 0; k < 40; k++) dug += terrain_dig(cx + 6.0f, cy, -5.0f, 0.7f, 100.0f);
	float dumped = 0.0f, left = dug;
	for (int k = 0; k < 200 && left > 0.0f; k++) {
		float d = terrain_dump(cx + 6.0f, cy - 2.5f, 2.0f, 1.2f, left < 0.05f ? left : 0.05f);
		dumped += d;
		left -= d;
	}
	printf("dug=%.3f m3 dumped=%.3f m3 hole=%.2f m pile=%.2f m\n", dug, dumped,
	       terrain_height(cx + 6.0f, cy), terrain_height(cx + 6.0f, cy - 2.5f));
	float cam[6] = {cx, cy, 2.3f, 0.0f, -0.30f, 0.0f};
	memset(frame, 0, sizeof frame);
	terrain_render(frame, cam);
	f = fopen("build/host_edit.raw", "wb");
	fwrite(frame, 1, sizeof frame, f);
	fclose(f);
	return 0;
}
