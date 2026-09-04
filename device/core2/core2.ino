// M5Stack Core2 for AWS desk display for claudecounter.
// Polls the Cloudflare Worker (see ../../cloudflare/README.md) every
// 30 s and renders spend + usage. Alarms on a context-window warning.
#include <M5Unified.h>
#include <time.h>
#include "secrets.h"
#include "model.h"
#include "net.h"
#include "render.h"
#include "alarm.h"

static const uint32_t POLL_MS = 30000;
static const uint32_t WIFI_TIMEOUT_MS = 20000;
static const uint32_t WIFI_RETRY_MS = 10000;
static const time_t STALE_AFTER_S = 10 * 60;

static Payload payload;
static String lastBody;
static HeaderState header;
static HeaderState drawnHeader;
static bool havePayload = false;
static uint32_t lastPollMs = 0;
static time_t lastGoodFetch = 0;
static bool bodyChanged = false;
static Screen screen = Screen::Overview;
static Screen drawnScreen = Screen::Overview;
static String vendorFilter;        // Models screen filter, "" = all
static String drawnVendorFilter;

static void connectWifiBlocking() {
  while (!wifiConnect(WIFI_TIMEOUT_MS)) {
    renderMessage("connecting", WIFI_SSID);
    delay(WIFI_RETRY_MS);
  }
}

static void poll() {
  String body; int code;
  FetchStatus st = fetchState(body, code);
  time_t now = time(nullptr);
  switch (st) {
    case FetchStatus::Ok:
      lastGoodFetch = now;
      header.offline = false;
      if (body != lastBody) {
        Payload p;
        if (parsePayload(body, p)) { payload = p; havePayload = true; lastBody = body; bodyChanged = true; }
        else { renderMessage("unsupported payload", "expected v=1; update firmware"); havePayload = false; }
      }
      break;
    case FetchStatus::Unauthorized:
      renderMessage("unauthorised", "check READ_TOKEN in secrets.h"); havePayload = false; break;
    case FetchStatus::NoData:
      renderMessage("no data", "mac app has not published yet"); havePayload = false; break;
    default:
      header.offline = true;
      header.offlineMinutes = lastGoodFetch ? (int)((now - lastGoodFetch) / 60) : 0;
      if (!havePayload) { char msg[32]; snprintf(msg, sizeof msg, "HTTP %d", code); renderMessage("offline", msg); }
      break;
  }
}

void setup() {
  auto cfg = M5.config();
  M5.begin(cfg);
  Serial.begin(115200);
  renderInit();
  alarmInit();
  connectWifiBlocking();
  ntpStart();
  renderMessage("connected", "fetching...");
  lastPollMs = millis() - POLL_MS;  // poll immediately
}

void loop() {
  M5.update();
  // The three touch buttons under the display switch screens; any touch,
  // including those, also silences the alarm.
  if (M5.BtnA.wasPressed()) { screen = Screen::Overview; }
  if (M5.BtnB.wasPressed()) { screen = Screen::Models; vendorFilter = ""; }
  if (M5.BtnC.wasPressed()) { screen = Screen::Usage; }
  bool screenTap = M5.Touch.getCount() > 0 && M5.Touch.getDetail(0).wasPressed();
  if (screenTap && havePayload) {
    auto t = M5.Touch.getDetail(0);
    if (screen == Screen::Overview) {
      // Tap a vendor's spend row → that vendor's models.
      String v = vendorAtY(payload, t.y);
      if (v.length()) { screen = Screen::Models; vendorFilter = v; }
    } else if (screen == Screen::Models) {
      screen = Screen::Overview;
    }
  }
  bool touched = screenTap || M5.BtnA.wasPressed() || M5.BtnB.wasPressed() || M5.BtnC.wasPressed();

  if (!wifiUp()) { connectWifiBlocking(); lastPollMs = millis() - POLL_MS; }

  if (millis() - lastPollMs >= POLL_MS) { lastPollMs = millis(); poll(); }

  // Header state that changes without a new body.
  time_t now = time(nullptr);
  if (clockValid()) { struct tm t; gmtime_r(&now, &t); header.hour = t.tm_hour; header.minute = t.tm_min; }
  header.wifiBars = wifiBars();
  header.stale = havePayload && payload.at > 0 && clockValid() && (now - payload.at) > STALE_AFTER_S;
  renderSetDim(header.stale);

  bool headerChanged = header.hour != drawnHeader.hour || header.minute != drawnHeader.minute ||
                       header.wifiBars != drawnHeader.wifiBars || header.stale != drawnHeader.stale ||
                       header.offline != drawnHeader.offline || header.offlineMinutes != drawnHeader.offlineMinutes;
  if (havePayload && (bodyChanged || headerChanged || screen != drawnScreen || vendorFilter != drawnVendorFilter)) {
    renderPayload(payload, header, screen, vendorFilter);
    drawnHeader = header;
    drawnScreen = screen;
    drawnVendorFilter = vendorFilter;
    bodyChanged = false;
  }

  alarmUpdate(havePayload && payload.hasContext && payload.ctxWarn, touched);
  delay(50);
}
