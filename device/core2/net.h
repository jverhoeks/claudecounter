#pragma once
#include <Arduino.h>

enum class FetchStatus { Ok, Unauthorized, NoData, HttpError, NetworkError };

// Blocks until connected to any configured network or timeoutMs
// elapses. Returns connection state.
bool wifiConnect(uint32_t timeoutMs);
// Comma-separated list of configured SSIDs, for the connecting screen.
String wifiNetworkList();
// SSID currently associated, or "".
String wifiCurrentSsid();
bool wifiUp();
int  wifiBars();                 // 0..4 from RSSI
void ntpStart();                 // configTime with TZ=UTC
bool clockValid();               // true once NTP has set the clock

// GET WORKER_URL with the read token. On Ok, body holds the response.
FetchStatus fetchState(String& body, int& httpCode);
