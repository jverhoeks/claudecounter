#include "orient.h"
#include <M5Unified.h>

// Hysteresis: a NEW orientation needs its axis above G_ENTER for
// ORIENT_HOLD_MS; the current one is kept until its axis drops below
// G_LEAVE. Small wobbles around 45 degrees therefore never flip.
static const float G_ENTER = 0.75f;
static const float G_LEAVE = 0.45f;
static const uint32_t ORIENT_HOLD_MS = 800;

static Orient current = Orient::Unknown;
static Orient candidate = Orient::Unknown;
static uint32_t candidateSince = 0;
static float lax = 0, lay = 0, laz = 0;

// Axis → orientation mapping. If a side comes out mirrored on your unit,
// swap the two entries of the affected pair (Left/Right or Down/Up).
static Orient classify(float ax, float ay, float az, float thresh) {
  if (fabsf(az) > 0.75f) return Orient::Unknown;        // lying flat
  // Signs verified on a Core2 for AWS: upright landscape reads ay > 0,
  // standing on the side with the buttons to the left reads ax > 0.
  if (fabsf(ay) >= fabsf(ax)) {
    if (ay >  thresh) return Orient::ButtonsDown;
    if (ay < -thresh) return Orient::ButtonsUp;
  } else {
    if (ax < -thresh) return Orient::ButtonsRight;
    if (ax >  thresh) return Orient::ButtonsLeft;
  }
  return Orient::Unknown;
}

// Gravity still on the current orientation's axis above G_LEAVE?
static bool stillHolding(Orient o, float ax, float ay) {
  switch (o) {
    case Orient::ButtonsDown:  return ay >  G_LEAVE;
    case Orient::ButtonsUp:    return ay < -G_LEAVE;
    case Orient::ButtonsRight: return ax < -G_LEAVE;
    case Orient::ButtonsLeft:  return ax >  G_LEAVE;
    default: return false;
  }
}

Orient orientPoll() {
  if (!M5.Imu.isEnabled()) return Orient::Unknown;
  M5.Imu.update();
  auto d = M5.Imu.getImuData();
  lax = d.accel.x; lay = d.accel.y; laz = d.accel.z;
  if (current != Orient::Unknown && stillHolding(current, lax, lay)) {
    candidate = Orient::Unknown;
    return Orient::Unknown;
  }
  Orient o = classify(lax, lay, laz, G_ENTER);
  if (o == Orient::Unknown) { candidate = Orient::Unknown; return Orient::Unknown; }
  if (o != candidate) { candidate = o; candidateSince = millis(); return Orient::Unknown; }
  if (millis() - candidateSince < ORIENT_HOLD_MS) return Orient::Unknown;
  if (o == current) return Orient::Unknown;
  current = o;
  return o;
}

const char* orientName(Orient o) {
  switch (o) {
    case Orient::ButtonsDown: return "buttons-down";
    case Orient::ButtonsUp: return "buttons-up";
    case Orient::ButtonsLeft: return "buttons-left";
    case Orient::ButtonsRight: return "buttons-right";
    default: return "unknown";
  }
}

void orientRaw(float& ax, float& ay, float& az) { ax = lax; ay = lay; az = laz; }
