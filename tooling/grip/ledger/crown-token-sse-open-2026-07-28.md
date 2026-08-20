# Re-derivation: can a chat-scoped token OPEN the per-session SSE stream on guerrilla?

Verified 2026-07-28 (barkpark-tasks-mobile wave, crown leg 1). Answer: YES.

## 1. Slot truth — which process is live, from which build tree

```sh
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
  'cat /opt/barkpark/.slots/blue.sha /opt/barkpark/.slots/green.sha;
   systemctl show barkpark-slot@blue -p ActiveState -p MainPID -p ActiveEnterTimestamp;
   systemctl show barkpark.service -p ActiveState'
```

Expect: `blue.sha=cd346389dd95f3d1ad32639a70767ee27e565e80`, blue `ActiveState=active`,
`barkpark.service` **inactive** (the documented smoke path reads DEAD — do not believe it).

Which `_build` the live BEAM actually runs from (not what is merely on disk):

```sh
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
  'tr "\0" "\n" < /proc/$(systemctl show -P MainPID barkpark-slot@blue)/environ | grep MIX_BUILD_ROOT'
```

Expect `MIX_BUILD_ROOT=/opt/barkpark/api/_build_blue`. It is a `mix run` node, **not** an
OTP release — there is no `bin/barkpark rpc`, so "is the module loaded" is proved by
beam-mtime < service-start, plus a symbol grep:

```sh
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
  'ls -l --time-style=full-iso /opt/barkpark/api/_build_blue/prod/lib/barkpark/ebin/Elixir.BarkparkWeb.ChatController.beam;
   strings /opt/barkpark/api/_build_blue/prod/lib/barkpark/ebin/Elixir.BarkparkWeb.ChatController.beam | grep -c stable_end'
```

Ancestry of the live-document merge:

```sh
git merge-base --is-ancestor a99127cad cd346389dd95f3d1ad32639a70767ee27e565e80 && echo yes
```

## 2. The stream opens

```sh
TOK=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['token'])")
SID=$(curl -s -H "Authorization: Bearer $TOK" \
  https://guerrilla.barkpark.cloud/v1/chat/sessions | python3 -c 'import sys,json;print(json.load(sys.stdin)["sessions"][0]["id"])')

# unauthenticated control — must be 401, never 404
curl -s -o /dev/null -w '%{http_code}\n' \
  https://guerrilla.barkpark.cloud/v1/chat/sessions/00000000-0000-0000-0000-000000000000/events

# authed attach; -m 40 so the 30s keepalive lands
curl -N -sS -m 40 -D - -o /tmp/sse.raw \
  -H "Authorization: Bearer $TOK" -H 'Accept: text/event-stream' \
  "https://guerrilla.barkpark.cloud/v1/chat/sessions/$SID/events"; od -c /tmp/sse.raw
```

Expect `HTTP/2 200`, `content-type: text/event-stream; charset=utf-8`, then — after ~30s —
exactly `:   k e e p a l i v e \n \n` (13 bytes). Curl exits 28 (timeout); that is the
expected shape of a never-shed stream, not a failure.

## 3. Gotcha that will bite the next reader

An **idle** session emits ZERO bytes on connect. That is correct, not a broken stream:
`chat_controller.ex` `replay(conn, _id, nil) -> conn` (no `Last-Event-ID` ⇒ no replay) and
`stable_snapshot/2` returns the conn untouched when `Recorder.stable_snapshot(id)` is `nil`
(no in-flight tail). Anything under a 30s timeout therefore reads as "0 bytes received" and
is indistinguishable from a dead stream. **Always use `-m 40`.**

All 39 sessions on the instance were `agent_state: idle` at probe time, so no free live
`stable` frame is observable — a real turn must be driven to capture one.
