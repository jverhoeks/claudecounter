#include "render.h"
#include <M5Unified.h>

static const int W = 320, H = 240;
static const uint16_t BG = TFT_BLACK, FG = TFT_WHITE, DIM = 0x7BEF;
static const uint16_t OK_C = 0x07E0, WARN_C = 0xFD20, OVER_C = 0xF800, STALE_C = DIM;

void renderInit() {
  M5.Display.setRotation(1);
  M5.Display.fillScreen(BG);
  M5.Display.setTextDatum(top_left);
  M5.Display.setBrightness(200);
}

void renderSetDim(bool dim) { M5.Display.setBrightness(dim ? 60 : 200); }

void renderMessage(const char* line1, const char* line2) {
  M5.Display.fillScreen(BG);
  M5.Display.setTextDatum(top_left);
  M5.Display.setTextColor(FG, BG);
  M5.Display.setTextSize(2);
  M5.Display.drawString(line1, 12, 90);
  M5.Display.setTextSize(1);
  M5.Display.setTextColor(DIM, BG);
  M5.Display.drawString(line2, 12, 120);
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
  M5.Display.setTextSize(1);
  M5.Display.setTextColor(DIM, BG);
  M5.Display.drawString("claudecounter", 8, 6);
  char clock[8] = "--:--";
  if (h.hour >= 0) snprintf(clock, sizeof clock, "%02d:%02d", h.hour, h.minute);
  M5.Display.drawString(clock, 200, 6);
  if (h.offline) {
    char msg[24]; snprintf(msg, sizeof msg, "offline %dm", h.offlineMinutes);
    M5.Display.setTextColor(WARN_C, BG); M5.Display.drawString(msg, 120, 6);
  } else if (h.stale) {
    M5.Display.setTextColor(WARN_C, BG); M5.Display.drawString("stale", 140, 6);
  }
  for (int i = 0; i < 4; i++) {
    int bh = 3 + i * 3;
    M5.Display.fillRect(288 + i * 6, 16 - bh, 4, bh, i < h.wifiBars ? FG : 0x2104);
  }
  M5.Display.drawFastHLine(0, 22, W, DIM);
}

// Tab strip under the header; the active screen is bright and underlined.
// Positioned over the three touch buttons' columns so the mapping is obvious.
static void drawTabs(Screen active, const String& vendorFilter) {
  String modelsName = vendorFilter.length() ? "models: " + vendorFilter : String("models");
  const char* names[3] = {"overview", modelsName.c_str(), "usage"};
  const int centers[3] = {64, 160, 256};
  M5.Display.setTextSize(1);
  M5.Display.setTextDatum(top_center);
  for (int i = 0; i < 3; i++) {
    bool on = (int)active == i;
    M5.Display.setTextColor(on ? FG : DIM, BG);
    M5.Display.drawString(names[i], centers[i], 26);
    if (on) M5.Display.drawFastHLine(centers[i] - 24, 36, 48, FG);
  }
  M5.Display.setTextDatum(top_left);
}

static String shortModel(const String& id) {
  // Drop the "claude-" prefix and truncate so a row fits.
  String m = id;
  if (m.startsWith("claude-")) m = m.substring(7);
  if (m.length() > 14) m = m.substring(0, 14);
  return m;
}

static void drawContextRow(const Payload& p) {
  const int cy = 212;
  M5.Display.setTextSize(2);
  if (p.hasContext) {
    M5.Display.setTextColor(DIM, BG);
    M5.Display.drawString("ctx", 8, cy);
    String name = p.ctxSession;
    if (name.length() > 12) name = name.substring(0, 12);
    M5.Display.setTextColor(FG, BG);
    M5.Display.drawString(name.c_str(), 52, cy);
    const int bx = 206, bw = 100, bh = 12;
    uint16_t c = p.ctxWarn ? OVER_C : (p.ctxPct >= p.warnPct ? WARN_C : OK_C);
    M5.Display.drawRect(bx, cy + 2, bw, bh, DIM);
    M5.Display.fillRect(bx + 1, cy + 3, (bw - 2) * min(p.ctxPct, 100) / 100, bh - 2, c);
    M5.Display.setTextSize(1);
    M5.Display.setTextColor(c, BG);
    char pct[8]; snprintf(pct, sizeof pct, "%d%%%s", p.ctxPct, p.ctxWarn ? " !" : "");
    M5.Display.drawString(pct, bx, cy + 16);
  } else {
    M5.Display.setTextColor(DIM, BG);
    M5.Display.drawString("no active session", 8, cy);
  }
}

static void drawModels(const Payload& p, const String& vendorFilter) {
  const int y0 = 44, rowH = 18;
  M5.Display.setTextSize(1);
  M5.Display.setTextColor(DIM, BG);
  M5.Display.setTextDatum(top_right);
  M5.Display.drawString("today", 220, y0);
  M5.Display.drawString("month", 310, y0);
  M5.Display.setTextDatum(top_left);
  int y = y0 + 12;
  int shown = 0;
  for (int i = 0; i < p.modelCount && y + rowH <= 204; i++) {
    const ModelRow& m = p.models[i];
    if (vendorFilter.length() && m.vendor != vendorFilter) continue;
    shown++;
    M5.Display.setTextColor(DIM, BG);
    M5.Display.drawString(m.vendor.c_str(), 8, y);
    M5.Display.setTextColor(FG, BG);
    M5.Display.drawString(shortModel(m.model).c_str(), 56, y);
    M5.Display.setTextDatum(top_right);
    M5.Display.drawString(usd(m.day).c_str(), 220, y);
    M5.Display.drawString(usd(m.month).c_str(), 310, y);
    M5.Display.setTextDatum(top_left);
    y += rowH;
  }
  if (shown == 0) {
    M5.Display.setTextColor(DIM, BG);
    M5.Display.drawString("no model spend this month", 8, y);
  }
  M5.Display.setTextColor(DIM, BG);
  M5.Display.drawString("tap to return", 8, 196);
}

