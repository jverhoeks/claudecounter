# Core2 desk display

Shows the mac app's spend and usage on an M5Stack Core2 for AWS. Reads
`GET /state` from the Cloudflare Worker in `../../cloudflare`.

## Configure

    cp secrets.example.h secrets.h
    # edit: WIFI_SSID, WIFI_PASS, WORKER_URL (with /state), READ_TOKEN

`secrets.h` is gitignored. Use the READ token only; the write token
never goes on the device.

## Build and flash, option A: make + arduino-cli

    make device-deps      # once: installs arduino-cli, the M5Stack core and libraries
    make device-build
    make device-flash     # plug in over USB-C first; DEVICE_PORT=/dev/cu.xxx to override
    make device-monitor   # optional serial log

## Build and flash, option B: Arduino IDE 2.x

1. Preferences → Additional boards manager URLs, add
   `https://static-cdn.m5stack.com/resource/arduino/package_m5stack_index.json`.
2. Boards Manager → install "M5Stack".
3. Library Manager → install M5Unified, ArduinoJson (7.x), FastLED.
4. Tools → Board → M5Stack → M5Core2. Tools → Port → the Core2's port.
5. File → Open → `device/core2/core2.ino`. Upload.

## What it shows

Three screens, switched with the three touch buttons under the display
(left, middle, right). The header and the context row are on all three.

- Header: title, UTC clock, Wi-Fi bars. "stale" and a dimmed backlight
  when the payload is older than 10 minutes; "offline Nm" when the last
  fetch failed. A tab strip shows which screen is active.
- Overview (left button): spend table per vendor with today and this
  month, plus a total row, and a usage strip with each
  reported window as `vendor window pct`.
- Models (middle button): models by month spend with today and month
  columns. Tap a vendor's row on Overview to see only that vendor's
  models; tap the Models screen to go back.
- Usage (right button): one bar per reported window.
- Context row: the active session with the highest context use, with a
  bar and `!` when it is over the warning threshold.
- Colours: green below the app's warn percentage, amber above it, red at
  100, grey if stale.

## Alarm

When the context warning turns on, the LED bar goes red and the speaker
beeps once. LEDs stay red while the warning holds. Touch the screen or
any button to turn the LEDs off until the next new warning.

## Security note

The device does not verify the Worker's TLS certificate (`setInsecure`):
the ESP32 Arduino core has no built-in root bundle reachable from
HTTPClient. A man-in-the-middle on your Wi-Fi could read the read-only
token, which grants nothing but reading the same JSON. Rotate it with
`wrangler secret put READ_TOKEN` if that matters.

## Troubleshooting

- "unauthorised": READ_TOKEN does not match the Worker secret.
- "no data": the mac app has not published, or the key expired after 24 h.
- "unsupported payload": the mac app publishes a newer `v`; update the firmware.
- Clock shows `--:--`: NTP not synced yet, or UDP 123 blocked.
