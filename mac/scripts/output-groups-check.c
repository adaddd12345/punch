#include "BassShakeRT.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

// The render adapter's responsibility is channel placement, not DSP. A
// transparent engine makes accidental channel swaps/duplication visible.
void punch_process_interleaved(PunchEngine* e, const float* in, float* out, int channels, int frames) {
  (void)e;
  memcpy(out, in, (size_t)channels * frames * sizeof(float));
}

int main(void) {
  float input[8] = { .1f, -.2f, .3f, -.4f, .5f, -.6f, .7f, -.8f };
  float first[32], second[8];
  struct { UInt32 count; AudioBuffer buffers[2]; } outputs = { 2, { {8, sizeof(first), first}, {2, sizeof(second), second} } };
  AudioBufferList inputs = { 1, {{2, sizeof(input), input}} };
  AudioTimeStamp time = {0};
  BSRenderContext* ctx = BSRenderContextCreate((PunchEngine*)1);
  assert(ctx);
  int32_t map[] = {0, 1, -1, -1, -1, -1, -1, -1, 0, 1};
  assert(BSRenderContextSetOutputMap(ctx, map, 10));
  BSRenderContextFadeIn(ctx, 48000, 0);
  assert(BSIOProc(0, &time, &inputs, &time, (AudioBufferList*)&outputs, &time, ctx) == 0);
  for (int frame = 0; frame < 4; ++frame) {
    assert(first[frame * 8] == input[frame * 2]);
    assert(first[frame * 8 + 1] == input[frame * 2 + 1]);
    for (int c = 2; c < 8; ++c) assert(first[frame * 8 + c] == 0);
    assert(second[frame * 2] == input[frame * 2]);
    assert(second[frame * 2 + 1] == input[frame * 2 + 1]);
  }
  // A disconnected/reconfigured member must not shift audio onto wrong channels.
  outputs.count = 1;
  BSIOProc(0, &time, &inputs, &time, (AudioBufferList*)&outputs, &time, ctx);
  for (int i = 0; i < 32; ++i) assert(first[i] == 0);
  assert(BSRenderContextStats(ctx).deadOutputCallbacks == 1);
  assert(!BSRenderContextSetOutputMap(ctx, map, 129));
  int32_t invalid[] = { -2 };
  assert(!BSRenderContextSetOutputMap(ctx, invalid, 1));
  // No group map preserves the existing single-output layout.
  assert(BSRenderContextSetOutputMap(ctx, map, 0));
  BSIOProc(0, &time, &inputs, &time, (AudioBufferList*)&outputs, &time, ctx);
  assert(first[0] == .1f && first[1] == -.2f && first[2] == 0);
  BSRenderContextDestroy(ctx);
  puts("Output group render: stereo fan-out, unused channels, disconnect guard and single-device regression passed");
}
