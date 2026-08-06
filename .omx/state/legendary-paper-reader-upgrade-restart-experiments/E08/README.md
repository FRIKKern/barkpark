# Restart Experiment E08 — hostile reader attack

This isolated artifact attacks E04, E05, and E06 without selecting a candidate. It runs local headless Chrome against candidate public artifacts and decoded email HTML at desktop, 390 px, 320 px, and 200%-equivalent zoom; checks geometry, DOM table/callout/landmark/mark signals, focus order, and MIME structure; and records authenticated Studio, delivered-mail, real AT, cache freshness, session expiry, and reconnect as `BLOCKED` when no real reader is available.

Reproduce from this directory:

```sh
python3 scripts/attack.py 1
python3 scripts/attack.py 2
python3 scripts/verify.py
```

The static E04 JSON-to-HTML harness is explicitly typed as proxy evidence. E05/E06 public HTML and decoded MIME parts are candidate artifacts, but neither becomes a pass for a deployed reader, real mail client, or assistive technology.
