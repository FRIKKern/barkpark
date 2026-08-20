<!-- doc-tier: cold | canonical-for: cch-v8-registry-deploy-txn-gap-rederivation | budget: 900tok -->

# V8 — registry.ex / deploy.ex unread write-cluster transaction-gap re-derivation (2026-08-18)

VERDICT: ZERO new transaction gaps in the un-sampled write clusters. Every multi-write
cluster is already wrapped in `Repo.transaction` or `Ecto.Multi`; everything else is a
single bare write. The class-1 transaction-gap denominator holds.

## Re-derive (origin/main)

    # registry.ex named clusters — writes vs transaction wrappers
    git show origin/main:cloud/lib/barkpark_cloud/registry.ex | sed -n '4429,4603p;2180,2260p;6120,6160p' \
      | grep -nE 'Repo\.(insert|update|delete)|transaction|Multi'

    # deploy.ex tail — no bare multi-write clusters
    git show origin/main:cloud/lib/barkpark_cloud/sites/deploy.ex | sed -n '1440,2377p' \
      | grep -nE 'Repo\.(insert|update|delete)|transaction'

    # full deploy.ex write census
    git show origin/main:cloud/lib/barkpark_cloud/sites/deploy.ex \
      | grep -nE 'Repo\.(insert|update|delete|transaction)|Multi\.'

## Cluster-by-cluster

| Site | Function | Writes | Wrapped? |
|---|---|---|---|
| registry.ex:2196 | `succeed_attach_domain_job/3` | lock + changeset update | YES — `Repo.transaction` claim-fence (bp-c55) |
| registry.ex:2908 | `connect_provider/4` | 1 upsert (`on_conflict`) | single write |
| registry.ex:2960 | `disconnect_provider/2` | 1 `delete_all` | single write |
| registry.ex:4449/4469 | `set_autoupdate_halted`, `mark/clear_autoupdate_triggered` | 1 each | single write |
| registry.ex:~4534 | `put_env_var/2` | 1 `insert_or_update` (+read-only ownership gate) | single write; TOCTOU fails closed via `assoc_constraint` |
| registry.ex:4615 | `delete_env_var/2` | 1 `delete` | single write |
| registry.ex:5200 | `set_cf_binding/2` | 1 update | wrapped (redundantly) in `Repo.transaction` |
| registry.ex:6132 | `create_preview_deployment/4` | supersede + evict + insert | YES — whole lifecycle in `Repo.transaction`, rolls back on lost race |
| deploy.ex:374-377 | artifact stamp | insert + update | YES — `Ecto.Multi` |
| deploy.ex:404 | artifact GC | 1 `delete_all` | single write |
| deploy.ex:~1884 | site rollback repoint | 1 helper write (`set_site_current_deployment`) | single write; SKIPPED-write-still-200 is deploy-reliability W27 (KNOWN, distinct class — not a partial-write gap) |

No cluster performs 2+ bare `Repo.insert/update/delete` without a transaction/Multi.
