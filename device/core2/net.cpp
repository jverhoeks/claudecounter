#include "net.h"
#include "secrets.h"
#include <WiFi.h>
#include <WiFiMulti.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <time.h>

struct WifiCred { const char* ssid; const char* pass; };
// Accept the older single-network secrets.h too.
#ifndef WIFI_NETWORKS
#define WIFI_NETWORKS { WIFI_SSID, WIFI_PASS }
#endif
static const WifiCred NETWORKS[] = { WIFI_NETWORKS };
static const int NETWORK_COUNT = sizeof(NETWORKS) / sizeof(NETWORKS[0]);

static WiFiMulti multi;
static bool multiReady = false;

bool wifiConnect(uint32_t timeoutMs) {
  if (WiFi.status() == WL_CONNECTED) return true;
  if (!multiReady) {
    WiFi.mode(WIFI_STA);
    for (int i = 0; i < NETWORK_COUNT; i++) multi.addAP(NETWORKS[i].ssid, NETWORKS[i].pass);
    multiReady = true;
  }
  // run() scans, picks the strongest configured network and connects,
  // blocking up to timeoutMs.
  return multi.run(timeoutMs) == WL_CONNECTED;
}

String wifiNetworkList() {
  String s;
  for (int i = 0; i < NETWORK_COUNT; i++) {
    if (i) s += ", ";
    s += NETWORKS[i].ssid;
  }
  return s;
}

String wifiCurrentSsid() { return WiFi.status() == WL_CONNECTED ? WiFi.SSID() : String(); }

bool wifiUp() { return WiFi.status() == WL_CONNECTED; }

int wifiBars() {
  if (!wifiUp()) return 0;
  int rssi = WiFi.RSSI();
  if (rssi > -55) return 4;
  if (rssi > -65) return 3;
  if (rssi > -75) return 2;
  return 1;
}

void ntpStart() {
  // UTC everywhere on the device; parseIso8601Utc relies on mktime
  // being UTC. The header clock is rendered in UTC too — see README.
  configTzTime("UTC0", "pool.ntp.org", "time.cloudflare.com");
}

bool clockValid() { return time(nullptr) > 1700000000; }

FetchStatus fetchState(String& body, int& httpCode) {
  httpCode = 0;
  if (!wifiUp()) return FetchStatus::NetworkError;
  WiFiClientSecure client;
  // No certificate verification: the ESP32 Arduino core ships no root
  // bundle reachable from HTTPClient without embedding a cert file.
  // The only secret at risk to a MITM on this Wi-Fi is the read-only
  // token. Documented in README.md.
  client.setInsecure();
  HTTPClient http;
  http.setTimeout(8000);
  http.setConnectTimeout(8000);
  if (!http.begin(client, WORKER_URL)) return FetchStatus::NetworkError;
  http.addHeader("Authorization", String("Bearer ") + READ_TOKEN);
  httpCode = http.GET();
  FetchStatus st;
  if (httpCode == 200) { body = http.getString(); st = FetchStatus::Ok; }
  else if (httpCode == 401) st = FetchStatus::Unauthorized;
  else if (httpCode == 404) st = FetchStatus::NoData;
  else if (httpCode > 0) st = FetchStatus::HttpError;
  else st = FetchStatus::NetworkError;
  http.end();
  return st;
}
