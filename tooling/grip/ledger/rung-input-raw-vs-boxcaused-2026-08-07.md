# Rung input: raw terminal rate vs box-caused subset — re-derivation recipes (2026-08-07)

Every number in the wave-10 `rung-input-design` verdict, with the one command that re-derives it.
All against cloud-db-1 (control plane), pinned window `now() - interval '24 hours'`, taken 2026-08-07 ~05:0xZ.

SSH prefix used everywhere below:

    SSHDB='ssh -o ConnectTimeout=20 -i ~/.ssh/barkpark_indx root@178.105.92.191 docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -A -F"|" -c'

## 1. Per-site partition (the ATTACK's crack)

    $SSHDB "select s.slug, count(*) filter (where d.status='failed') failed, count(*) filter (where d.status='live') live, count(*) filter (where d.status='deferred') def, count(*) filter (where d.status='failed' and d.failure_reason ~ 'graph (500|503|0)') boxcaused from deployments d join sites s on s.id=d.site_id where d.inserted_at > now() - interval '24 hours' group by 1 order by 2 desc;"

## 2. Box-vs-site agency partition (447 / 134 / 11)

Literal-class set: `bp-doc-id`, `feature_not_configured`, `unreachable`, `box_at_capacity` = BOX;
`^BUILD failed` = SITE; `died abnormally` = AMBIGUOUS.

    $SSHDB "with c as (select d.*, s.slug, case when d.failure_reason ~ 'bp-doc-id' then 'BOX_docid' when d.failure_reason ~ 'feature_not_configured' then 'BOX_featnotconf' when d.failure_reason ~ 'unreachable' then 'BOX_unreachable' when d.failure_reason ~ 'box_at_capacity' then 'BOX_capacity' when d.failure_reason ~ 'died abnormally' then 'AMBIG_died' when d.failure_reason ~ '^BUILD failed' then 'SITE_build' when d.failure_reason is null then 'CAUSELESS' else 'OTHER' end k from deployments d join sites s on s.id=d.site_id where d.status='failed' and d.inserted_at > now() - interval '24 hours') select slug, count(*) filter (where k like 'BOX%') box, count(*) filter (where k like 'SITE%') site, count(*) filter (where k like 'AMBIG%') ambig, count(*) tot from c group by 1 order by 4 desc;"

## 3. The three candidate numerators, fleet-wide

    $SSHDB "with c as (select d.status, d.failure_reason from deployments d join sites s on s.id=d.site_id join barkparks b on b.id=s.barkpark_id where b.slug='guerrilla' and d.inserted_at > now() - interval '24 hours') select count(*) filter (where status in ('failed','live')) n, round(100.0*count(*) filter (where status='failed')/count(*) filter (where status in ('failed','live')),2) raw, round(100.0*count(*) filter (where status='failed' and (failure_reason ~ 'bp-doc-id' or failure_reason ~ 'feature_not_configured' or failure_reason ~ 'unreachable' or failure_reason ~ 'box_at_capacity'))/count(*) filter (where status in ('failed','live')),2) boxlit, round(100.0*count(*) filter (where status='failed' and failure_reason ~ 'graph (500|503|0)')/count(*) filter (where status in ('failed','live')),2) graphsub from c;"

## 4. Leave-one-site-out sensitivity (the decisive experiment)

    $SSHDB "with c as (select d.status, d.failure_reason, s.slug from deployments d join sites s on s.id=d.site_id join barkparks b on b.id=s.barkpark_id where b.slug='guerrilla' and d.inserted_at > now() - interval '24 hours'), s as (select slug from c group by 1) select 'DROP '||s.slug, round(100.0*count(*) filter (where c.status='failed')/nullif(count(*) filter (where c.status in ('failed','live')),0),2) raw, round(100.0*count(*) filter (where c.status='failed' and (c.failure_reason ~ 'bp-doc-id' or c.failure_reason ~ 'feature_not_configured' or c.failure_reason ~ 'unreachable' or c.failure_reason ~ 'box_at_capacity'))/nullif(count(*) filter (where c.status in ('failed','live')),0),2) boxlit, round(100.0*count(*) filter (where c.status='failed' and c.failure_reason ~ 'graph (500|503|0)')/nullif(count(*) filter (where c.status in ('failed','live')),0),2) graphsub, count(*) filter (where c.status in ('failed','live')) n from s join c on c.slug <> s.slug group by 1 order by 2;"

## 5. Retire-the-three-search-sites counterfactual

    $SSHDB "with c as (select d.status, d.failure_reason from deployments d join sites s on s.id=d.site_id join barkparks b on b.id=s.barkpark_id where b.slug='guerrilla' and d.inserted_at > now() - interval '24 hours' and s.slug not like 'search%') select count(*) filter (where status in ('failed','live')) n, round(100.0*count(*) filter (where status='failed')/count(*) filter (where status in ('failed','live')),2) raw, round(100.0*count(*) filter (where status='failed' and (failure_reason ~ 'bp-doc-id' or failure_reason ~ 'feature_not_configured' or failure_reason ~ 'unreachable' or failure_reason ~ 'box_at_capacity'))/count(*) filter (where status in ('failed','live')),2) boxlit, round(100.0*count(*) filter (where status='failed' and failure_reason ~ 'graph (500|503|0)')/count(*) filter (where status in ('failed','live')),2) graphsub from c;"

## 6. min_sample population: how many boxes can ever be metered

    $SSHDB "select count(*) from barkparks;"
    $SSHDB "select b.slug, count(*) filter (where d.status in ('failed','live')) terminal_lifetime, max(d.inserted_at) last_dep from barkparks b join sites s on s.barkpark_id=b.id join deployments d on d.site_id=s.id group by 1 order by 2 desc;"

## 7. Graph-substring false positives and recall

    $SSHDB "select stage, count(*) from deployments where status='failed' and inserted_at > now() - interval '24 hours' and failure_reason ~ 'graph (500|503|0)' group by 1;"
    $SSHDB "select count(*) from deployments where status='failed' and inserted_at > now() - interval '24 hours' and failure_reason ~ 'feature_not_configured' and failure_reason ~ 'graph (500|503|0)';"

## 8. Code anchors (origin/main, not the worktree)

    git show origin/main:cloud/lib/barkpark_cloud/deploy_ledger.ex | sed -n '226,280p'      # classify/2 taxonomy + its anti-substring warning
    git show origin/main:cloud/lib/barkpark_cloud/deploy_ledger.ex | sed -n '591,625p'      # rate/2, @min_sample refusal node
    git show origin/main:cloud/lib/barkpark_cloud/deploy_ledger.ex | grep -n 'basis_attempted\|def rate('
    git show origin/main:internal/cli/cloud_status_cmd.go | sed -n '30,95p'                 # attentionStatus + attentionRankOrder
