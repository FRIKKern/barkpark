# felix-w29 V3 — upload/3 else restructure map (media dataset-swallow mirror)

Re-derivation recipes for the surgical else-clause insertion map handed to the
felix-w27-bl-media-dataset-swallow-mirror builder. All facts from origin/main
@ 71f06d62d5ccc5a1bd02efaec5e5e60ab5812581.

## Recipes

- upload/3 with-chain + do-block + full ordered else block (canonical read):
  `git show origin/main:api/lib/barkpark/media.ex | sed -n '55,155p'`

- exact line anchors of every structural point:
  `git show origin/main:api/lib/barkpark/media.ex | grep -n "def upload(plug_upload\|with {:ok, %{size:\|Blobstore.put_file(relative_path, temp_path\|attrs =\||> put_scope_attrs(opts)\|case result do\|_ = Blobstore.delete(relative_path)\|^    else$\|{:error, :unsupported_media_type} = rejected\|{:error, :payload_too_large} = rejected\|{:error, _reason} ->\|{:error, :storage_unavailable}"`

- put_scope_attrs/2 + resolve_dataset_id/2 (the swallow, inner `_ -> nil` at ~663):
  `git show origin/main:api/lib/barkpark/media.ex | sed -n '640,670p'`

- get_or_create_dataset/2 error set is EXACTLY two shapes ({:error, changeset} and {:error, :dataset_not_found}):
  `git show origin/main:api/lib/barkpark/tenancy.ex | sed -n '1095,1122p'`

- errors.ex live clauses that make the 422/409 envelope free (invalid_dataset guarded is_map at :564, conflict at :437):
  `git show origin/main:api/lib/barkpark/content/errors.ex | sed -n '437,438p;564,571p'`

## Line map (origin/main line numbers)

- 91  with-head opens: File.stat(temp_path)
- 92  validate_upload/3  (BEFORE any blob write → its rejects need NO cleanup)
- 100 Blobstore.put_file(...) do   ← blob PERSISTED after this clause succeeds
- 106-115 attrs = %{...} |> put_scope_attrs(opts)   ← runs INSIDE do-block today
- 117-122 result = insert; case result
- 136 error-arm blob cleanup for insert failure (already present)
- 139 else
- 143 {:error, :unsupported_media_type} = rejected -> rejected   (pre-blob, no cleanup)
- 146 {:error, :payload_too_large}      = rejected -> rejected   (pre-blob, no cleanup)
- 149 {:error, _reason} -> Blobstore.delete + {:error, :storage_unavailable}  ← 503 CATCH-ALL
- 155 end

## The restructure

1. Move `put_scope_attrs(opts)` OUT of the do-block into the with-head as a NEW
   clause AFTER put_file (blob already persisted), threading its tuple:
   `{:ok, attrs} <- put_scope_attrs(base_attrs, opts)`.
2. Insert TWO new else clauses BETWEEN line 146 and the 503 catch-all at 149:
   - `{:error, {:invalid_dataset, _}} = err -> _ = Blobstore.delete(relative_path); err`
   - `{:error, :conflict}            -> _ = Blobstore.delete(relative_path); {:error, :conflict}`
   Both fire AFTER put_file → blob is persisted → MUST Blobstore.delete first.
   Both MUST precede `{:error, _reason}` or the catch-all relabels them 503.
3. put_scope_attrs re-keys the changeset error under "dataset" (string wire key)
   into {:invalid_dataset, %{"dataset" => msgs}}, and converts :dataset_not_found
   → :conflict (retry-once first per direction). errors.ex maps both already.
