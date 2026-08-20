# cch-w52 — api transport: DELETE, not DISCLOSE (re-derivation recipes)

Verifier lane `api-delete-vs-disclose`, 2026-08-08. Every row below is a command,
not a reading. Re-run any of them to re-derive the ruling from scratch.

## R1 — live prod transport census (control plane, cloud-db-1)

```sh
ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud "docker exec cloud-db-1 sh -c 'psql -U \$POSTGRES_USER -d \$POSTGRES_DB \
  -c \"select transport, count(*) from email_notification_settings group by 1;\" \
  -c \"select count(*) filter (where api_key_encrypted is not null) as with_key, count(*) as total from email_notification_settings;\" \
  -c \"select count(*) from teams;\" \
  -c \"select max(updated_at) from email_notification_settings;\"'"
```

Taken 2026-08-08: `instance | 22` (the ONLY row — no smtp, no api), `with_key 0 / total 22`,
`teams 27`, `max(updated_at) 2026-07-25 01:04:47`. Two weeks of write silence: the
snapshot-vs-migration race the survey flagged is real but cold.

## R2 — no DB-level constraint pins the transport vocabulary

```sh
ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud "docker exec cloud-db-1 sh -c 'psql -U \$POSTGRES_USER -d \$POSTGRES_DB -c \"\\d email_notification_settings\"'"
```

`transport | character varying(255) | not null | default 'instance'`. No CHECK, no PG enum,
no index on transport. Deleting `"api"` from `@transports` therefore needs **no** constraint
migration — only (a) an optional `remove :api_key_encrypted` column drop and (b) a defensive
`update ... set transport='instance' where transport='api'` that will touch zero rows.

## R3 — no remote branch, no unmerged history, carries an api/hosted-provider mail adapter

```sh
git fetch --all -q
git for-each-ref --format='%(refname:short)' refs/remotes > /tmp/refs.txt   # 2490 refs
python3 - <<'EOF'
import subprocess
refs=[l.strip() for l in open('/tmp/refs.txt') if l.strip()]
p="cloud/lib/barkpark_cloud/notifications.ex"
main=subprocess.run(["git","rev-parse","origin/main:"+p],capture_output=True,text=True).stdout.strip()
blobs={}
for r in refs:
    o=subprocess.run(["git","rev-parse",r+":"+p],capture_output=True,text=True)
    if o.returncode==0 and o.stdout.strip()!=main: blobs.setdefault(o.stdout.strip(),[]).append(r)
for b in list(blobs)+[main]:
    t=subprocess.run(["git","cat-file","-p",b],capture_output=True,text=True).stdout
    print(b, t.count("defp deliver_alert"), t.count('transport: "api"'))
EOF
```

2249 remote refs carry the file; 19 distinct blobs total (18 non-main + main). **Every one**
has exactly 2 `defp deliver_alert` clauses and zero `transport: "api"` clauses. Same scan over
`refs/heads` (6118 local refs, 22 distinct blobs): one anomaly, `swarm/notifications-chat`
(2026-06-29, unpushed, 239-line pre-refactor file whose own commit message says "needs no
mailer") — a chat transport, not a mail adapter.

## R4 — no hosted-adapter dependency anywhere in the refspace

```sh
git log --all --oneline -S'Swoosh.Adapters.Resend' -S'req_swoosh'   # empty
git log --all --oneline -S'finch' -- cloud/mix.exs                  # empty
git log --all --oneline -S'api_key_encrypted'                       # 6c0ffdc57 only (#352, the original 2026-06 foundation)
```

`cloud/mix.exs` has 10 distinct blobs across the refspace; the only `Resend|SendGrid|Finch`
lines in any of them are the *comment* saying the hosted adapter "is deferred".

## R5 — deleting the option collides with nothing

```sh
git grep -n 'EmailSettings.transports\|transports/0' origin/main -- cloud   # zero call sites
git grep -n 'NOTIF_TRANSPORTS' origin/main -- cloud/priv/static/app.js      # 3274, 3311, 3486
git grep -n 'api_key' origin/main -- cloud/lib/barkpark_cloud/notifications.ex  # 149 (doc), 176 (write), 216 (mask)
git grep -n 'decrypt' origin/main -- cloud/lib/barkpark_cloud/notifications.ex  # smtp_host/username/password only
```

`api_key_encrypted` is written (`put_encrypted`), masked (`mask/1`) and **never decrypted** —
a write-only secret. The delete surface is: one doc line, one `@transports` member, one schema
field, one changeset cast entry, one JS array entry, one column.

**RULING: DELETE.** The DISCLOSE branch has no branch to protect.
