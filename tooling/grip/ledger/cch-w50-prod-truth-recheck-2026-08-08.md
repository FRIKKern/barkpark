# cch-w50 — live control-plane re-measurement (v11-prod-truth-recheck), 2026-08-08

Read-only. Every row below is a command that re-derives the fact from scratch.
Host: `barkpark.cloud` (control plane). Containers: `cloud-control_plane_green-1`,
`cloud-db-1`. Key: `~/.ssh/barkpark_indx`.

## A — Stripe is ARMED and in TEST MODE

    ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud 'docker exec cloud-control_plane_green-1 sh -c "for v in STRIPE_SECRET_KEY STRIPE_PRICE_SUPPORTER STRIPE_PRICE_SUPPORT_PLUS STRIPE_WEBHOOK_SECRET STRIPE_PUBLISHABLE_KEY; do printf \"%s=%s\n\" \$v \"\$(printenv \$v | cut -c1-12)\"; done"'

    ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud 'docker exec cloud-control_plane_green-1 /app/bin/barkpark_cloud rpc "IO.inspect(BarkparkCloud.Billing.configured?(), label: \"configured?\"); IO.inspect(BarkparkCloud.Billing.gateway(), label: \"gateway\"); IO.inspect(BarkparkCloud.Billing.price_id(\"supporter\"), label: \"price_supporter\")"'

`STRIPE_PUBLISHABLE_KEY` is empty; it is not needed (hosted Checkout redirect).

## B — 15 lapsed trials still carry status='active'

    ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud 'docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -c "select plan,status,current_period_end,current_period_end<now() as lapsed from subscriptions order by current_period_end;"'

    ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud 'docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -c "select t.name, s.current_period_end::date as ends, t.trial_notice_3d_sent_at is not null as n3, t.trial_notice_1d_sent_at is not null as n1, (select count(*) from barkparks b where b.team_id=s.team_id) as boxes from subscriptions s join teams t on t.id=s.team_id where s.plan=\$\$trial\$\$ and s.status=\$\$active\$\$ and s.current_period_end<now() order by s.current_period_end;"'

trial_days_remaining CLAMPS at 0 (never negative):

    ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud 'docker exec cloud-control_plane_green-1 /app/bin/barkpark_cloud rpc "import Ecto.Query; sub = BarkparkCloud.Repo.one(from s in BarkparkCloud.Billing.Subscription, where: s.plan==\"trial\" and s.status==\"active\" and s.current_period_end < ^DateTime.utc_now(), order_by: s.current_period_end, limit: 1); IO.puts(\"trial_days_remaining=#{inspect BarkparkCloud.Billing.trial_days_remaining(sub)}\")"'

## C — the running release's Oban crontab (14 rows, TrialExpiryWorker present)

    ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud 'docker exec cloud-control_plane_green-1 /app/bin/barkpark_cloud rpc "crons = Oban.config(Oban) |> Map.get(:plugins) |> Enum.find_value(fn {Oban.Plugins.Cron, opts} -> Keyword.get(opts, :crontab); _ -> nil end); IO.puts(\"CRON_ROWS=#{length(crons||[])}\"); Enum.each(crons||[], &IO.inspect/1)"'

    ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud 'docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -c "select worker,state,count(*),max(completed_at) from oban_jobs where worker like \$\$%Trial%\$\$ group by 1,2;"'

## D — the bullets, driven from the bytes prod actually serves

    curl -s https://barkpark.cloud/app.js -o /tmp/served_app.js && shasum -a256 /tmp/served_app.js
    git show origin/main:cloud/priv/static/app.js | shasum -a256      # must match

Then eval the served file in a node:vm sandbox (same idiom as
`cloud/priv/static/__app.test.mjs`) and read `planCatalog` / `planFeatures` /
`trialCardHtml` / `readOnlyPlanCardHtml` / `currentPlanCardHtml` off
`__bpTestHook`. Driver kept at
`scratchpad/drive.mjs` in the verify run; reconstruct from the harness header.

## E — the backup signal the plane receives

    ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud 'docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -c "select type,count(*),max(inserted_at) from agent_events group by 1 order by 1;" -c "select payload->>\$\$backup_ok\$\$ as backup_ok, payload->>\$\$backup_detail\$\$ as detail, count(*) from agent_events where type=\$\$health\$\$ group by 1,2;"'
