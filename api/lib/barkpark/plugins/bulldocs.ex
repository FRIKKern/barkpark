defmodule Barkpark.Plugins.Bulldocs do
  @moduledoc """
  Bulldocs — the live, no-reload paper/document surface, as a first-party plugin.

  Bulldocs is the *producer* brand; a **paper** is what it produces. An external
  tool (formerly "paperflow") POSTs block-structured papers to Bulldocs's ingest
  API; Bulldocs stores them as type-`"paper"` documents and renders them at
  `/papers/:slug` with real-time per-block streaming and rev-gap recovery.

  This was the built-in "Papers" feature until it was lifted onto the plugin
  highway. The split (decided with the maintainer): the *core* keeps the
  reusable machinery — `Barkpark.PortableDoc.{Render,Patch,Projection,Synthesis}`,
  the generic block-document write paths in `Barkpark.Content`
  (`apply_document_block_op/5`, `upsert_document/4`, `doc_topic/4`), and the
  `RequireIngestToken` plug — and Bulldocs is the plugin that wires them into a
  product: it declares the `paper` schema, mounts the reader + ingest routes,
  and (later steps) owns the paper lifecycle-event workflow.

  ## What this module contributes

    * `register_schemas/1` — the `paper` document type (read from
      `priv/plugins/bulldocs/schemas/paper.json`). Auto-registers on every boot
      via `Barkpark.Plugins.Bootstrap.register_all_schemas/0`, idempotent on
      `(name, dataset)`.
    * `register_routes/1` — the public reader (`/papers/:slug`, `:public_root`)
      and the token-gated ingest/intents API (`:ingest`), mounted through the
      plugin route highway (`BarkparkWeb.Router.Plugins`).

  The artifact stays a "paper": the persisted `type` discriminator is still
  `"paper"` and the reader URL is still `/papers/:slug`, so no data migration
  and no public-URL break — only the producer/brand and the code namespace
  became Bulldocs.
  """

  use Barkpark.Plugin, manifest_path: "../../../priv/plugins/bulldocs/plugin.json"

  alias Barkpark.Content.SchemaDefinition

  # Compile-time absolute path to this plugin's bundled schema JSON. Matches the
  # source-tree prod deploy model (Barkpark compiles + runs in place under
  # /opt/barkpark), mirroring how `Barkpark.Plugins.OnixEdit` resolves its
  # schemas dir.
  @schemas_dir Path.expand("../../../priv/plugins/bulldocs/schemas", __DIR__)

  @doc """
  Declares the `paper` document type. The shape mirrors the legacy seed/
  migration row exactly (title "Papers", icon, public visibility, the four
  flat string fields), so re-upserts via Bootstrap never drift an existing
  row.
  """
  @impl Barkpark.Plugin
  def register_schemas(_opts) do
    raw =
      @schemas_dir
      |> Path.join("paper.json")
      |> File.read!()
      |> Jason.decode!()

    [
      %SchemaDefinition{
        name: Map.fetch!(raw, "name"),
        title: Map.get(raw, "title"),
        icon: Map.get(raw, "icon"),
        visibility: Map.get(raw, "visibility", "public"),
        fields: Map.get(raw, "fields", []),
        dataset: "production"
      }
    ]
  end

  @doc """
  Mounts Bulldocs's web surfaces through the plugin route highway
  (`BarkparkWeb.Router.Plugins`):

    * the public reader at `/papers/:slug` (`:public_root` — its own
      full-document `:bulldocs` root layout, no studio chrome), reusing the core
      `BarkparkWeb.BulldocsLive`;
    * the token-gated ingest + intents API under `/v1/plugins/bulldocs/…`
      (`:ingest` — RequireIngestToken pipeline), reusing the core
      `BulldocsIngestController` / `BulldocsIntentsController`.

  The reader URL stays `/papers/:slug` (the artifact noun is unchanged). The
  ingest API gains the canonical plugin prefix `/v1/plugins/bulldocs/…`; the
  host keeps `/v1/paperflow/*` as a back-compat alias for existing producers
  (see `BarkparkWeb.Router`).

  These point at modules that remain in core — Bulldocs is the wiring layer, the
  core block-document machinery is the utility it builds on.
  """
  @impl Barkpark.Plugin
  def register_routes(_ctx) do
    [
      {:live, "/papers/:slug", BarkparkWeb.BulldocsLive, :index,
       auth: :public_root, root_layout: {BarkparkWeb.Layouts, :bulldocs}},
      # Dataset-scoped reader (mirrors the studio `/d/:dataset/...` convention):
      # SAME live mount, SAME `:public_root` bucket + bulldocs root layout as the
      # flat reader above. The `:dataset` path param is read in BulldocsLive's
      # mount and threaded to the public-paper fetch; absent on the flat route it
      # defaults to `Content.paper_default_dataset()` (back-compat).
      {:live, "/d/:dataset/papers/:slug", BarkparkWeb.BulldocsLive, :index,
       auth: :public_root, root_layout: {BarkparkWeb.Layouts, :bulldocs}},
      {:post, "/bulldocs/papers", BarkparkWeb.BulldocsIngestController, :ingest, auth: :ingest},
      {:post, "/bulldocs/papers/:slug/ops", BarkparkWeb.BulldocsIngestController, :apply_op,
       auth: :ingest},
      {:get, "/bulldocs/intents", BarkparkWeb.BulldocsIntentsController, :index, auth: :ingest},
      {:post, "/bulldocs/intents/:id/processed", BarkparkWeb.BulldocsIntentsController,
       :mark_processed, auth: :ingest}
    ]
  end

  @doc """
  Ergonomic CLI verbs Bulldocs contributes to the `/v1/capabilities` manifest
  (M3). Each command is grounded in a route that `register_routes/1` ABOVE
  actually mounts — `path_template` is the flat plugin path (the canonical
  `/v1/plugins/bulldocs/…` prefix; the `/v1/paperflow/…` alias is a back-compat
  mirror, not modelled here). Every ingest route maps to `auth_tier: "ingest"`,
  the route's highway bucket.

  Five verbs over four routes:

    * `publish` — `POST /v1/plugins/bulldocs/papers` (the ingest endpoint;
      `blocks` or `body_html` payload from a file/stdin). WRITES, MINIMAL receipt.
    * `patch` — `POST /v1/plugins/bulldocs/papers/:slug/ops` (the batch ops
      endpoint). Accepts an `{ops:[…]}` BATCH body applied atomically; carries
      the optional `--if-rev` optimistic-concurrency guard (M3) the controller +
      `Content.apply_paper_block_ops/2` honour. WRITES, BATCH.
    * `intents` — `GET /v1/plugins/bulldocs/intents` (pending actionable intents,
      oldest first). READ-shaped over the ingest pipeline.
    * `intent-processed` — `POST /v1/plugins/bulldocs/intents/:id/processed`
      (mark one intent drained). WRITES.

  No `get`/`ls` paper verb is declared: the paper reader at `/papers/:slug` is a
  LiveView (`:public_root`), not a JSON API route, so there is no honest flat
  `http.path_template` for it — declaring one would invent an endpoint.
  """
  @impl Barkpark.Plugin
  def cli_commands do
    [
      %{
        id: "bulldocs.publish",
        noun: "bulldocs",
        verb: "publish",
        summary: "Publish (upsert) a paper from a portable-doc or HTML payload.",
        http: %{method: "POST", path_template: "/v1/plugins/bulldocs/papers"},
        auth_tier: "ingest",
        args: [
          %{name: "slug", required: true, type: "slug", summary: "Paper slug (its public id)."}
        ],
        flags: [
          %{
            name: "file",
            type: "file",
            summary: "Payload (blocks or body_html) from a file or - for stdin."
          }
        ],
        writes: true,
        batch: false,
        paginated: false,
        dry_run: false,
        default_output: "minimal",
        scoped_prefix: nil
      },
      %{
        id: "bulldocs.patch",
        noun: "bulldocs",
        verb: "patch",
        summary: "Apply an atomic batch of block ops to a paper (optimistic --if-rev guard).",
        http: %{method: "POST", path_template: "/v1/plugins/bulldocs/papers/:slug/ops"},
        auth_tier: "ingest",
        args: [
          %{name: "slug", required: true, type: "slug", summary: "Paper slug to patch."}
        ],
        flags: [
          %{
            name: "file",
            type: "file",
            summary: "Ops payload {\"ops\":[…]} from a file or - for stdin."
          },
          %{
            name: "if-rev",
            type: "int",
            summary: "Reject unless the paper is still at this rev (optimistic concurrency)."
          }
        ],
        writes: true,
        batch: true,
        paginated: false,
        dry_run: false,
        default_output: "minimal",
        scoped_prefix: nil
      },
      %{
        id: "bulldocs.intents",
        noun: "bulldocs",
        verb: "intents",
        summary: "List pending actionable paper intents (oldest first).",
        http: %{method: "GET", path_template: "/v1/plugins/bulldocs/intents"},
        auth_tier: "ingest",
        args: [],
        flags: [],
        writes: false,
        batch: false,
        paginated: false,
        dry_run: false,
        default_output: "table",
        scoped_prefix: nil
      },
      %{
        id: "bulldocs.intent-processed",
        noun: "bulldocs",
        verb: "intent-processed",
        summary: "Mark a pending intent processed so it drops out of the queue.",
        http: %{method: "POST", path_template: "/v1/plugins/bulldocs/intents/:id/processed"},
        auth_tier: "ingest",
        args: [
          %{name: "id", required: true, type: "string", summary: "Intent (paper_event) id."}
        ],
        flags: [],
        writes: true,
        batch: false,
        paginated: false,
        dry_run: false,
        default_output: "minimal",
        scoped_prefix: nil
      }
    ]
  end

  @doc """
  Projects a paper document's internal references into the content graph
  (Goal ges/graph-edge-seam Phase 3).

  Implemented as the RESOLVER form directly (like Tasks) — the
  `@resolver_callbacks` entry is `{nil, nil, nil, :none}`, so only the resolver
  form is collected; the additive lift `prev ++ extract_edges(ctx.doc)` is
  supplied here.

  PURE — no `get_document`, no DB. Walks ONLY the doc payload's `content`,
  collecting internal references:

    * embed/sheet blocks carrying a `"ref"` (an internal doc id) → a
      `references` edge.
    * inline `PdLink` / `link` nodes whose `href` points at an internal
      `/papers/<slug>` → a `references` edge to `<slug>`.

  Emits `%{from_id: paper_pubid, to_id: linked_pubid, kind: "references",
  plugin_source: "bulldocs"}`. The core Projector pass resolves dangling.
  Guards a `nil` `ctx.doc` → returns `prev` unchanged.
  """
  @impl Barkpark.Plugin
  def resolve_extract_edges(prev, ctx) do
    case Map.get(ctx, :doc) do
      nil -> prev
      doc -> prev ++ extract_edges(doc, ctx)
    end
  end

  @impl Barkpark.Plugin
  def extract_edges(nil, _ctx), do: []

  def extract_edges(doc, _ctx) do
    doc_id = Map.get(doc, :doc_id) || Map.get(doc, "doc_id")
    content = Map.get(doc, :content) || Map.get(doc, "content") || %{}

    if is_binary(doc_id) do
      from_id = Barkpark.Content.published_id(doc_id)

      content
      |> collect_refs([])
      |> Enum.uniq()
      |> Enum.reject(fn ref -> ref == "" or ref == from_id end)
      |> Enum.map(fn ref ->
        %{
          from_id: from_id,
          to_id: ref,
          kind: "references",
          plugin_source: "bulldocs"
        }
      end)
    else
      []
    end
  end

  # Recursively walk the paper content, harvesting internal-reference targets.
  # Pure tree walk — no DB. Two signals:
  #   * a map with a "ref" string (embed/sheet block) → the ref doc id.
  #   * a map with an "href" string pointing at an internal "/papers/<slug>" →
  #     the <slug>. External (http...) and anchor (#...) hrefs are skipped.
  defp collect_refs(node, acc) when is_map(node) and not is_struct(node) do
    acc = ref_target(Map.get(node, "ref"), acc)
    acc = href_target(Map.get(node, "href"), acc)

    Enum.reduce(node, acc, fn {_k, v}, a -> collect_refs(v, a) end)
  end

  defp collect_refs(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &collect_refs/2)

  defp collect_refs(_other, acc), do: acc

  defp ref_target(ref, acc) when is_binary(ref) and ref != "",
    do: [Barkpark.Content.published_id(ref) | acc]

  defp ref_target(_ref, acc), do: acc

  defp href_target("/papers/" <> slug, acc) when slug != "" do
    [slug |> String.split(["?", "#"]) |> List.first() | acc]
  end

  defp href_target(_href, acc), do: acc
end
