# claudecounter Worker

Stores the mac app's device payload in a Durable Object and serves it to
the M5Stack.

## One-time setup

    cd cloudflare
    npm install
    npx wrangler login
    openssl rand -hex 24   # write token
    openssl rand -hex 24   # read token
    npx wrangler secret put WRITE_TOKEN
    npx wrangler secret put READ_TOKEN
    npx wrangler deploy

`wrangler deploy` prints the Worker URL, e.g.
`https://claudecounter.<account>.workers.dev`. The app and the device use
`<that URL>/state`.

## Verify

    URL=https://claudecounter.<account>.workers.dev/state
    curl -sS -X PUT "$URL" -H "Authorization: Bearer $WRITE" \
      -H 'Content-Type: application/json' -d '{"v":1,"spend":{}}' -w '%{http_code}\n'   # 204
    curl -sS "$URL" -H "Authorization: Bearer $READ"                                     # echoes the body
    curl -sS "$URL" -H "Authorization: Bearer wrong" -w '%{http_code}\n'                 # 401

## Wire it up

- Mac app: gear menu → Device display… → paste the URL and the write
  token → Save → Send now.
- Device: put the URL and the read token in `device/core2/secrets.h`.

## Quota

The payload lives in one SQLite-backed Durable Object (the kind the
Workers free plan includes; no KV namespace, no card). The free plan
allows 100 000 Durable Object requests a day. The mac app PUTs once per
60 s tick when the payload's bytes changed, the device GETs every 30 s:
about 4 300 requests a day at the very most, so the interval is not
quota-bound. If the Worker returns 429 the app shows `Device publish
failed: HTTP 429` in the popover footer.

The stored value expires 24 h after the last PUT (an alarm clears
storage), so a stopped mac app eventually yields 404 and the device
shows "no data" rather than a day-old number forever.
