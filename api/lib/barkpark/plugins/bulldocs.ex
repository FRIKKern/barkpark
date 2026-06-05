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
      {:post, "/bulldocs/papers", BarkparkWeb.BulldocsIngestController, :ingest, auth: :ingest},
      {:post, "/bulldocs/papers/:slug/ops", BarkparkWeb.BulldocsIngestController, :apply_op,
       auth: :ingest},
      {:get, "/bulldocs/intents", BarkparkWeb.BulldocsIntentsController, :index, auth: :ingest},
      {:post, "/bulldocs/intents/:id/processed", BarkparkWeb.BulldocsIntentsController,
       :mark_processed, auth: :ingest}
    ]
  end
end
