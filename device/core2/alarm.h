#pragma once

void alarmInit();
// Call every loop with the current warn flag and whether the screen was
// touched this iteration. Handles the rising edge (LEDs red + one beep),
// steady state (LEDs stay red), touch silence, and falling edge (off).
void alarmUpdate(bool warn, bool touched);
