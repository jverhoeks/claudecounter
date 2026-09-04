#pragma once
#include <Arduino.h>

struct VendorSpend { String vendor; float day; float week; float month; };
struct ModelRow    { String vendor; String model; float day; float month; };
struct UsageRow    { String vendor; String window; int pct; bool stale; };

struct Payload {
  bool valid = false;
  int version = 0;
  time_t at = 0;               // parsed from "at", UTC
  VendorSpend spend[4]; int spendCount = 0;
  ModelRow models[20];  int modelCount = 0;   // payload order (sorted by month spend)
  UsageRow usage[8];    int usageCount = 0;
  int warnPct = 80;
  bool hasContext = false;
  String ctxSession; int ctxPct = 0; bool ctxWarn = false;
};

// Any non-stale usage window at or above USAGE_ALERT_PCT is an alert.
// Returns the highest such row, or nullptr.
static const int USAGE_ALERT_PCT = 90;
const UsageRow* usageAlert(const Payload& p);

// Parses a v1 body. Returns false (and sets valid=false) on malformed
// JSON or a version other than 1.
bool parsePayload(const String& body, Payload& out);

// Parses "2026-09-04T10:41:00Z" into a UTC time_t; 0 on failure.
time_t parseIso8601Utc(const char* s);
