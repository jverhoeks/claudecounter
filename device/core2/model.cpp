#include "model.h"
#include <ArduinoJson.h>
#include <time.h>

// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's
// algorithm). Lets us convert a UTC timestamp without timegm, which the
// ESP32 libc lacks, and independent of the device's local TZ.
static long daysFromCivil(int y, int m, int d) {
  y -= m <= 2;
  const long era = (y >= 0 ? y : y - 399) / 400;
  const unsigned yoe = (unsigned)(y - era * 400);
  const unsigned doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
  const unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  return era * 146097 + (long)doe - 719468;
}

time_t parseIso8601Utc(const char* s) {
  int Y, M, D, h, m, sec;
  if (!s || sscanf(s, "%4d-%2d-%2dT%2d:%2d:%2d", &Y, &M, &D, &h, &m, &sec) != 6) return 0;
  return (time_t)daysFromCivil(Y, M, D) * 86400 + h * 3600 + m * 60 + sec;
}

const UsageRow* usageAlert(const Payload& p) {
  const UsageRow* worst = nullptr;
  for (int i = 0; i < p.usageCount; i++) {
    const UsageRow& u = p.usage[i];
    if (u.stale || u.pct < USAGE_ALERT_PCT || u.pct >= 100) continue;
    if (!worst || u.pct > worst->pct) worst = &u;
  }
  return worst;
}

static const char* VENDOR_ORDER[] = {"claude", "codex", "grok"};

bool parsePayload(const String& body, Payload& out) {
  out = Payload();
  JsonDocument doc;
  if (deserializeJson(doc, body)) return false;
  out.version = doc["v"] | 0;
  if (out.version != 1) return false;
  out.at = parseIso8601Utc(doc["at"] | "");
  out.warnPct = doc["warnPct"] | 80;

  // Fixed vendor order so rows never reshuffle between polls.
  JsonObject spend = doc["spend"];
  for (const char* v : VENDOR_ORDER) {
    if (!spend[v].is<JsonObject>()) continue;
    if (out.spendCount >= 4) break;
    VendorSpend& s = out.spend[out.spendCount++];
    s.vendor = v;
    s.day = spend[v]["day"] | 0.0f;
    s.week = spend[v]["week"] | 0.0f;
    s.month = spend[v]["month"] | 0.0f;
  }

  for (JsonObject m : doc["models"].as<JsonArray>()) {
    if (out.modelCount >= 20) break;
    ModelRow& r = out.models[out.modelCount++];
    r.vendor = (const char*)(m["vendor"] | "");
    r.model = (const char*)(m["model"] | "");
    r.day = m["day"] | 0.0f;
    r.month = m["month"] | 0.0f;
  }

  for (JsonObject u : doc["usage"].as<JsonArray>()) {
    if (out.usageCount >= 8) break;
    UsageRow& r = out.usage[out.usageCount++];
    r.vendor = (const char*)(u["vendor"] | "");
    r.window = (const char*)(u["window"] | "");
    r.pct = u["pct"] | 0;
    r.stale = u["stale"] | false;
  }

  if (doc["context"].is<JsonObject>()) {
    out.hasContext = true;
    out.ctxSession = (const char*)(doc["context"]["session"] | "");
    out.ctxPct = doc["context"]["pct"] | 0;
    out.ctxWarn = doc["context"]["warn"] | false;
  }
  out.valid = true;
  return true;
}
