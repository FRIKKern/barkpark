<!-- doc-tier: human | canonical-for: template-manifest | budget: 2400tok -->
# `barkpark.template.json` — template manifest spec

A declarative deploy descriptor. A **deploy-button UI** enumerates templates by
reading these files; a **server-side bootstrap job** consumes one to stand up a
Barkpark-backed site with no ad-hoc `install.sh`. It captures, as data, the six
steps `bp vercel quick-setup` performs imperatively today (workspace → schema →
seed → publish → read-token → env/deploy — `internal/cli/vercel_cmd.go`).

- **JSON Schema:** [`barkpark.template.schema.json`](./barkpark.template.schema.json) (draft-07)
- **Go loader/validator:** `internal/template` — `Load([]byte) → *Template`, then `(*Template).Validate()`. This is the executable spec the provisioner (dwb-4) imports.
- **Drift gate:** `internal/template.TestRealManifests` loads + validates every checked-in manifest and asserts its referenced schema/seed paths exist. CI fails on drift.

## Shape

```jsonc
{
  "manifestVersion": "1",            // format version, currently "1"
  "name": "place-directory",         // lowercase kebab slug — the deploy-UI key
  "title": "Place Directory",        // human title
  "description": "A map-backed …",   // one line
  "framework": "nextjs",             // enum: nextjs
  "repo": "https://github.com/…",    // optional git URL of the deployable app
  "dataset": "production",           // optional, default "production"
  "demoContent": true,               // optional — ships sample content vs bare scaffold
  "schemas": ["schemas/place.json"], // ≥1 relative paths, applied in order
  "seed": {                          // optional
    "path": "seed-places.json",
    "format": "mutations",           // mutations | ndjson | script  (default mutations)
    "publish": true,                 // publish after seeding
    "publishType": "place"           // REQUIRED when publish+mutations
  },
  "env": [                           // optional — what the provisioner materializes
    { "key": "BARKPARK_TOKEN", "role": "server", "source": "read_token",
      "description": "…" }
  ]
}
```

All relative paths (`schemas[]`, `seed.path`) resolve against the directory the
manifest lives in.

## Fields that carry a contract

**`seed.format`** decides how the seed lands:
- `mutations` — a `{"mutations":[…]}` body POSTed to `/v1/data/mutate`.
  `createOrReplace` writes **DRAFTS**, so publishing is a *separate* mutation
  that needs `{id, type}` — hence `publishType` is **required** when
  `publish:true` on this format. (The place-directory shape.)
- `ndjson` — newline-delimited documents (dataset export/import shape).
- `script` — an executable seed script (e.g. `seeds/seed.ts`) that does its OWN
  create + publish. No `publishType`; the script owns per-document typing. (The
  create-barkpark-app starters, which seed multiple types.)

**`env[].role`** is browser-exposure, not secrecy alone: `server` = server-only
(tokens, API base — never shipped to the browser); `public` = safe to expose (a
Next.js `NEXT_PUBLIC_` value).

**`env[].source`** is the wiring contract with the provisioner — where each
value comes from at bootstrap:

| source | value the provisioner supplies |
|---|---|
| `api_url` | resolved Barkpark API base |
| `read_token` | the minted read-only, workspace-bound token |
| `dataset` / `workspace` / `project` | the chosen slugs |
| `webhook_secret` | a generated HMAC/preview secret |
| `literal` | the baked `value` field (required for this source) |

Env keys follow the **starter convention** (`BARKPARK_API_URL`,
`BARKPARK_TOKEN`, `BARKPARK_SERVER_TOKEN`, `BARKPARK_WORKSPACE`,
`BARKPARK_PROJECT`, `BARKPARK_DATASET`) — the naming dwb-3 unifies across
surfaces.

## Retrofitted manifests

- `templates/place-directory/barkpark.template.json` — JSON schema + mutations seed, publishes `place`.
- `js/packages/create-barkpark-app/templates/website-starter/barkpark.template.json` — `.ts` schemas + script seed.
- `js/packages/create-barkpark-app/templates/blog-starter/barkpark.template.json` — same, plus a `webhook_secret` env.

## Validation

`Load` rejects unknown fields and trailing data (strict decode). `Validate`
enforces required fields, enum membership, the slug shape, and the
publish-needs-type rule, returning the first violation. Run the gate:

```sh
go test ./internal/template/...
```
