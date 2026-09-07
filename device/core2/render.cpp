#include "render.h"
#include <M5Unified.h>

// All drawing goes to an off-screen canvas that is pushed in one blit,
// so a redraw never shows a cleared screen mid-frame. Sized on every
// frame from the display, which the sketch rotates with the device
// (320x240 landscape, 240x320 portrait).
static M5Canvas gfx(&M5.Display);
#define W (gfx.width())
#define H (gfx.height())

static const uint16_t BG = TFT_BLACK, FG = TFT_WHITE, DIM = 0x7BEF;
static const uint16_t OK_C = 0x07E0, WARN_C = 0xFD20, OVER_C = 0xF800, STALE_C = DIM;

static void beginFrame() {
  if (gfx.width() != M5.Display.width() || gfx.height() != M5.Display.height()) {
    gfx.deleteSprite();
    gfx.setColorDepth(16);
    gfx.setPsram(true);
    gfx.createSprite(M5.Display.width(), M5.Display.height());
  }
  gfx.fillScreen(BG);
  gfx.setTextDatum(top_left);
}
static void endFrame() { gfx.pushSprite(0, 0); }

void renderInit() {
  M5.Display.setRotation(1);
  M5.Display.fillScreen(BG);
  M5.Display.setTextDatum(top_left);
  M5.Display.setBrightness(200);
}

void renderSetDim(bool dim) { M5.Display.setBrightness(dim ? 60 : 200); }

void renderMessage(const char* line1, const char* line2) {
  beginFrame();
  gfx.setTextColor(FG, BG);
  gfx.setTextSize(2);
  gfx.drawString(line1, 12, 90);
  gfx.setTextSize(1);
  gfx.setTextColor(DIM, BG);
  gfx.drawString(line2, 12, 120);
  endFrame();
}

static uint16_t pctColor(int pct, int warnPct, bool stale) {
  if (stale) return STALE_C;
  if (pct >= 100) return OVER_C;
  if (pct >= warnPct) return WARN_C;
  return OK_C;
}

static String usd(float v) {
  char buf[16];
  if (v >= 1000) snprintf(buf, sizeof buf, "$%.0f", v);
  else snprintf(buf, sizeof buf, "$%.2f", v);
  return String(buf);
}

static void drawHeader(const HeaderState& h) {
  gfx.setTextSize(1);
  gfx.setTextColor(DIM, BG);
  gfx.drawString("claudecounter", 8, 6);
  char clock[8] = "--:--";
  if (h.hour >= 0) snprintf(clock, sizeof clock, "%02d:%02d", h.hour, h.minute);
  gfx.setTextDatum(top_right);
  gfx.drawString(clock, W - 40, 6);
  if (h.offline) {
    char msg[24]; snprintf(msg, sizeof msg, "offline %dm", h.offlineMinutes);
    gfx.setTextColor(WARN_C, BG); gfx.drawString(msg, W - 80, 6);
  } else if (h.stale) {
    gfx.setTextColor(WARN_C, BG); gfx.drawString("stale", W - 80, 6);
  }
  gfx.setTextDatum(top_left);
  for (int i = 0; i < 4; i++) {
    int bh = 3 + i * 3;
    gfx.fillRect(W - 32 + i * 6, 16 - bh, 4, bh, i < h.wifiBars ? FG : 0x2104);
  }
  gfx.drawFastHLine(0, 22, W, DIM);
}

// Tab strip under the header; the active screen is bright and underlined.
// Positioned over the three touch buttons' columns so the mapping is obvious.
// Replaces the tab strip while a plan window is at/over the alert
// threshold: "vendor window  [====   ] 100%" in the alert colour.
static void drawUsageAlert(const UsageRow& u, int warnPct) {
  uint16_t c = pctColor(u.pct, warnPct, false);
  gfx.setTextSize(1);
  gfx.setTextDatum(top_left);
  String label = u.vendor + " " + u.window;
  gfx.setTextColor(c, BG);
  gfx.drawString(label.c_str(), 8, 28);
  int lx = 8 + gfx.textWidth(label.c_str()) + 10;
  char pct[8]; snprintf(pct, sizeof pct, "%d%%", u.pct);
  int pw = gfx.textWidth(pct);
  int bx = lx, bw = W - 10 - pw - 8 - bx, bh = 8;
  gfx.drawRect(bx, 28, bw, bh, c);
  gfx.fillRect(bx + 1, 29, (bw - 2) * min(u.pct, 100) / 100, bh - 2, c);
  gfx.setTextDatum(top_right);
  gfx.drawString(pct, W - 10, 28);
  gfx.setTextDatum(top_left);
}

