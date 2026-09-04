#include "model.h"
#include <ArduinoJson.h>
#include <time.h>

time_t parseIso8601Utc(const char* s) {
  struct tm t = {};
  if (!s || sscanf(s, "%4d-%2d-%2dT%2d:%2d:%2d", &t.tm_year, &t.tm_mon, &t.tm_mday,
                   &t.tm_hour, &t.tm_min, &t.tm_sec) != 6) return 0;
  t.tm_year -= 1900;
  t.tm_mon -= 1;
  // timegm is not in the ESP32 libc; mktime assumes local time, but we
  // configure the device clock with TZ=UTC (see net.cpp) so they agree.
  return mktime(&t);
}

const UsageRow* usageAlert(const Payload& p) {
  const UsageRow* worst = nullptr;
  for (int i = 0; i < p.usageCount; i++) {
    const UsageRow& u = p.usage[i];
    if (u.stale || u.pct < USAGE_ALERT_PCT) continue;
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
