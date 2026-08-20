# Re-derivation recipe — wave 58 verifier `identity-probe-exists` (2026-08-09)

Question: can any route on a provisioned Barkpark LOSE on a wrong bearer, cheaply?
Answer: YES — `GET /v1/admin/self-update`, and the control plane already calls it hourly.

## 1. verify.api's probe is identity-blind (200 to a bogus bearer)

```sh
curl -s -o /dev/null -w '%{http_code}\n' https://guerrilla.barkpark.cloud/v1/capabilities
curl -s -o /dev/null -w '%{http_code}\n' -H 'Authorization: Bearer totally-invalid-token-xyz' \
  https://guerrilla.barkpark.cloud/v1/capabilities
# 200 / 200   (same on http://89.167.28.206)
```

TRAP: do NOT write the loop as `curl ${h:+-H "$h"} ...` — zsh does not word-split, the
whole thing arrives as ONE argv and the box answers 406. That 406 is an artifact of the
harness, not of the server. Pass each header as its own literal `-H '...'`.

## 2. The identity probe that CAN lose

```sh
TOK=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['token'])")
P=https://guerrilla.barkpark.cloud/v1/admin/self-update
curl -s -o /dev/null -w 'noauth %{http_code}\n' "$P"
curl -s -o /dev/null -w 'bogus  %{http_code}\n' -H 'Authorization: Bearer totally-invalid-token-xyz' "$P"
curl -s -o /dev/null -w 'valid  %{http_code} %{size_download}B %{time_total}s\n' -H "Authorization: Bearer $TOK" "$P"
# noauth 401 / bogus 401 / valid 200 328B 0.070s
```

403 arm is code-level, not run-proven here: `api/lib/barkpark_web/plugs/require_admin.ex`
halts 403 unless the token carries `admin`.

Other discriminators found: `/v1/secrets` 401/401/200 (197B). Non-discriminators:
`/v1/auth/app-tokens` and `/v1/schemas` 404 on every arm (routes do not exist at those paths).

## 3. The plane already makes this exact request — and discards the answer

```sh
git show origin/main:cloud/lib/barkpark_cloud/registry.ex | sed -n '3806,3840p'
```

`refresh_update_status/1` builds `GET <bp.url>/v1/admin/self-update` with the decrypted
admin bearer, then:

```elixir
          _ ->
            persist_update_unknown(bp, :instance_error)
```

That bare `_ ->` at :3834 swallows 401, 403, 404, 5xx and every transport failure into the
same `update_state: "unknown"`. An identity REFUTATION and a pre-feature 404 land on the
same column value.

## 4. Destination-column check (survey point B stands)

```sh
git show origin/main:cloud/lib/barkpark_cloud/registry.ex | sed -n '3785,3792p;4203,4220p'
```

`checkable_scope/1` and `next_autoupdate_candidate/1` both filter `b.host`; the request in
§3 is built from `bp.url`. Different columns.

## 5. Fence

```sh
gh pr list --state open --json number,title,files --limit 100
```
Only #10944 touches `cloud/lib/barkpark_cloud/registry.ex`; nothing open touches
`api/.../self_update_controller.ex`.