static void drawUsageBars(const Payload& p) {
  const int y0 = 46, rowH = 26, bx = 120, bw = 120, bh = 12;
  M5.Display.setTextSize(1);
  int y = y0;
  for (int i = 0; i < p.usageCount && y + rowH <= 204; i++) {
    const UsageRow& u = p.usage[i];
    uint16_t c = pctColor(u.pct, p.warnPct, u.stale);
    M5.Display.setTextColor(FG, BG);
    M5.Display.drawString(u.vendor.c_str(), 8, y + 2);
    M5.Display.setTextColor(DIM, BG);
    M5.Display.drawString(u.window.c_str(), 70, y + 2);
    M5.Display.drawRect(bx, y, bw, bh, DIM);
    M5.Display.fillRect(bx + 1, y + 1, (bw - 2) * min(u.pct, 100) / 100, bh - 2, c);
    M5.Display.setTextColor(c, BG);
    char pct[12]; snprintf(pct, sizeof pct, "%d%%%s", u.pct, u.stale ? " stale" : "");
    M5.Display.drawString(pct, bx + bw + 8, y + 2);
    y += rowH;
  }
  if (p.usageCount == 0) {
    M5.Display.setTextColor(DIM, BG);
    M5.Display.drawString("no usage windows reported", 8, y);
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
  const int COL_DAY = 190, COL_MONTH = 310;
  M5.Display.setTextSize(1);
  M5.Display.setTextColor(DIM, BG);
  M5.Display.setTextDatum(top_right);
  M5.Display.drawString("today", COL_DAY, y0);
  M5.Display.drawString("month", COL_MONTH, y0);
  M5.Display.setTextDatum(top_left);

  float td = 0, tm = 0;
  int y = SPEND_Y0;
  M5.Display.setTextSize(2);
  for (int i = 0; i < p.spendCount; i++) {
    const VendorSpend& s = p.spend[i];
    M5.Display.setTextColor(FG, BG);
    M5.Display.drawString(s.vendor.c_str(), 8, y);
    M5.Display.setTextDatum(top_right);
    M5.Display.drawString(usd(s.day).c_str(), COL_DAY, y);
    M5.Display.drawString(usd(s.month).c_str(), COL_MONTH, y);
    M5.Display.setTextDatum(top_left);
    td += s.day; tm += s.month;
    y += rowH;
  }
  if (p.spendCount == 0) {
    M5.Display.setTextColor(DIM, BG);
    M5.Display.drawString("no spend this month", 8, y);
    y += rowH;
  }
  M5.Display.drawFastHLine(8, y, W - 16, DIM);
  y += 4;
  M5.Display.setTextColor(DIM, BG);
  M5.Display.drawString("total", 8, y);
  M5.Display.setTextDatum(top_right);
  M5.Display.drawString(usd(td).c_str(), COL_DAY, y);
  M5.Display.drawString(usd(tm).c_str(), COL_MONTH, y);
  M5.Display.setTextDatum(top_left);

  // Usage strip: one line, wraps to a second if needed.
  int uy = 182;
  M5.Display.drawFastHLine(0, uy - 6, W, DIM);
  M5.Display.setTextSize(1);
  int x = 8;
  for (int i = 0; i < p.usageCount; i++) {
    const UsageRow& u = p.usage[i];
    String label = u.vendor + " " + u.window + " ";
    char pct[8]; snprintf(pct, sizeof pct, "%d%%", u.pct);
    int wLabel = M5.Display.textWidth(label.c_str());
    int wPct = M5.Display.textWidth(pct);
    if (x + wLabel + wPct + 12 > W) { x = 8; uy += 12; }
    M5.Display.setTextColor(DIM, BG);
    M5.Display.drawString(label.c_str(), x, uy);
    M5.Display.setTextColor(pctColor(u.pct, p.warnPct, u.stale), BG);
    M5.Display.drawString(pct, x + wLabel, uy);
    x += wLabel + wPct + 12;
  }
  if (p.usageCount == 0) {
    M5.Display.setTextColor(DIM, BG);
    M5.Display.drawString("no usage windows reported", 8, uy);
  }
}

void renderPayload(const Payload& p, const HeaderState& h, Screen screen, const String& vendorFilter) {
  M5.Display.startWrite();
  M5.Display.fillScreen(BG);
  drawHeader(h);
  drawTabs(screen, vendorFilter);
  switch (screen) {
    case Screen::Overview: drawOverview(p); break;
    case Screen::Models:   drawModels(p, vendorFilter); break;
    case Screen::Usage:    drawUsageBars(p); break;
  }
  drawContextRow(p);
  M5.Display.endWrite();
}
