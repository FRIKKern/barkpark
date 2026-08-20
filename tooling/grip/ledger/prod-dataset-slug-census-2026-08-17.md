# prod-dataset-slug-census — 2026-08-17 (Felix wave 26, verify lane)

DECIDING FACT for #11853 loosen-vs-keep-regex: NO persisted dataset slug on guerrilla
production violates `^[a-z0-9][a-z0-9-]*$`. 21 datasets, 0 violators, 0 underscores.
Verdict: KEEP regex, rename test fixtures (data-reality wins over autopsy's loosen call).

## Re-derivation

DB is `barkpark_prod` (owner `barkpark`) on guerrilla 157.180.90.121.

```
cat <<'SQL' | ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 "cat > /tmp/census.sql && sudo -u postgres psql barkpark_prod -f /tmp/census.sql"
SELECT slug FROM datasets WHERE slug !~ '^[a-z0-9][a-z0-9-]*$';
SELECT count(*) AS total, count(*) FILTER (WHERE slug ~ '_') AS with_underscore FROM datasets;
SELECT slug FROM datasets ORDER BY slug;
SQL
```

Result (2026-08-17): violators = 0 rows; total=21, with_underscore=0.

`datasets` has NO slug on documents — content tables reference `dataset_id` (uuid FK).
FK-join proof: `SELECT count(*) FROM documents dc JOIN datasets d ON d.id=dc.dataset_id
WHERE d.slug !~ '^[a-z0-9][a-z0-9-]*$'` = 0. Docs live only in conforming slugs
(production 8127, aker-brygge 16, bl-preview-crash-scratch 6, tasks 2).

All 21 slugs: aker-brygge(x2 diff projects), bl-preview-crash-scratch, cchscratch,
default, demo, development, docs, local, papers, production(x5 diff projects), query,
sandbox, search-demo, staging, tasks, test. NOTE: 'paperflow' does NOT exist on prod.
