// Copy to secrets.h (gitignored) and fill in.
#pragma once

#define WIFI_SSID   "your-wifi"
#define WIFI_PASS   "your-password"
// Worker URL including the /state path.
#define WORKER_URL  "https://claudecounter.<account>.workers.dev/state"
// The READ token from `wrangler secret put READ_TOKEN`, never the write token.
#define READ_TOKEN  "replace-me"