static void drawTabs(Screen active, const String& vendorFilter) {
  String modelsName = vendorFilter.length() ? "models: " + vendorFilter : String("models");
  const char* names[3] = {"overview", modelsName.c_str(), "usage"};
  const int centers[3] = {W / 5, W / 2, W - W / 5};
  gfx.setTextSize(1);
  gfx.setTextDatum(top_center);
  for (int i = 0; i < 3; i++) {
    bool on = (int)active == i;
    gfx.setTextColor(on ? FG : DIM, BG);
    gfx.drawString(names[i], centers[i], 26);
    if (on) gfx.drawFastHLine(centers[i] - 24, 36, 48, FG);
  }
  gfx.setTextDatum(top_left);
}

static String shortModel(const String& id) {
  // Drop the "claude-" prefix and truncate so a row fits.
  String m = id;
  if (m.startsWith("claude-")) m = m.substring(7);
  if (m.length() > 14) m = m.substring(0, 14);
  return m;
}

static void drawContextRow(const Payload& p) {
  const int cy = H - 28;
  gfx.setTextSize(2);
  if (p.hasContext) {
    gfx.setTextColor(DIM, BG);
    gfx.drawString("ctx", 8, cy);
    String name = p.ctxSession;
    if (name.length() > 12) name = name.substring(0, 12);
    gfx.setTextColor(FG, BG);
    gfx.drawString(name.c_str(), 52, cy);
    const int bw = 100, bh = 12, bx = W - 14 - bw;
    if (name.length() * 12 + 52 > bx - 6) { name = name.substring(0, max(0, (bx - 6 - 52) / 12)); }
    uint16_t c = p.ctxWarn ? OVER_C : (p.ctxPct >= p.warnPct ? WARN_C : OK_C);
    gfx.drawRect(bx, cy + 2, bw, bh, DIM);
    gfx.fillRect(bx + 1, cy + 3, (bw - 2) * min(p.ctxPct, 100) / 100, bh - 2, c);
    gfx.setTextSize(1);
    gfx.setTextColor(c, BG);
    char pct[8]; snprintf(pct, sizeof pct, "%d%%%s", p.ctxPct, p.ctxWarn ? " !" : "");
    gfx.drawString(pct, bx, cy + 16);
  } else {
    gfx.setTextColor(DIM, BG);
    gfx.drawString("no active session", 8, cy);
  }
}

static void drawModels(const Payload& p, const String& vendorFilter) {
  const int y0 = 44, rowH = 18, bottom = H - 44;
  const int colDay = W - 100, colMonth = W - 10;
  gfx.setTextSize(1);
  gfx.setTextColor(DIM, BG);
  gfx.setTextDatum(top_right);
  gfx.drawString("today", colDay, y0);
  gfx.drawString("month", colMonth, y0);
  gfx.setTextDatum(top_left);
  int y = y0 + 12;
  int shown = 0;
  for (int i = 0; i < p.modelCount && y + rowH <= bottom; i++) {
    const ModelRow& m = p.models[i];
    if (vendorFilter.length() && m.vendor != vendorFilter) continue;
    shown++;
    gfx.setTextColor(DIM, BG);
    gfx.drawString(m.vendor.c_str(), 8, y);
    gfx.setTextColor(FG, BG);
    gfx.drawString(shortModel(m.model).c_str(), 56, y);
    gfx.setTextDatum(top_right);
    gfx.drawString(usd(m.day).c_str(), colDay, y);
    gfx.drawString(usd(m.month).c_str(), colMonth, y);
    gfx.setTextDatum(top_left);
    y += rowH;
  }
  if (shown == 0) {
    gfx.setTextColor(DIM, BG);
    gfx.drawString("no model spend this month", 8, y);
  }
  gfx.setTextColor(DIM, BG);
  gfx.drawString("tap to return", 8, H - 40);
}

static void drawUsageBars(const Payload& p) {
  const int y0 = 46, rowH = 26, bx = 110, bh = 12, bottom = H - 36;
  const int bw = W - bx - 70;
  gfx.setTextSize(1);
  int y = y0;
  for (int i = 0; i < p.usageCount && y + rowH <= bottom; i++) {
    const UsageRow& u = p.usage[i];
    uint16_t c = pctColor(u.pct, p.warnPct, u.stale);
    gfx.setTextColor(FG, BG);
    gfx.drawString(u.vendor.c_str(), 8, y + 2);
    gfx.setTextColor(DIM, BG);
    gfx.drawString(u.window.c_str(), 70, y + 2);
    gfx.drawRect(bx, y, bw, bh, DIM);
    gfx.fillRect(bx + 1, y + 1, (bw - 2) * min(u.pct, 100) / 100, bh - 2, c);
    gfx.setTextColor(c, BG);
    char pct[12]; snprintf(pct, sizeof pct, "%d%%%s", u.pct, u.stale ? " stale" : "");
    gfx.drawString(pct, bx + bw + 8, y + 2);
    y += rowH;
  }
  if (p.usageCount == 0) {
    gfx.setTextColor(DIM, BG);
    gfx.drawString("no usage windows reported", 8, y);
  }
}

