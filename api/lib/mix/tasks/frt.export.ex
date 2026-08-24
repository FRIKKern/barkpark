defmodule Mix.Tasks.Frt.Export do
  @moduledoc """
  Export the published `frt` dataset to a deterministic, hashable JSON
  artifact a Godot build can consume — WITHOUT touching the game's existing
  `source-truth.json` or the M0 gate.

  This is the read-only sibling of `mix frt.seed`: where seed WRITES the frt
  documents into the CMS, export READS the PUBLISHED documents back out and
  flattens them into one self-describing JSON file keyed by type. The output is
  byte-deterministic for identical content (recursively sorted map keys, all
  numeric values stored as strings → no float-format drift), so a committed
  `content_hash` is a stable determinism pin a CI gate can assert against.

  It does NOT replace `source-truth.json`: the two coexist. `source-truth.json`
  remains the M0 source-of-truth gate; this artifact is a CMS-derived build
  input the game loads at runtime.

  ## Usage

      mix frt.export                     # print JSON to stdout
      mix frt.export --out frt.gen.json  # write JSON to a file
      mix frt.export --dataset frt       # choose the dataset (default "frt")

  Flags:

    * `--out PATH`     — write the JSON document to PATH (default: stdout).
    * `--dataset NAME` — the dataset to export (default: `"frt"`).

  A one-line summary (`doc_count`, `content_hash`, `out`) is always printed to
  STDERR so stdout stays a clean JSON stream when piped.

  ## Output shape

      {
        "_meta": {
          "format_version": 1,
          "generated_for": "frt",
          "doc_count": 142,
          "content_hash": "<sha256-hex of the canonical-encoded `types` map>"
        },
        "types": {
          "gameClock":  { ... },          # SINGLETON → a single object
          "enemyType":  [ { ... }, ... ], # COLLECTION → list sorted by doc_id
          ...
        }
      }

  Each document object is its `content` map merged with `"_id"` (the doc_id)
  and `"_title"` (the row title); all internal/tenancy fields (`rev`,
  `dataset_id`, `workspace_id`, `project_id`, `id`, `inserted_at`,
  `updated_at`, `status`, `dataset`, `type`) are stripped.

  Seven types are SINGLETONS (one object, not a list): `coordinatorLoop`,
  `gameClock`, `player`, `weapon`, `runRuleset`, `arena`, `theme`. Every other
  type is a list sorted by `_id`.

  ## Determinism contract

  The `content_hash` is computed over the `types` map ONLY (never `_meta`), so
  it is stable regardless of `doc_count` / meta churn — re-run with the same
  published content and the hash is identical. `canonical_iodata/1` sorts map
  keys recursively, so input map ordering never affects the bytes.

  ## Godot loader (reference)

      # var f := FileAccess.open("res://data/frt_content.gen.json", FileAccess.READ)
      # var data: Dictionary = JSON.parse_string(f.get_as_text())
      # var enemies: Array = data["types"]["enemyType"]   # collections are arrays
      # var clock: Dictionary = data["types"]["gameClock"] # singletons are objects
      # assert(data["_meta"]["content_hash"] == pinned_hash)  # determinism pin
  """
  @shortdoc "Export the frt dataset to deterministic JSON for the Godot game"

  use Mix.Task

  alias Barkpark.Content
  alias Barkpark.Tenancy

  @default_dataset "frt"

  # The seven types that resolve to exactly ONE document (a single object in
  # the output), not a list. Mirrors the singleton convention in mix frt.seed.
  @singletons ~w(coordinatorLoop gameClock player weapon runRuleset arena theme)

  # Document/tenancy fields stripped from every exported object — only the
  # publisher-authored `content` (plus injected `_id`/`_title`) survives.
  @strip_keys ~w(rev dataset_id workspace_id project_id id inserted_at updated_at status dataset type)

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args, strict: [out: :string, dataset: :string])

    out = Keyword.get(opts, :out)
    dataset = Keyword.get(opts, :dataset, @default_dataset)

    # Boot the app so Repo + tenancy tables are live. Confirmed safe: app.start
    # does NOT bind the web port.
    Mix.Task.run("app.start")

    {ws_id, project_id, _dataset_id} = resolve_scope!(dataset)

    docs = list_published_docs(dataset, ws_id, project_id)

    doc_maps = Enum.map(docs, &doc_to_map/1)
    types = build_types(doc_maps)
    hash = content_hash(types)

    document = %{
      "_meta" => %{
        "format_version" => 1,
        "generated_for" => dataset,
        "doc_count" => length(doc_maps),
        "content_hash" => hash
      },
      "types" => types
    }

    json = IO.iodata_to_binary([canonical_iodata(document), "\n"])

    if out do
      File.write!(out, json)
    else
      IO.puts(json)
    end

    IO.puts(
      :stderr,
      "frt.export: doc_count=#{length(doc_maps)} content_hash=#{hash} out=#{out || "(stdout)"}"
    )
  end

  # ── DB plumbing (impure; not exercised by the unit test) ────────────────────

  # Resolve {workspace_id, project_id, dataset_id} for `dataset`. Read-only
  # mirror of frt.seed's resolve_scope!/0: the Default workspace/project must
  # already exist (export reads what seed wrote), and the dataset row is
  # get-or-created to obtain the authoritative dataset_id used for scoping.
  defp resolve_scope!(dataset) do
    workspace =
      Tenancy.get_default_workspace() ||
        Mix.raise("frt.export: no Default workspace — run `mix frt.seed` first")

    project =
      Tenancy.get_default_project() ||
        Mix.raise("frt.export: no Default project — run `mix frt.seed` first")

    {:ok, %Tenancy.Dataset{id: dataset_id}} =
      Tenancy.get_or_create_dataset(project.id, dataset)

    {workspace.id, project.id, dataset_id}
  end

  # List every PUBLISHED document in `dataset`, across all registered types.
  # Types are enumerated via the schema catalogue (Content.list_schemas/2);
  # each type is then WALKED published-perspective, paging past the server's
  # row cap.
  #
  # This used to pass `limit: 1000` with a comment claiming "a high row cap so
  # a large collection is not truncated". That was false: `list_documents/3`
  # CLAMPS :limit to 1000, so 1000 was the CEILING, not a generous headroom —
  # any type with more than 1000 published documents was silently dropped from
  # the export FILE, which is the artifact an operator then restores from.
  # `Mix.raise` on a truncated walk: a half-corpus export must never be written
  # to disk looking like a whole one.
  defp list_published_docs(dataset, ws_id, project_id) do
    scope = [workspace_id: ws_id, project_id: project_id]

    dataset
    |> Content.list_schemas(scope)
    |> Enum.map(& &1.name)
    |> Enum.flat_map(fn type ->
      case Content.collect_all_documents(
             type,
             dataset,
             scope ++ [perspective: :published]
           ) do
        {docs, nil} ->
          docs

        {docs, :cap} ->
          Mix.raise(
            "frt.export: the corpus walk for type #{type} in dataset #{dataset} hit its page " <>
              "bound at #{length(docs)} documents — the collection is LARGER than the walk. " <>
              "Refusing to write a partial export that would read as complete."
          )
      end
    end)
  end

  # A loaded %Document{} → a plain string-keyed map carrying its content plus
  # the doc_id and title under explicit keys (so the pure helpers never touch
  # the Ecto struct).
  defp doc_to_map(doc) do
    %{
      "doc_id" => doc.doc_id,
      "type" => doc.type,
      "title" => doc.title,
      "content" => doc.content || %{}
    }
  end

  # ── PURE helpers (DB-free; the unit test exercises these directly) ──────────

  @doc """
  Flatten a list of doc maps into `%{type_name => singleton | sorted_list}`.

  Each `doc` is a string-keyed map carrying `"doc_id"`, `"type"`, `"title"`,
  and a `"content"` map. The output value is a single object for the seven
  singleton types and a `doc_id`-sorted list for every other type. Each
  object is the `content` map merged with `"_id"`/`"_title"`; all internal and
  tenancy fields are stripped.
  """
  @spec build_types([map()]) :: map()
  def build_types(docs) when is_list(docs) do
    docs
    |> Enum.group_by(fn doc -> doc["type"] end)
    |> Map.new(fn {type, type_docs} ->
      objects = Enum.map(type_docs, &to_object/1)

      value =
        if type in @singletons do
          # A singleton resolves to one object. If (defensively) more than one
          # published doc shares a singleton type, the lowest doc_id wins —
          # deterministic, never a crash.
          objects
          |> Enum.sort_by(& &1["_id"])
          |> List.first()
        else
          Enum.sort_by(objects, & &1["_id"])
        end

      {type, value}
    end)
  end

  # One doc map → its export object: content merged with _id/_title, stripped.
  defp to_object(doc) do
    content = doc["content"] || %{}

    content
    |> Map.drop(@strip_keys)
    |> Map.merge(%{"_id" => doc["doc_id"], "_title" => doc["title"]})
  end

  @doc """
  Encode `term` to deterministic JSON iodata with RECURSIVELY SORTED map keys.

  Maps emit `{"k":v,...}` with keys sorted via `Enum.sort`; lists emit
  `[..]`; strings are escaped through `Jason.encode!/1`; numbers, booleans and
  `nil` are emitted as JSON literals. Identical content always yields
  byte-identical output regardless of input map ordering.
  """
  @spec canonical_iodata(term :: any()) :: iodata()
  def canonical_iodata(term) when is_map(term) do
    pairs =
      term
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map(fn k ->
        [encode_key(k), ":", canonical_iodata(Map.fetch!(term, k))]
      end)
      |> Enum.intersperse(",")

    ["{", pairs, "}"]
  end

  def canonical_iodata(term) when is_list(term) do
    items =
      term
      |> Enum.map(&canonical_iodata/1)
      |> Enum.intersperse(",")

    ["[", items, "]"]
  end

  def canonical_iodata(term) when is_binary(term), do: Jason.encode!(term)
  def canonical_iodata(term) when is_boolean(term), do: if(term, do: "true", else: "false")
  def canonical_iodata(nil), do: "null"
  def canonical_iodata(term) when is_integer(term), do: Integer.to_string(term)
  def canonical_iodata(term) when is_float(term), do: Jason.encode!(term)
  def canonical_iodata(term) when is_atom(term), do: Jason.encode!(Atom.to_string(term))

  # Object keys are always JSON strings. A non-binary key (defensive) is
  # stringified first so the output is still valid JSON.
  defp encode_key(k) when is_binary(k), do: Jason.encode!(k)
  defp encode_key(k), do: Jason.encode!(to_string(k))

  @doc """
  Stable lowercase-hex SHA-256 of the canonical encoding of `types`.

  Computed over `types` ONLY (not `_meta`), so the hash is independent of
  `doc_count`/meta churn. Identical content — even with differently ORDERED
  input maps — produces an identical hash; different content differs.
  """
  @spec content_hash(map()) :: String.t()
  def content_hash(types) do
    :sha256
    |> :crypto.hash(canonical_iodata(types))
    |> Base.encode16(case: :lower)
  end
end
