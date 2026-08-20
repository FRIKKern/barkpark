<!-- doc-tier: cold | canonical-for: idor-webhook-charset-clamp-proof | budget: 800tok -->

# Webhook proxy render_path charset-clamp — re-derivation recipe

Wave: api-read-path-security-sweep IDOR/BOLA · assignment [webhook-charset] · 2026-08-18
Verdict: CLOSED, zero findings. Nested webhook_id/event_id/?dataset= cannot reshape the upstream URL, and base+admin_token derive solely from the ownership-resolved bp.

## Re-derive the clamp regex + that it rejects every hostile shape

    git show origin/main:cloud/lib/barkpark_cloud/registry/instance_api_catalog.ex | grep -nE 'safe_value|render_path|bad_param'
    # @safe_value ~r/^[A-Za-z0-9._~-]+$/  @ line 163 (RFC 3986 unreserved set)

    elixir -e 're = ~r/^[A-Za-z0-9._~-]+$/; for v <- ["abc","wh_42","evt_9","a/b","a?x=1","a#f","..%2f","%2e%2e","http://evil","a b","","a\nb","a;b","a&b=1","a\\b","café"], do: IO.puts("#{inspect(v)} => #{Regex.match?(re, v)}")'
    # safe ids (abc/wh_42/evt_9) => true ; every / ? # % whitespace ; & \ url empty => false

## Re-derive that base+token are param-independent (derive from bp struct only)

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '11029,11140p'
    # proxy_instance_webhook -> resolve_team_barkpark(team, path_params["id"]) -> %Barkpark{} bp
    # dispatch_instance_api: {:ok, base} <- instance_base_url(bp); {:ok, admin_token} <- instance_admin_token(bp)
    # render_instance_path builds values {dataset, id=webhook_id, event_id} -> render_path clamp -> :bad_request(400) on any hostile char

    git show origin/main:cloud/lib/barkpark_cloud/usage.ex | sed -n '905,930p'
    # instance_base_url(%Barkpark{url: url}) -> {:ok, trim(url)}   base = bp.url ONLY
    # instance_admin_token(bp) -> Registry.reveal_admin_token(bp)  token = bp's own ciphertext ONLY

## Why this closes the seam

Each webhook template ({dataset}/{id}/{event_id}) is a literal-prefixed path
(`/v1/webhooks/...`) whose substituted segments are individually clamped to the
unreserved set. A `/` (authority/traversal), `?` (query), `#` (fragment), `%`
(double-encode) or whitespace in webhook_id / event_id / ?dataset= halts render
as {:error,{:bad_param,key}} -> 400 bad_request; the upstream call never fires.
base and admin_token come off the ownership-resolved bp struct, never off request
params, so nested objects cannot retarget a second host or a foreign instance.
