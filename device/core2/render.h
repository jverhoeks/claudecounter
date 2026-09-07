#pragma once
#include "model.h"

struct HeaderState {
  int hour = -1, minute = -1;  // -1 until the clock is valid
  int wifiBars = 0;
  bool stale = false;          // payload older than 10 min
  bool offline = false;        // last fetch failed
  int offlineMinutes = 0;      // age of last good fetch when offline
};

enum class Screen { Overview = 0, Models = 1, Usage = 2 };

void renderInit();
void renderMessage(const char* line1, const char* line2);   // full-screen status
// vendorFilter is empty for "all vendors" (Models screen only).
void renderPayload(const Payload& p, const HeaderState& h, Screen screen, const String& vendorFilter);
void renderSetDim(bool dim);                                 // 30 % backlight when true

// Overview spend rows occupy y in [SPEND_Y0, SPEND_Y0 + n*SPEND_ROW_H).
// Returns the vendor whose row contains y, or "" if none.
String vendorAtY(const Payload& p, int y);
