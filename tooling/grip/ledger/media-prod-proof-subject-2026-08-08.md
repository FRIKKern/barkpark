# media-prod-proof-subject — re-derivation recipes (http-edge-truth W1 slice 2)

Verifier lane: can the D2 post-merge L1 curl transcript observe slice 2's fix on prod?
All rows re-derive from scratch. Prod = guerrilla 157.180.90.121, ssh key ~/.ssh/barkpark_indx.

## R1 — prod serves media from the LOCAL {:file, path} branch (200 + etag, not 302)

    curl -sS -D- -o /dev/null 'https://guerrilla.barkpark.cloud/media/files/2026/08/popover-light-9edaf3a8.png' | grep -iE '^(HTTP|location|cache-control|etag)'

Expect: `HTTP/2 200`, `cache-control: public, max-age=31536000, immutable`, `etag: "51355-TDO699D"`, NO location.
Backend proof (config, not inference):

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'cut -d= -f1 /opt/barkpark/.env | sort' | grep -i 'MEDIA_STORAGE\|S3_'

Expect: EMPTY. `git show origin/main:api/config/runtime.exs | sed -n '439,450p'` — unset ⇒ :local;
`git show origin/main:api/lib/barkpark/media/blobstore.ex | sed -n '180,183p'` — `:s3 -> S3; _ -> Local`.

## R2 — Caddy is transparent for cache-control/etag (edge != origin credit)

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'grep -inE "header|cache|encode" /etc/caddy/Caddyfile'

Expect: the ONLY `header` is `header Retry-After "15"` inside `handle_errors`. No `encode`, no cache directive.
Origin/edge diff:

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'curl -sS -D- -o /dev/null http://localhost:4000/media/files/2026/08/popover-light-9edaf3a8.png'

Expect: byte-identical cache-control + etag to R1. Caddy adds only alt-svc, via, HTTP/2 framing.

## R3 — conformance gap: only an EXACT first-value If-None-Match 304s

    U='https://guerrilla.barkpark.cloud/media/files/2026/08/popover-light-9edaf3a8.png'
    for h in '"51355-TDO699D"' 'W/"51355-TDO699D"' '"abc", "51355-TDO699D"' '*'; do
      printf '%-28s ' "$h"; curl -sS -o /dev/null -w 'status=%{http_code} bytes=%{size_download}\n' -H "If-None-Match: $h" "$U"
    done

Expect: strong=304/0, weak=200/51355, list=200/51355, star=200/51355.
Code that explains it: `git show origin/main:api/lib/barkpark/media/delivery/urls.ex | sed -n '51,65p'` — `[^etag | _] ->` .
NB: re-derive the current etag from R1 first; it is size-mtime, so it rotates whenever the blob is re-written.

## R4 — asset-doc linkage census (blast radius of the nil -> public arm)

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'sudo -u postgres psql -d barkpark_prod -At \
      -c "select count(*) from media_files;" \
      -c "select count(*) from media_files f where not exists (select 1 from documents d where d.type='"'"'mediaAsset'"'"' and d.content->>'"'"'mediaFileId'"'"' = f.id::text and d.dataset = f.dataset);" \
      -c "select d.dataset, d.status, coalesce(d.content->>'"'"'bp_visibility'"'"','"'"'<ABSENT>'"'"') v, count(*) from documents d where d.type='"'"'mediaAsset'"'"' group by 1,2,3 order by 4 desc;"'

Expect (2026-08-08): `184` / `0` / `production|draft|public|184`.
Linkage column derived from `git show origin/main:api/lib/barkpark/plugins/media/assets.ex | sed -n '98,104p'`
(`content->>'mediaFileId'` + dataset scope), which is what `Media.asset_doc_for_file/2` calls from
`MediaController.serve` with no workspace opts.

## R5 — the non-admin seeding route for a private proof subject

    git show origin/main:api/lib/barkpark_web/router.ex | sed -n '2160p'      # patch("/:dataset/:id", V1.MediaController, :update)
    git show origin/main:api/lib/barkpark_web/router.ex | sed -n '604,631p'   # pipeline :media_mutate — NO require_admin
    git show origin/main:api/lib/barkpark/media.ex | sed -n '14p'             # @metadata_fields ... bp_visibility
    git show origin/main:api/lib/barkpark/media/storage/access.ex | sed -n '15,20p'  # nil -> "public"

Seed command shape (needs a write-permitted, NON-admin bearer; do NOT run against prod without the human gate):

    curl -sS -X PATCH -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
      -d '{"bp_visibility":"private"}' \
      https://guerrilla.barkpark.cloud/v1/media/production/<media_file_id>

Note `metadata_params/1` (v1/media_controller.ex:521-525) is an open passthrough
(`Map.drop(params, ["dataset","id"])`); the allowlist is `pick_metadata/1` -> `@metadata_fields`.
