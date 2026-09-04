#pragma once

enum class AlarmLevel { None = 0, Usage = 1, Context = 2 };

void alarmInit();
// Call every loop with the current level and whether the screen was
// touched this iteration. Rising to Context: LEDs red + one beep.
// Rising to Usage (a plan window >= 90%): LEDs orange, no beep. LEDs
// hold while the level holds; any touch clears them until the level
// next rises; dropping to None turns them off.
void alarmUpdate(AlarmLevel level, bool touched);