static const int SPEND_Y0 = 58, SPEND_ROW_H = 22;

String vendorAtY(const Payload& p, int y) {
  int idx = (y - SPEND_Y0) / SPEND_ROW_H;
  if (y < SPEND_Y0 || idx < 0 || idx >= p.spendCount) return "";
  return p.spend[idx].vendor;
}

static void drawOverview(const Payload& p) {
  // Spend table: vendor | today | month, right-aligned numbers. Two
  // columns only: at text size 2 a "$1234.56" is ~96 px wide, so three
  // columns overlapped. Week is still in the payload for later use.
  // Row geometry is shared with vendorAtY so taps land on the right row.
  const int y0 = SPEND_Y0 - 14, rowH = SPEND_ROW_H;
  const int COL_DAY = W - 130, COL_MONTH = W - 10;
  gfx.setTextSize(1);
  gfx.setTextColor(DIM, BG);
  gfx.setTextDatum(top_right);
  gfx.drawString("today", COL_DAY, y0);
  gfx.drawString("month", COL_MONTH, y0);
  gfx.setTextDatum(top_left);

  float td = 0, tm = 0;
  int y = SPEND_Y0;
  gfx.setTextSize(2);
  for (int i = 0; i < p.spendCount; i++) {
    const VendorSpend& s = p.spend[i];
    gfx.setTextColor(FG, BG);
    gfx.drawString(s.vendor.c_str(), 8, y);
    gfx.setTextDatum(top_right);
    gfx.drawString(usd(s.day).c_str(), COL_DAY, y);
    gfx.drawString(usd(s.month).c_str(), COL_MONTH, y);
    gfx.setTextDatum(top_left);
    td += s.day; tm += s.month;
    y += rowH;
  }
  if (p.spendCount == 0) {
    gfx.setTextColor(DIM, BG);
    gfx.drawString("no spend this month", 8, y);
    y += rowH;
  }
  gfx.drawFastHLine(8, y, W - 16, DIM);
  y += 4;
  gfx.setTextColor(DIM, BG);
  gfx.drawString("total", 8, y);
  gfx.setTextDatum(top_right);
  gfx.drawString(usd(td).c_str(), COL_DAY, y);
  gfx.drawString(usd(tm).c_str(), COL_MONTH, y);
  gfx.setTextDatum(top_left);

  // Usage strip: one line, wraps to a second if needed.
  int uy = 182;
  gfx.drawFastHLine(0, uy - 6, W, DIM);
  gfx.setTextSize(1);
  int x = 8;
  for (int i = 0; i < p.usageCount; i++) {
    const UsageRow& u = p.usage[i];
    String label = u.vendor + " " + u.window + " ";
    char pct[8]; snprintf(pct, sizeof pct, "%d%%", u.pct);
    int wLabel = gfx.textWidth(label.c_str());
    int wPct = gfx.textWidth(pct);
    if (x + wLabel + wPct + 12 > W) { x = 8; uy += 12; }
    gfx.setTextColor(DIM, BG);
    gfx.drawString(label.c_str(), x, uy);
    gfx.setTextColor(pctColor(u.pct, p.warnPct, u.stale), BG);
    gfx.drawString(pct, x + wLabel, uy);
    x += wLabel + wPct + 12;
  }
  if (p.usageCount == 0) {
    gfx.setTextColor(DIM, BG);
    gfx.drawString("no usage windows reported", 8, uy);
  }
}

void renderPayload(const Payload& p, const HeaderState& h, Screen screen, const String& vendorFilter) {
  beginFrame();
  drawHeader(h);
  if (const UsageRow* a = usageAlert(p)) drawUsageAlert(*a, p.warnPct);
  else drawTabs(screen, vendorFilter);
  switch (screen) {
    case Screen::Overview: drawOverview(p); break;
    case Screen::Models:   drawModels(p, vendorFilter); break;
    case Screen::Usage:    drawUsageBars(p); break;
  }
  drawContextRow(p);
  endFrame();
}
