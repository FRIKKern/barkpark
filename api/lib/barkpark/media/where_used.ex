defmodule Barkpark.Media.WhereUsed do
  @moduledoc """
  Which PUBLISHED documents reference a media blob by its delivery URL.

  Papers (and every other content type) embed self-hosted media as a RAW URL
  STRING inside their block JSON — `/media/files/<path>` — never as a typed
  reference. So no reference graph can see them: `Media.Storage.Relations.graph/3`
  (the `bp media relations` where-used API) walks `mediaAsset` <-> `mediaAsset`
  `relatedAssets` edges ONLY, and `Content.Expand`/`Reference` resolve `_ref`
  maps. A document that shows a blob on every page is, to both of them, unrelated
  to it.

  That invisibility is what made `DELETE /v1/media/:dataset/:id` (and its legacy
  twin `DELETE /media/:id`) a silent-loss door: `Media.delete_file/2` removes the
  row, the blob, the renditions and the CDN copy irreversibly, the caller gets a
  clean 200 receipt, and the loss surfaces only when a reader opens a live paper
  and finds a broken image. Nothing on either delete path consulted usage.

  This module is the missing lookup: a `content::text` containment scan for the
  blob's delivery path over PUBLISHED rows. It is deliberately TEXTUAL rather
  than structural — the reference IS text, in an arbitrary position of a
  schemaless block tree, so any structural walk would have to enumerate shapes
  and would miss the next one someone invents.

  ## The one shape the textual scan cannot see (task-5f6e7ae324334044)

  A schema `image`/`file` FIELD never stores the delivery-path string: its
  value is `{"asset": {"_ref": assetDocId}, ...}` (docs/contracts/schema-v2.md)
  — a reference to the blob's companion `mediaAsset` DOCUMENT
  (`Media.asset_doc_for_file/3`), whose own `doc_id` is a different string from
  both `MediaFile.id` and `MediaFile.path`. An author who only ever uses the
  schema-managed image/file picker, never pasting a bare URL into a block, is
  therefore invisible to `scan/2` alone — even though the identical reference
  shape is already visible to `Content.Query.list_reference_holders/3` (the
  backlinks query). `referrers/1` now ALSO runs that structural lookup
  (`structural_referrers/1`) and merges its hits into the same census, so an
  image/file field reference is protected exactly like a raw URL embed is.
  Scoped to the blob's OWN dataset (`file.dataset`) — unlike the cross-dataset
  textual scan — because a document can only hold a `_ref` to an asset
  document that lives in its OWN dataset's row space; there is no cross-
  dataset structural case the way there is a cross-dataset URL-string one.

  UNLIKE the textual scan, the structural lookup counts DRAFT references too
  (a draft edit's `_ref`, or a never-published document's). Deleting a blob a
  draft references is the same unrecoverable data loss as deleting one a
  published page references, and nothing scopes the textual scan to
  published-only for a REASON that also applies here — it is a corpus-wide
  text scan with its own churn/cost tradeoffs the structural lookup (a single
  indexed read) does not share. So an author editing a draft, or one who never
  published at all, is protected exactly as a live page is.

  ## The census that sets the urgency (measured 2026-09-01, guerrilla prod)

  `GET /v1/data/query/production/paper` over the whole corpus (1050 papers, two
  pages) — 30 of them carry at least one `/media/files/...` URL, referencing 235
  DISTINCT blob paths. Every one of those 235 blobs was, before this module, one
  unguarded `DELETE` away from a silent hole in a live page, and the flagship
  `eight-minute-erasure` paper's two casts are among them. The reproduction is a
  containment grep over the query result:

      curl -sH "Authorization: Bearer $TOKEN" \\
        "$HOST/v1/data/query/production/paper?limit=1000" \\
      | python3 -c 'import sys,json,re;d=json.load(sys.stdin)["result"]["documents"];\\
        print(sum(1 for x in d if re.search(r"/media/files/", json.dumps(x))))'

  ## Scope: every dataset, deliberately

  The blob keyspace is FLAT (`media_files.path` has no dataset in it) and
  `/media/files/<path>` resolves the same from any dataset's document, so a
  reference from `staging` is a real reference to the same bytes. The scan is
  therefore NOT dataset-filtered: a guard that only looked in the deleter's own
  dataset would wave through exactly the cross-dataset case it exists to catch.

  ## What it does NOT claim

  A `false` from `referenced?/1` is not proof the blob is unused — an unpublished
  draft, an external mirror, or a consumer outside this database can still hold
  it. This answers one question only, and answers it conservatively: *does a
  published document in this database contain this blob's delivery path?*
  """

  import Ecto.Query, warn: false

  require Logger

  alias Barkpark.Content.Document
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo

  # The refusal names referrers so the operator can go fix them. Naming all of
  # them could be thousands of ids on a logo; the count is exact and the list is
  # a sample, and the envelope says which is which.
  @sample_limit 20

  @doc """
  The delivery path a document would carry for this blob: `/media/files/<path>`.

  This is the exact prefix `MediaController.serve/2` is routed on
  (`get("/files/*path", MediaController, :serve)`), so it is the string an author
  or an editor pastes into a block.
  """
  def delivery_path(%MediaFile{path: path}) when is_binary(path), do: "/media/files/" <> path
  def delivery_path(path) when is_binary(path), do: "/media/files/" <> path

  @doc """
  Published documents whose `content` JSON contains this blob's delivery path,
  OR whose schema `image`/`file` field structurally `_ref`s the blob's
  companion `mediaAsset` document (task-5f6e7ae324334044 — see the moduledoc's
  "one shape the textual scan cannot see").

  Returns `%{count: non_neg_integer(), sample: [map()]}` — `count` is the exact
  number of referring published documents, `sample` at most #{@sample_limit} of
  them as `%{doc_id:, type:, dataset:, title:}`.

  A blob with no `path` cannot be referenced by URL, but CAN still be
  referenced structurally (its companion asset document exists independently
  of whether the blob's own `path` is set) — so the nil-path arm still runs
  the structural lookup rather than short-circuiting to zero.
  """
  # @canonical capability:media-where-used aka:where-used,media references,orphan blob,referenced?,referrers,silent erasure,media delete guard doc:docs/cards/search-media.md
  def referrers(file_or_path)

  def referrers(%MediaFile{path: nil} = file),
    do: merge_censuses(%{count: 0, sample: []}, structural_referrers(file))

  # A MediaFile carries its tenant: the TEXTUAL census is confined to THAT
  # workspace (plus the shared NULL-workspace layer) — see
  # `scope_to_owner_tenant/2`. The structural census is confined to the blob's
  # own DATASET instead (see the moduledoc) — a different axis, so both run
  # and their hits are merged into one census.
  def referrers(%MediaFile{} = file),
    do:
      merge_censuses(
        file |> delivery_path() |> scan(Map.get(file, :workspace_id)),
        structural_referrers(file)
      )

  # A bare path has no tenant, no blob id and no dataset to resolve a
  # companion asset document from — the legacy all-tenant TEXTUAL-only read.
  def referrers(path) when is_binary(path), do: path |> delivery_path() |> scan(nil)

  @doc """
  True when at least one published document references the blob.
  """
  def referenced?(file_or_path), do: referrers(file_or_path).count > 0

  # TENANT, NOT DATASET (task-00a41cec5455bc91). The scan stays cross-DATASET on
  # purpose (moduledoc: the blob keyspace is flat), but it used to be
  # cross-WORKSPACE too: a `DELETE` from workspace A answered its 409 with the
  # doc ids, types and titles of ANOTHER tenant's pages that hotlinked the blob's
  # public URL, and that tenant's reference counted toward — and blocked — A's
  # delete of its own blob. The census now covers the blob's own workspace plus
  # the shared NULL-workspace layer (`scope_to_workspace_including_global/3`, the
  # canonical clause; a nil workspace keeps the legacy all-tenant read).
  defp scope_to_owner_tenant(query, workspace_id) do
    # global-read: a delete GUARD, not a content read. A blob with a workspace is narrowed to it; a legacy NULL-workspace blob keeps the pre-existing all-tenant census so it can never become LESS guarded than before.
    Barkpark.Content.Scope.scope_to_workspace_including_global(query, workspace_id, nil)
  end

  # A struct with no `id` (e.g. a caller re-probing the textual scan alone
  # after the real row was already deleted — `%MediaFile{path: file.path}`,
  # pre-existing in delete_file_where_used_policy_test.exs) has no blob id to
  # resolve a companion asset document from at all.
  defp structural_referrers(%MediaFile{id: nil}), do: %{count: 0, sample: []}

  # task-5f6e7ae324334044 — the structural half: does any document (draft OR
  # published) in the blob's own dataset hold a schema image/file field whose
  # `{"asset": {"_ref": ...}}` names this blob's companion `mediaAsset`
  # document?
  #
  # Admin/full-visibility context on purpose: this is an internal delete-guard
  # read, not a client-facing one, and it must see a PRIVATE image/file field's
  # reference exactly as readily as a public one — the blob is just as
  # unrecoverable either way.
  #
  # DRAFTS COUNT HERE, unlike the textual scan (which is published-only by
  # design — see the moduledoc's "What it does NOT claim"). Deleting a blob a
  # draft references is the SAME unrecoverable data loss as deleting one a
  # published page references; nothing in the textual scan's own published-
  # only scoping is written as a reason to exclude a draft, only as an
  # ACKNOWLEDGED gap in what a raw-text containment scan can promise (ruling,
  # 2026-10-09). The structural lookup has no equivalent reason to narrow
  # itself the same way: it is a single indexed read, not a corpus-wide text
  # scan, so there is no churn/cost tradeoff pushing it toward published-only.
  defp structural_referrers(%MediaFile{} = file) do
    case Barkpark.Media.asset_doc_for_file(file, file.dataset, MediaFile.scope_opts(file)) do
      nil ->
        %{count: 0, sample: []}

      asset_doc ->
        asset_doc_id = Barkpark.Content.published_id(asset_doc.doc_id)

        ctx = %Barkpark.Content.CallerContext{
          principal_type: :api_token,
          is_admin: true,
          roles: ["admin"]
        }

        # task-4bffdfa43b24e4a5 — MUST carry the blob's OWN tenant scope, not
        # just the caller context. Without workspace_id/project_id here,
        # base_query/4's scope_to_workspace_or_global(query, nil, nil) falls
        # to the NULL-workspace-only read, making any document stamped with a
        # REAL workspace_id (i.e. every document outside the legacy default
        # tenant) invisible to this lookup — a silent 0-hit false negative on
        # the exact data-loss guard this module exists to be.
        rows =
          Barkpark.Content.Query.list_reference_holders(
            asset_doc_id,
            file.dataset,
            Keyword.merge(MediaFile.scope_opts(file), caller_context: ctx)
          )

        sample =
          rows
          |> Enum.map(fn row ->
            %{doc_id: row.doc_id, type: row.type, dataset: file.dataset, title: row.title}
          end)

        %{count: length(sample), sample: Enum.take(sample, @sample_limit)}
    end
  end

  # Unions the textual and structural censuses by `doc_id`. Each half's `count`
  # is exact on its OWN query; de-duping a document hit by BOTH (a raw URL
  # pasted into one field while another field also holds a structural `_ref`
  # to the same blob) is only possible within the two capped samples — the
  # same honest-approximation the pre-existing `sampleTruncated` flag already
  # accepts for a count past `@sample_limit`. In practice a document uses one
  # embed style per field, so an overlap big enough to matter is the rare
  # case, not the modeled one.
  defp merge_censuses(%{count: 0, sample: []}, structural), do: structural
  defp merge_censuses(textual, %{count: 0, sample: []}), do: textual

  defp merge_censuses(%{count: c1, sample: s1}, %{count: c2, sample: s2}) do
    merged_sample = (s1 ++ s2) |> Enum.uniq_by(& &1.doc_id) |> Enum.take(@sample_limit)
    overlap = length(s1) + length(s2) - length(Enum.uniq_by(s1 ++ s2, & &1.doc_id))

    %{count: max(c1 + c2 - overlap, length(merged_sample)), sample: merged_sample}
  end

  defp scan(url, workspace_id) do
    # `content::text LIKE '%<url>%'` — a containment test against the rendered
    # JSON. `url` is a server-built string (a literal prefix plus the row's own
    # stored `path`), never caller text, but it is still bound as a PARAMETER so
    # a path containing `%` or `_` cannot widen the match: `like_escape/1` neuters
    # both wildcards and the query declares its own ESCAPE character.
    pattern = "%" <> like_escape(url) <> "%"

    query =
      from(d in Document,
        where: d.status == "published",
        where: fragment("(?)::text LIKE ? ESCAPE '\\'", d.content, ^pattern),
        select: %{
          doc_id: d.doc_id,
          type: d.type,
          dataset: d.dataset,
          title: d.title
        }
      )
      |> scope_to_owner_tenant(workspace_id)

    count = Repo.aggregate(query, :count)
    sample = Repo.all(from(q in subquery(query), limit: @sample_limit))

    %{count: count, sample: sample}
  end

  # LIKE metacharacters in the blob path would otherwise make the pattern match
  # MORE than the literal path — an over-broad match here means a refusal that
  # names documents which do not actually reference this blob.
  defp like_escape(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  @doc """
  The 409 envelope a delete refuses with, naming the referrers.

  Rendered by the controllers directly (not through `FallbackController`) so the
  referrer census can ride in `details` — the envelope reuses the already-public
  `conflict` code, so no client's error branching changes.
  """
  def refusal_envelope(%MediaFile{} = file, %{count: count, sample: sample}) do
    %{
      code: "conflict",
      message:
        "refusing to delete #{file.filename}: #{count} " <>
          "#{if count == 1, do: "document references", else: "documents reference"} " <>
          "#{delivery_path(file)}. Deleting it would blank the media in " <>
          "#{if count == 1, do: "that document", else: "those documents"} behind a 200 " <>
          "receipt, and the blob, its renditions and its CDN copy are not recoverable. " <>
          "Remove the reference(s) first, or repeat the request with ?force=true to " <>
          "delete anyway.",
      details: %{
        path: delivery_path(file),
        referencedByCount: count,
        referencedBy: sample,
        sampleTruncated: count > length(sample),
        override: "force=true"
      }
    }
  end

  @doc """
  Whether the caller explicitly opted out of the guard (`?force=true`).

  Only the literal strings `"true"` and `"1"` count. Anything else — including
  the mere PRESENCE of the parameter — leaves the guard armed, so a stray
  `?force=` in a copied URL cannot disarm an irreversible delete.
  """
  def forced?(params) when is_map(params), do: Map.get(params, "force") in ["true", "1"]
  def forced?(_), do: false

  @doc """
  The WITNESS an override leaves behind (task-ef676cfc88e71fae).

  `forced?/1` disarms an IRREVERSIBLE delete, and the guard used to answer it by
  skipping the census entirely: nothing logged, and a 200 receipt byte-identical
  to an unforced delete of an unreferenced blob. So the store kept a hole with no
  record that a human was told about the references and proceeded anyway, and
  whoever investigated the broken image later concluded "it was unreferenced when
  it was deleted" — the exact opposite of what happened.

  Called on the forced branch BEFORE `Media.delete_file/2` (the point of no
  return). It runs the same census the unforced branch runs, emits it at WARNING
  level, and returns the receipt fields the controller merges into its 200 so the
  CALLER's own log records the choice too.

  Deliberately logs IDENTIFIERS ONLY — the blob path, the referrer count, the
  sampled `doc_id`s and the actor label. The census is cross-dataset by design
  and includes the shared NULL-workspace layer (see `scan/2`), so logging
  document TITLES or bodies here would still spill content beyond the deleting
  dataset into a shared log file.

  Returns `%{forced: true, referencedByCount: count}`.
  """
  def witness_forced_delete(conn, %MediaFile{} = file) do
    %{count: count, sample: sample} = referrers(file)

    doc_ids = Enum.map(sample, & &1.doc_id)

    Logger.warning(
      "media force-delete override: path=#{delivery_path(file)} " <>
        "filename=#{file.filename} referrers=#{count} " <>
        "doc_ids=#{format_doc_ids(doc_ids, count)} actor=#{actor_label(conn)}"
    )

    %{forced: true, referencedByCount: count}
  end

  defp format_doc_ids([], _count), do: "none"

  defp format_doc_ids(ids, count) do
    joined = Enum.join(ids, ",")
    if count > length(ids), do: joined <> ",…(#{count - length(ids)} more)", else: joined
  end

  # LOG-ONLY attribution, read by the operator, never compared. The lock stamp
  # (`checkedOutBy`) is a different thing: `Media.Storage.Actor`, which names an
  # account by "user:<id>", never by email (task-36a302b2e981d5e1).
  defp actor_label(%{assigns: assigns}) do
    case assigns[:api_token] do
      %{label: label} when is_binary(label) and label != "" ->
        label

      _ ->
        case assigns[:current_user] do
          %{email: email} when is_binary(email) and email != "" -> email
          _ -> "api"
        end
    end
  end

  defp actor_label(_), do: "api"
end
