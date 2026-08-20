# Carrier-column sizing — cch wave 52 verifier (2026-08-08)

Re-derivation recipes for the carrier bucket sizing and the Console-gate blindness proof.
Tree measured: `git archive origin/main` @ `572d51e13fa41fd4aace729661f6fc0119bfa8f2`.

## 1. Prod notification_deliveries census (L1 — running system)

```
ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud "docker exec cloud-db-1 sh -c 'psql -U \$POSTGRES_USER -d \$POSTGRES_DB -c \"select kind, channel, count(*) from notification_deliveries group by 1,2 order by 3 desc; select count(*) from notification_deliveries;\"'"
```

Result 2026-08-08: `alert|email 3001`, `transactional|email 4`, total `3005`.
**Zero chat-channel rows exist** (discord/slack/telegram/pushover/webhook: absent from the group-by).

Multi-statement SQL over ssh needs stdin, not `-c` (quote mangling turns `'alert'` into a numeric literal):

```
ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud 'docker exec -i cloud-db-1 sh -c "psql -U \$POSTGRES_USER -d \$POSTGRES_DB -f -"' < query.sql
```

## 2. The unknown bucket collapses — every alert row is provably platform

```sql
select count(*) filter (where smtp_host_encrypted is not null) as smtp_host_set,
       count(*) filter (where smtp_password_encrypted is not null) as smtp_pw_set,
       count(*) filter (where api_key_encrypted is not null)      as api_key_set,
       count(*) as total from email_notification_settings;
-- 0 | 0 | 0 | 22

select (d.team_id is null) as no_team, (s.id is null) as no_settings, count(*)
from notification_deliveries d
left join email_notification_settings s on s.team_id = d.team_id
where d.kind='alert' and d.channel='email' group by 1,2 order by 3 desc;
-- f | f | 3001   (every alert row joins a settings row)

select s.transport, count(d.id) from notification_deliveries d
join email_notification_settings s on s.team_id=d.team_id
where d.kind='alert' and d.channel='email' group by 1;
-- instance | 3001
```

Residue: exactly ONE settings row was ever updated after insert
(`team 506f035e-08f4-4b49-9038-86735eb4c0ef`, updated_at 2026-07-01 17:42:10.943041,
11ms before the first delivery row at 17:42:10.95173) and it owns 2953 of the 3001 rows.
There is NO history table, so "never SMTP" is inference, not proof.

## 3. Console-gate blindness to a carrier meta segment (mutation, not reading)

Anchor in the extract, `cloud/priv/static/app.js:3431` (`notifDeliveryRowHtml`):

```
var meta = [channel, event].concat(attempts ? [attempts] : []).join(" &middot; ");
```

MUTANT A — plain-text third segment:

```
var meta = [channel, event, esc(d.carrier || "unknown")].concat(attempts ? [attempts] : []).join(" &middot; ");
```

Then, in the extract root:

```
node --test cloud/priv/static/__app.test.mjs   # 1004/1004 pass
node cloud/priv/static/__css_check.mjs         # 0 errors
node cloud/priv/static/__preview__/smoke.mjs
node cloud/priv/static/__preview__/member-authority-sweep.mjs
node cloud/priv/static/__binding_census.mjs
node cloud/priv/static/__reason_arm_census.mjs
node cloud/priv/static/__me_envelope_census.mjs
node cloud/priv/static/__agent_event_vocabulary_census.mjs
node cloud/priv/static/__unknown_census.mjs
```

ALL NINE EXIT 0. Zero Console-gate pins break.

MUTANT B — same segment wrapped in `<span class="wh-del-carrier">`:
unit suite still 1004/1004, but `__css_check.mjs` exits 1 with

```
FAIL  E2 app.js:3431  class "wh-del-carrier" is emitted but has no rule in app.css
```

So the ONLY Console-gate pin a carrier segment can trip is `__css_check` E2, and only if
the builder introduces a new class. There is no order/content pin on `.wh-del-meta` for the
NOTIFICATION row builder. The one `doesNotMatch(/wh-del-meta/)` pin
(`__app.test.mjs:4997`) guards the WEBHOOK builder `deliveryRowHtml` (app.js:9525), a
different function with a different meta (`attempts · latency`).
