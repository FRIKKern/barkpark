<!-- doc-tier: cold | canonical-for: none | budget: 800tok -->
# Re-derivation: Connectors public route is ARMED (premise refuted) — W35

Claim under test (digest contradiction A): "https://guerrilla.barkpark.cloud/connectors/* 404s on
every path while loopback :4020 health is ok; the Caddy /connectors route appears unarmed."

VERDICT: REFUTED. The Caddy route is armed and proxying. Public /connectors/health = 200.
The /connectors/webhooks/slack 404 is the bridge's DELIBERATE opaque 404 (no Slack install mounted;
connector_installs = 0), reproduced identically over loopback — so it is not a Caddy fault.
/mcp 405 is the Phoenix API (:4000), not the connectors bridge (:4020), which serves only the
/connectors prefix.

## Re-derive (public probe)

    for p in /connectors/health /connectors/webhooks/slack /mcp; do \
      curl -s -o /dev/null -w "$p %{http_code}\n" --max-time 8 https://guerrilla.barkpark.cloud$p; done
    # expect: /connectors/health 200 | /connectors/webhooks/slack 404 | /mcp 405

## Re-derive (server truth)

    ssh -o ConnectTimeout=12 -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      'grep -n -B2 -A8 connectors /etc/caddy/Caddyfile | head -80; \
       systemctl is-active barkpark-connectors.service; \
       curl -s -m5 http://127.0.0.1:4020/connectors/health; \
       curl -s -o /dev/null -w "loopback slack %{http_code}\n" -m5 http://127.0.0.1:4020/connectors/webhooks/slack; \
       grep -n "arm_caddy_connectors_route" /opt/barkpark/deploy/instance-deploy.sh'
    # Caddyfile carries: @barkpark_connectors path /connectors /connectors/*  -> reverse_proxy localhost:4020
    # service active; loopback health {"status":"ok"}; loopback slack 404 (same as public)
    # instance-deploy.sh:584 arm_caddy_connectors_route() ; :636 with_caddy_lock arm_caddy_connectors_route

## Why the webhook 404 is by design

connectors/src/http/webhook-server.ts parseRoute() accepts /connectors/webhooks/:provider, then
lookupInstall()/handlerFor() returns null when no install is mounted -> notFound() (the "single
opaque failure", webhook-server.ts:84,442). Zero installs => every webhook path 404s correctly.

## Fix shape for Decide

NO ops re-arm and NO deploy-code slice for the route. Route is correct and live. The Slack live
gate is inert because of zero installs + a human-held BotFather/Slack credential, NOT the route.
Do not cut a connectors-public-route slice.
