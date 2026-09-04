#pragma once
#include <Arduino.h>

// Physical orientation from the accelerometer. Names describe where the
// three touch buttons are relative to the user looking at the screen.
enum class Orient { Unknown, ButtonsDown, ButtonsUp, ButtonsLeft, ButtonsRight };

// Reads the IMU. Returns a new orientation only when it has been stable
// for ORIENT_HOLD_MS and differs from the last returned one; otherwise
// Orient::Unknown. Lying flat (gravity on z) never changes orientation.
Orient orientPoll();
const char* orientName(Orient o);
// Latest raw accelerometer sample for calibration logging.
void orientRaw(float& ax, float& ay, float& az);
