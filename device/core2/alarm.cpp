#include "alarm.h"
#include <M5Unified.h>
#include <FastLED.h>

static const int LED_PIN = 25;   // SK6812 bar on Core2 for AWS
static const int LED_COUNT = 10;
static CRGB leds[LED_COUNT];
static bool wasWarn = false;
static bool silenced = false;

static void setBar(CRGB c) {
  for (int i = 0; i < LED_COUNT; i++) leds[i] = c;
  FastLED.show();
}

void alarmInit() {
  FastLED.addLeds<SK6812, LED_PIN, GRB>(leds, LED_COUNT);
  FastLED.setBrightness(40);
  setBar(CRGB::Black);
}

void alarmUpdate(bool warn, bool touched) {
  if (warn && !wasWarn) {
    silenced = false;
    setBar(CRGB::Red);
    M5.Speaker.tone(1000, 200);   // one 200 ms beep at 1 kHz
  } else if (!warn && wasWarn) {
    setBar(CRGB::Black);
  } else if (warn && touched && !silenced) {
    silenced = true;
    setBar(CRGB::Black);
  }
  wasWarn = warn;
}
