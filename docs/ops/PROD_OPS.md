# Production operations — postcheck protocol

## Why

Any `systemctl` operation on production — `restart`, `stop`, `reload`,
`daemon-reload`, even an interrupted `start` — can leave the service in a
state the operator did not intend. Without a verification step, a stopped
or misbooted Phoenix node looks identical to a healthy one from outside
the box: the systemd command returned, the SSH session closed, no error
surfaced. The only signal is users hitting an empty API or a blank
Studio.

`api/scripts/prod-postcheck.sh` closes that gap. It guarantees that every
ops workflow ends with a probe of the public HTTP surface, so an
unhealthy node is detected at the moment it happens, not when traffic
discovers it.

## The rule

Any workflow that touches `systemctl barkpark` on production **must** end
with a run of `api/scripts/prod-postcheck.sh`.

Two corollaries:

- **Use atomic transitions.** Prefer `systemctl restart barkpark` over
  `stop` followed by a separate `start`. If a maintenance window genuinely
  requires a stop without a restart, document it before running the stop —
  do not assume someone else will start it back up.
- **No silent ops.** If you SSH in to apply a patch, run the script before
  you log out. The whole point is to refuse "looks fine, didn't check."

## How to run

From a workstation:

```bash
ssh root@<prod-host> "cd /opt/barkpark && ./api/scripts/prod-postcheck.sh"
```

On the box itself:

```bash
cd /opt/barkpark
./api/scripts/prod-postcheck.sh
```

Exit code 0 = healthy. Non-zero = unhealthy; the script writes a tail of
`systemctl status barkpark` to stderr before exiting so you have an
immediate diagnostic without a second SSH round-trip.

## What it checks

1. **Service is active.** `systemctl is-active --quiet barkpark`. If the
   unit is inactive the script starts it — the script is a recovery
   guardrail, not a passive monitor. Run it only when "service should be
   running" is the desired end state.
2. **Boot delay.** Sleeps 2 s before the HTTP probe so the BEAM has time
   to bind `:4000` after a fresh start.
3. **HTTP 200 from `/api/schemas`.** Legacy unauth path. Returns JSON
   when Phoenix is alive, no auth header required. Probe path can be
   swapped to `/studio` (HTML 200) if the legacy schemas endpoint is ever
   retired; do not swap to `/v1/schemas/production` (admin-token gated).

## Operational checklist

- Apply the change via the documented Makefile target (`make deploy`,
  `make rebuild`, `make restart`) rather than ad-hoc `systemctl` invocations
  where possible.
- Run `./api/scripts/prod-postcheck.sh`. Confirm `PASS prod healthy …`.
- Tail `journalctl -u barkpark -f` for at least 60 s and watch for boot
  errors, repeated supervisor restarts, or 5xx-emitting controllers.
- If the postcheck FAILs: read the `systemctl status` tail it printed,
  then `journalctl -u barkpark -n 200 --no-pager` for the surrounding
  context. Do not retry the same `systemctl` invocation blindly.

See the top-level [README](../../README.md) for the deploy section that
points back to this protocol.
