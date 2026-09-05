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
  Published documents whose `content` JSON contains this blob's delivery path.

  Returns `%{count: non_neg_integer(), sample: [map()]}` — `count` is the exact
  number of referring published documents, `sample` at most #{@sample_limit} of
  them as `%{doc_id:, type:, dataset:, title:}`.

  A blob with no `path` (which cannot be referenced by URL at all) yields a zero
  census rather than an error, so a caller never has to special-case it.
  """
  # @canonical capability:media-where-used aka:where-used,media references,orphan blob,referenced?,referrers,silent erasure,media delete guard doc:docs/cards/search-media.md
  def referrers(file_or_path)

  def referrers(%MediaFile{path: nil}), do: %{count: 0, sample: []}

  def referrers(%MediaFile{} = file), do: file |> delivery_path() |> scan()

  def referrers(path) when is_binary(path), do: path |> delivery_path() |> scan()

  @doc """
  True when at least one published document references the blob.
  """
  def referenced?(file_or_path), do: referrers(file_or_path).count > 0

  defp scan(url) do
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
        "refusing to delete #{file.filename}: #{count} published " <>
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
end
