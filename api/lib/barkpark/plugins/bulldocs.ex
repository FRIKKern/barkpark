defmodule Barkpark.Plugins.Bulldocs do
  @moduledoc """
  Bulldocs — the live, no-reload paper/document surface, as a first-party plugin.

  Bulldocs is the *producer* brand; a **paper** is what it produces. A producer
  POSTs block-structured papers to Bulldocs's ingest
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

  # Papers is core content — surfaced in the MAIN tier of the Desk Structure.
  @impl Barkpark.Plugin
  def structure_placement, do: :main

  alias Barkpark.Content.Papers.Hollow
  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.PortableDoc.BodyWalk

  # Resolved at RUNTIME, deliberately not frozen into an attribute.
  # `Application.app_dir/2` finds priv under BOTH deploy models: the source-tree
  # one (Barkpark compiles + runs in place under /opt/barkpark, where Mix
  # symlinks _build/<env>/lib/barkpark/priv at ./priv) and an OTP release, where
  # priv lives at lib/barkpark-<vsn>/priv. The previous
  # `Path.expand("../../../priv/...", __DIR__)` attribute served only the first:
  # it froze the BUILD machine's absolute path, so every released build raised
  # File.Error enoent here and this plugin's schemas never registered.
  # Precedent: the plugin loader already resolves priv this way — see
  # registry/discovery.ex default_paths/0.
  @schemas_subdir "priv/plugins/bulldocs/schemas"
  defp schemas_dir, do: Application.app_dir(:barkpark, @schemas_subdir)

  @doc """
  Declares the `paper` document type. The shape mirrors the legacy seed/
  migration row exactly (title "Papers", icon, public visibility, the four
  flat string fields), so re-upserts via Bootstrap never drift an existing
  row.
  """
  @impl Barkpark.Plugin
  def lifecycle_hooks do
    %{
      # In-list order is load-bearing and dispatcher-pinned (hooks_test.exs,
      # charter D7): the template shape gate first, the hollow-body quality
      # gate second. Hooks never mutate the payload, so the hollow gate always
      # sees the pristine write.
      before_save: [&validate_paper_template/1, &reject_hollow_published_save/1],
      before_publish: [&reject_hollow_paper_publish/1]
    }
  end

  # Doctrine gate (pdd-t3, paper portabledoc-doctrine): a paper that carries
  # template-locked blocks must keep the template shape — the locked title
  # heading at block 0, a featured block (when present) at block 1. Papers with
  # no locked blocks pass untouched (additive enforcement; corpus migration is
  # pdd-t5). The shape truth lives in Content.Papers.Template.validate/1; the
  # op-level backstop (remove/move/unlock of a locked block) in PortableDoc.Patch.
  defp validate_paper_template(%{doc: %{"type" => "paper"} = doc}) do
    blocks = get_in(doc, ["content", "blocks"])

    case Barkpark.Content.Papers.Template.validate(blocks) do
      [] -> :ok
      errors -> {:halt, "paper template violated: " <> Enum.join(errors, "; ")}
    end
  end

  defp validate_paper_template(_payload), do: :ok

  # Quality gate hook #2 (p-quality-gate): a PUBLISHED-surface paper write —
  # status "published", or a non-`drafts.` doc_id — whose body is hollow
  # (skeleton-only, `Barkpark.Content.Papers.Hollow`) is vetoed with the
  # ratified hard-stop copy. DRAFT writes stay free: mutate creates/patches
  # always land drafts (Writer draft-prefixes + coerces status), so gating
  # them would brick creation; a hollow draft is stopped at publish time by
  # the before_publish hook below. Today's Writer paths only emit draft
  # writes — this seam is the layer-parity backstop for any writer that ever
  # fires before_save with a published-surface payload.
  defp reject_hollow_published_save(%{doc: %{"type" => "paper"} = doc}) do
    if published_surface_write?(doc) and Hollow.hollow?(get_in(doc, ["content", "blocks"])) do
      {:halt, Hollow.message()}
    else
      :ok
    end
  end

  defp reject_hollow_published_save(_payload), do: :ok

  defp published_surface_write?(doc) do
    doc_id = doc["doc_id"] || doc["_id"]

    doc["status"] == "published" or
      (is_binary(doc_id) and not String.starts_with?(doc_id, "drafts."))
  end

  # Quality gate hook #3 (p-quality-gate): publishing a hollow draft paper —
  # the mutate `publish` op / proposals approve flow through
  # `Content.Lifecycle.publish_document` — is vetoed. The payload doc is the
  # DRAFT `%Document{}` being promoted (tests may fire plain maps; both
  # shapes are read). Non-papers and block-less (pre-doctrine) papers pass.
  defp reject_hollow_paper_publish(%{doc: doc}) when is_map(doc) do
    if paper_doc?(doc) and Hollow.hollow?(doc_blocks(doc)) do
      {:halt, Hollow.message()}
    else
      :ok
    end
  end

  defp reject_hollow_paper_publish(_payload), do: :ok

  defp paper_doc?(%{type: "paper"}), do: true
  defp paper_doc?(%{"type" => "paper"}), do: true
  defp paper_doc?(%{"_type" => "paper"}), do: true
  defp paper_doc?(_), do: false

  defp doc_blocks(doc) do
    case Map.get(doc, :content) || Map.get(doc, "content") do
      content when is_map(content) -> Map.get(content, "blocks")
      _ -> nil
    end
  end

  @impl Barkpark.Plugin
  # Reachability: the only path read is `schemas_dir()` joined with one of three
  # compile-time literal filenames — no runtime input reaches `File.read!/1`.
  # sobelow_skip ["Traversal.FileModule"]
  def register_schemas(_opts) do
    # paper (public reader artifact) + form_response (PRIVATE — anonymous form
    # submissions land here; visibility "private" keeps every response off the
    # public read API while bp/Studio token reads see them normally) +
    # session (session.json — ALSO PRIVATE, same reason as form_response: a
    # session record carries cwd, hostname, git branch/HEAD and a scrubbed
    # transcript ref, so it must never be anonymously readable. Sessions are
    # deliberately NOT in `AuthoringWall`'s `@walled_types`: they are
    # machine-generated lifecycle records, and being private already removes
    # the exposure the wall's curation exists to gate).
    for file <- ["paper.json", "form_response.json", "session.json"] do
      raw =
        schemas_dir()
        |> Path.join(file)
        |> File.read!()
        |> Jason.decode!()

      %SchemaDefinition{
        name: Map.fetch!(raw, "name"),
        title: Map.get(raw, "title"),
        icon: Map.get(raw, "icon"),
        # ALLOWLIST, not denylist. A schema is public only when its JSON
        # SAYS so — a dropped key, a typo, or a future visibility value fails
        # CLOSED. This matches the four sibling loaders (`onixedit.ex`,
        # `media.ex`, `sheets.ex`, `frt.ex`) and the ruling recorded at
        # `plugins/indx/indexer_worker.ex` `schema_public?/1`, so a nil or
        # unknown visibility cannot index in one place while 404ing in
        # another. Distinct from `%SchemaDefinition{}`'s own "public" default,
        # which is about DESK PLACEMENT (see schema_definition.ex, Gyldendal
        # #25) and is deliberately left alone.
        visibility: Map.get(raw, "visibility", "private"),
        fields: Map.get(raw, "fields", []),
        dataset: "production"
      }
    end
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
  ingest API gains the canonical plugin prefix `/v1/plugins/bulldocs/…`.

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
      {:get, "/papers/:slug/source", BarkparkWeb.BulldocsSourceController, :show,
       auth: :public_root},
      {:get, "/d/:dataset/papers/:slug/source", BarkparkWeb.BulldocsSourceController, :show,
       auth: :public_root},
      # The paper as the exact email byte stream — authors preview what a mail
      # backend would send (same :public_root visibility as the reader).
      {:get, "/papers/:slug/email", BarkparkWeb.BulldocsEmailController, :show,
       auth: :public_root},
      {:get, "/d/:dataset/papers/:slug/email", BarkparkWeb.BulldocsEmailController, :show,
       auth: :public_root},
      {:post, "/bulldocs/papers", BarkparkWeb.BulldocsIngestController, :ingest, auth: :ingest},
      # Validate-all dry-run (BPML masterplan W0): same body shapes as ingest,
      # every violation (BPML parse, wall gates, structure) in one reply,
      # nothing persisted. Registered BEFORE the :slug routes conceptually but
      # unambiguous either way — "validate" is a fixed segment, not a slug arg.
      {:post, "/bulldocs/papers/validate", BarkparkWeb.BulldocsIngestController, :validate,
       auth: :ingest},
      # Working-copy push (BPML masterplan W3): edited BPML + baseRev in,
      # server-derived op batch under if_rev, canonical BPML back.
      {:post, "/bulldocs/papers/:slug/sync", BarkparkWeb.BulldocsIngestController, :sync,
       auth: :ingest},
      {:post, "/bulldocs/papers/:slug/ops", BarkparkWeb.BulldocsIngestController, :apply_op,
       auth: :ingest},
      # Session-handoff (task-3): a `session` is a blocks-doc twin of a paper
      # (Content.blocks_type?/1 whitelist), same ingest token tier. GET is
      # `:ingest`-gated, and that gate is the ONLY reader: there is NO public
      # session reader route (the `/papers/:slug` reader below resolves
      # `type: "paper"` only), and the query API refuses the type anonymously
      # because session.json is `visibility: "private"`. Every read of a
      # session therefore costs a token.
      #
      # NOTE on the ops route: `apply_session_op` rides the GENERIC block-op
      # path, which patches the `drafts.<slug>` twin — NOT the published row
      # `show_session` reads. The op receipt names the written doc id and says
      # so; a `POST /bulldocs/sessions` upsert is what makes an edit visible.
      {:post, "/bulldocs/sessions", BarkparkWeb.BulldocsIngestController, :ingest_session,
       auth: :ingest},
      {:get, "/bulldocs/sessions/:slug", BarkparkWeb.BulldocsIngestController, :show_session,
       auth: :ingest},
      {:post, "/bulldocs/sessions/:slug/ops", BarkparkWeb.BulldocsIngestController,
       :apply_session_op, auth: :ingest},
      # Session-handoff (task-4): append-only server-stamped event trail
      # (`Barkpark.Content.Sessions.append_event/5`) — kinds whitelist,
      # advisory-lock + CAS-on-rev, never an update/delete.
      {:post, "/bulldocs/sessions/:slug/events", BarkparkWeb.BulldocsIngestController,
       :append_session_event, auth: :ingest},
      # session-conversations slice: registry of harness conversations that
      # touched this session (`Barkpark.Content.Sessions.touch_conversation/5`)
      # — same advisory-lock + CAS-on-rev posture as the events route above,
      # upsert-by-id rather than append-only.
      {:post, "/bulldocs/sessions/:slug/conversations", BarkparkWeb.BulldocsIngestController,
       :touch_session_conversation, auth: :ingest},
      # lvw-t4 — the AI-proposes loop: insert-only draft edits with provenance.
      {:post, "/bulldocs/papers/:slug/proposals", BarkparkWeb.BulldocsIngestController, :propose,
       auth: :ingest},
      {:get, "/bulldocs/intents", BarkparkWeb.BulldocsIntentsController, :index, auth: :ingest},
      {:post, "/bulldocs/intents/:id/processed", BarkparkWeb.BulldocsIntentsController,
       :mark_processed, auth: :ingest},
      # Anonymous form submissions (study play #5): the reader's form/
      # questionnaire blocks POST here. `:public_api` is the sanctioned
      # browser-reachable anonymous bucket (JSON, PublicCors, no session) —
      # abuse is held by the RateLimiter token bucket + honeypot inside the
      # controller, and the stored `form_response` schema is PRIVATE. The
      # `:options` sibling is the CORS-preflight contract for public_api POSTs.
      {:post, "/bulldocs/papers/:slug/form-responses", BarkparkWeb.BulldocsFormController,
       :submit, auth: :public_api},
      {:options, "/bulldocs/papers/:slug/form-responses", BarkparkWeb.BulldocsFormController,
       :submit, auth: :public_api}
    ]
  end

  @doc """
  Ergonomic CLI verbs Bulldocs contributes to the `/v1/capabilities` manifest
  (M3). Each command is grounded in a route that `register_routes/1` ABOVE
  actually mounts — `path_template` is the flat plugin path (the canonical
  `/v1/plugins/bulldocs/…` prefix). Every ingest route maps to `auth_tier: "ingest"`,
  the route's highway bucket.

  Six verbs over five routes:

    * `publish` — `POST /v1/plugins/bulldocs/papers` (the ingest endpoint;
      `blocks` or `body_html` payload from a file/stdin). WRITES, MINIMAL receipt.
    * `patch` — `POST /v1/plugins/bulldocs/papers/:slug/ops` (the batch ops
      endpoint). Accepts an `{ops:[…]}` BATCH body applied atomically; carries
      the optional `--if-rev` optimistic-concurrency guard (M3) the controller +
      `Content.apply_paper_block_ops/2` honour. WRITES, BATCH.
    * `propose` — `POST /v1/plugins/bulldocs/papers/:slug/proposals` (lvw-t4,
      the AI-proposes loop). An `{ops:[…], source:{doc_id, agent}}` body of
      INSERT-ONLY ops lands on the paper's `drafts.` twin with a mandatory
      `proposal-source` provenance edge — the published prose is never
      written; approval is the existing draft→publish gate. WRITES, BATCH.
    * `intents` — `GET /v1/plugins/bulldocs/intents` (pending actionable intents,
      oldest first). READ-shaped over the ingest pipeline.
    * `intent-processed` — `POST /v1/plugins/bulldocs/intents/:id/processed`
      (mark one intent drained). WRITES.

  No `get`/`ls` paper verb is declared: the paper reader at `/papers/:slug` is a
  LiveView (`:public_root`), not a JSON API route, so there is no honest flat
  `http.path_template` for it — declaring one would invent an endpoint.

  Task 6 (session-handoff) adds the `session` verb group — `bp session
  {open,log,publish,view,link-task}` — riding the session routes registered
  ABOVE (tasks 3-4) plus `POST /v1/tasks/:doc_id/sessions` (Tasks plugin,
  task 5). `session.open`/`publish`/`view` are `ingest`-tier over
  `/v1/plugins/bulldocs/sessions*`, same as the paper verbs; `session.log`
  is the ingest-tier event-append; `session.link-task` sits at `read`-tier
  (it rides the `/v1/tasks` bearer scope, not the ingest token) — so, unlike
  the paper verbs above, NOT every command in this list is ingest-tier.

  The session-conversations slice adds a sixth session verb, `session.touch`
  (`bp session touch <slug> --conversation … --harness … --account … --machine
  … --cwd …`) — ingest-tier, over the sibling
  `POST /v1/plugins/bulldocs/sessions/:slug/conversations` route registered
  ABOVE. It upserts-by-id into the session's harness-conversation registry
  (`Barkpark.Content.Sessions.touch_conversation/5`), server-stamping
  `first_seen`/`last_active` — never taken from the caller.
  """
  @impl Barkpark.Plugin
  def cli_commands do
    [
      %{
        id: "bulldocs.publish",
        noun: "bulldocs",
        verb: "publish",
        summary:
          "Publish (upsert) a paper from a portable-doc block payload. blocks[] is the door: " <>
            "56 renderer block types (chart, diagram, asciicast, diff, filetree, pipeline, …) " <>
            "with value-keyed inline leaves — items and cells are objects carrying a value key, " <>
            "never bare strings (a bare string publishes clean and renders blank). " <>
            "Guide: /papers/paper-authoring-excellence. " <>
            "body_html is a legacy last resort — hand-rolled HTML renders flat and loses tables " <>
            "in the terminal reader. " <>
            "Reader spacing law: empty paragraph blocks are editor scaffolds, not published " <>
            "layout — remove them from ingest payloads; shared reader tokens own section rhythm.",
        http: %{method: "POST", path_template: "/v1/plugins/bulldocs/papers"},
        auth_tier: "ingest",
        args: [
          %{name: "slug", required: true, type: "slug", summary: "Paper slug (its public id)."}
        ],
        flags: [
          %{
            name: "file",
            type: "file",
            summary:
              "Payload from a file or - for stdin: portable-doc blocks (preferred) " <>
                "or legacy body_html."
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
            summary:
              "Ops payload {\"ops\":[…]} from a file or - for stdin. Each op is " <>
                "{\"op\": <verb>, …}; the accepted verbs are append-block, insert-after, " <>
                "patch-block, replace-block, remove-block and move-block. append-block " <>
                "takes \"block\"; insert-after takes \"afterId\" + \"block\"; patch-block " <>
                "and replace-block take \"id\" (+ \"patch\" / \"block\"); remove-block and " <>
                "move-block take \"id\". An unrecognised verb refuses the WHOLE batch — " <>
                "the apply is atomic, so nothing is written."
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
        id: "bulldocs.propose",
        noun: "bulldocs",
        verb: "propose",
        summary:
          "Propose insert-only draft paper edits with provenance (approve via the publish gate).",
        http: %{method: "POST", path_template: "/v1/plugins/bulldocs/papers/:slug/proposals"},
        auth_tier: "ingest",
        args: [
          %{name: "slug", required: true, type: "slug", summary: "Paper slug to propose into."}
        ],
        flags: [
          %{
            name: "file",
            type: "file",
            summary:
              "Proposal payload {\"ops\":[…],\"source\":{\"doc_id\":…,\"agent\":…}} " <>
                "from a file or - for stdin."
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
      },
      %{
        id: "session.open",
        noun: "session",
        verb: "open",
        summary:
          "Open a living session document at session start (status: open, metadata seeded).",
        http: %{method: "POST", path_template: "/v1/plugins/bulldocs/sessions"},
        auth_tier: "ingest",
        args: [
          %{
            name: "slug",
            required: true,
            type: "slug",
            summary: "Session slug (session-YYYY-MM-DD-<topic>)."
          }
        ],
        flags: [
          %{
            name: "file",
            type: "file",
            summary: "Metadata payload (fields, tags, description; blocks optional)."
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
        id: "session.log",
        noun: "session",
        verb: "log",
        summary: "Append one milestone event to an open session (server stamps ts).",
        http: %{method: "POST", path_template: "/v1/plugins/bulldocs/sessions/:slug/events"},
        auth_tier: "ingest",
        args: [
          %{name: "slug", required: true, type: "slug", summary: "Session slug."}
        ],
        flags: [
          %{
            name: "kind",
            type: "string",
            summary:
              "Event kind: paper-published | task-closed | epic-wave-complete | push | note."
          },
          %{
            name: "ref",
            type: "string",
            summary: "Related doc id (task id, paper slug, commit SHA)."
          },
          %{name: "note", type: "string", summary: "Short free-text note."},
          %{
            name: "conversation",
            type: "string",
            summary: "Conversation that logged this event (provenance)."
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
        id: "session.publish",
        noun: "session",
        verb: "publish",
        summary: "Upsert session synthesis blocks + metadata (checkpoint or close).",
        http: %{method: "POST", path_template: "/v1/plugins/bulldocs/sessions"},
        auth_tier: "ingest",
        args: [
          %{name: "slug", required: true, type: "slug", summary: "Session slug."}
        ],
        flags: [
          %{
            name: "file",
            type: "file",
            summary: "Payload: blocks + fields (status: closed on final close)."
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
        id: "session.view",
        noun: "session",
        verb: "view",
        summary: "Read a session back: metadata + event trail + synthesis blocks.",
        http: %{method: "GET", path_template: "/v1/plugins/bulldocs/sessions/:slug"},
        auth_tier: "ingest",
        args: [
          %{name: "slug", required: true, type: "slug", summary: "Session slug."}
        ],
        flags: [],
        writes: false,
        batch: false,
        paginated: false,
        dry_run: false,
        default_output: "json",
        scoped_prefix: nil
      },
      %{
        id: "session.link-task",
        noun: "session",
        verb: "link-task",
        summary:
          "Stamp a task with the session it was worked in (appends to the task's sessions[]).",
        http: %{method: "POST", path_template: "/v1/tasks/:doc_id/sessions"},
        auth_tier: "read",
        args: [
          %{name: "doc_id", required: true, type: "string", summary: "Task doc id."}
        ],
        flags: [
          %{name: "add", type: "string", summary: "Session slug to add."}
        ],
        writes: true,
        batch: false,
        paginated: false,
        dry_run: false,
        default_output: "minimal",
        scoped_prefix: nil
      },
      %{
        id: "session.touch",
        noun: "session",
        verb: "touch",
        summary:
          "Register or refresh a harness conversation on a session (server stamps first_seen/last_active).",
        http: %{
          method: "POST",
          path_template: "/v1/plugins/bulldocs/sessions/:slug/conversations"
        },
        auth_tier: "ingest",
        args: [
          %{name: "slug", required: true, type: "slug", summary: "Session slug."}
        ],
        flags: [
          %{
            name: "conversation",
            type: "string",
            summary: "Harness-native conversation/session uuid."
          },
          %{name: "harness", type: "string", summary: "claude-code | codex | other."},
          %{
            name: "account",
            type: "string",
            summary: "Account holding the conversation (email or best-effort id)."
          },
          %{name: "machine", type: "string", summary: "Hostname."},
          %{name: "cwd", type: "string", summary: "Working directory."}
        ],
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
  (Goal ges/graph-edge-seam Phase 3; body-walk extractor per the wire
  contract's §7 — `portabledoc-inline-liveref-taskchip-wire`).

  Implemented as the RESOLVER form directly (like Tasks) — the
  `@resolver_callbacks` entry is `{nil, nil, nil, :none}`, so only the resolver
  form is collected; the additive lift `prev ++ extract_edges(ctx.doc)` is
  supplied here.

  PURE — no `get_document`, no DB. Walks ONLY the doc payload's `content` (via
  the ONE shared `Barkpark.PortableDoc.BodyWalk` walker), collecting internal
  references:

    * embed/sheet blocks carrying a `"ref"` (an internal doc id) → a
      `references` edge.
    * any node whose `href` points at an internal paper → a `references` edge
      to `<slug>`. BOTH shapes count: the root-relative `/papers/<slug>` the
      picker writes, and the absolute `https://<own-host>/papers/<slug>` an
      author pastes from the browser (the `action`/bp-button block keeps the
      URL verbatim). A url on ANY OTHER host mints nothing.
    * inline `wikilink` nodes → a `references` edge to the picker-stamped
      `"docId"`/`"doc_id"` when present, else the raw `"target"`. This is the
      wire §7 "wikilink resolving to a task → `references`" row: a task chip is
      a plain wikilink whose `docId` IS the task doc id. Task-ness is NOT
      checked here (this callback is pure); the WRITE path decides — an edge
      only materialises when `Content.add_edges/2` resolves the endpoint in
      scope, so a title-targeted wikilink that matches no `doc_id` simply
      drops (`{:error, :no_target}`), exactly like a dangling `"ref"`.
    * inline `valueref` nodes → a `valueref`-kind edge to the node's `"target"`
      (a canonical doc_id slug, D3). The edge kind is spelled IDENTICALLY to
      the node type — `valueref`, never `value-ref`.
    * `content["proposals"]` sidecar entries (lvw-t4 — the AI-proposes loop)
      → a `proposal-source` edge to each entry's `"source"` doc. This is how a
      proposal's provenance SURVIVES the publish gate: the draft row's direct
      edge cascade-deletes when publish removes the draft, but the sidecar is
      copied onto the published row, and this clause re-materializes the edge
      there — rebuild-stable, since every projector rebuild re-extracts it.

  Emits `%{from_id: paper_pubid, to_id: linked_pubid, kind:
  "references" | "valueref" | "proposal-source", plugin_source: "bulldocs"}`.
  The core Projector pass resolves dangling. Guards a `nil` `ctx.doc` →
  returns `prev` unchanged.

  These plugin-projected edges feed BOTH graph surfaces: the PUBLISHED
  materialised graph (projector corpus `perspective: :published`) AND — since
  the lvw-t12 fold — the live drafts traverse, whose `build_drafts_index`
  folds `Registry.collect_edge_extractors/1` over the drafts corpus, so a
  draft paper's valueref/wikilink/ref edges surface pre-publish (dangling
  there is resolved against the scoped drafts corpus, see
  `Content.Graph.drafts_edges_for_doc/3`).
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

      (collect_edge_targets(content) ++ proposal_source_targets(content))
      |> Enum.uniq()
      |> Enum.reject(fn {to, _kind} -> to == "" or to == from_id end)
      |> Enum.map(fn {to, kind} ->
        %{
          from_id: from_id,
          to_id: to,
          kind: kind,
          plugin_source: "bulldocs"
        }
      end)
    else
      []
    end
  end

  # ONE pass of the shared BodyWalk walker over the paper content, harvesting
  # every internal-reference target as a `{to_id, kind}` pair. Pure — no DB.
  # Four signals per node:
  #   * a "ref" string (embed/sheet block)            → {pubid(ref), "references"}
  #   * an "href" naming an internal paper → {slug, "references"} — either the
  #     root-relative "/papers/<slug>" or an absolute url on THIS instance's own
  #     public host (foreign-host and anchor #… hrefs are skipped)
  #   * a "type":"wikilink" node                      → {pubid(docId || target), "references"}
  #   * a "type":"valueref" node                      → {pubid(target), "valueref"}
  defp collect_edge_targets(content) do
    BodyWalk.collect(content, fn node ->
      ref_target(Map.get(node, "ref")) ++
        href_target(Map.get(node, "href")) ++
        inline_node_target(node)
    end)
  end

  defp ref_target(ref) when is_binary(ref) and ref != "",
    do: [{Barkpark.Content.published_id(ref), "references"}]

  defp ref_target(_ref), do: []

  defp href_target(href) when is_binary(href) do
    case internal_paper_path(href) do
      "/papers/" <> slug when slug != "" ->
        [{slug |> String.split(["?", "#"]) |> List.first(), "references"}]

      _ ->
        []
    end
  end

  defp href_target(_href), do: []

  # An internal paper link reaches us in TWO shapes. The root-relative
  # "/papers/<slug>" is what the picker writes. The ABSOLUTE
  # "https://<own-host>/papers/<slug>" is what an author pastes after copying a
  # paper's address out of the browser — the action/bp-button block stores the
  # URL verbatim — and until this clause existed it fell to the catch-all, so
  # ~7% of the paper→paper citation channel minted no `references` edge and the
  # linked paper reported zero backlinks.
  #
  # Only THIS instance's own public host is unwrapped: a url naming another
  # Barkpark would otherwise mint a LOCAL edge to whatever local paper happens
  # to share that slug. "Own host" is the endpoint's configured public host
  # (`BarkparkWeb.Endpoint.url()` — PHX_HOST at runtime), the same source
  # `BarkparkWeb.SessionController.instance_host/0` and `Barkpark.SSO.SAML` use;
  # no new env var.
  #
  # The comparison is HOST ONLY, case-insensitive — scheme and port are
  # deliberately ignored:
  #
  #   * the public scheme need not equal PHX_SCHEME. Prod fronts the app with a
  #     TLS terminator while the app itself is configured http (Golden Rule #5
  #     keeps force_ssl off), so the browser shows https:// on a box whose
  #     endpoint says http — matching on scheme would drop exactly the links
  #     this fixes.
  #   * the public port need not equal the url port. `url_port` is the
  #     scheme-standard 80/443 unless PHX_PORT overrides, while the proxy and
  #     the blue/green pair listen on 4000/4001; an author's pasted url may
  #     carry an explicit port or none.
  #
  # A url is therefore accepted with or without an explicit port and under
  # either scheme, and protocol-relative "//<own-host>/papers/<slug>" too.
  # Note this is a HOST check, not a prefix check: userinfo smuggling
  # ("https://own-host@evil.example/papers/x") parses to host "evil.example"
  # and is correctly refused.
  defp internal_paper_path("/papers/" <> _ = path), do: path

  defp internal_paper_path(href) do
    case URI.parse(href) do
      %URI{host: host, path: path} when is_binary(host) and is_binary(path) ->
        if own_public_host?(host), do: path, else: nil

      _ ->
        nil
    end
  end

  defp own_public_host?(host) do
    case URI.parse(BarkparkWeb.Endpoint.url()) do
      %URI{host: own} when is_binary(own) and own != "" ->
        String.downcase(host) == String.downcase(own)

      _ ->
        false
    end
  end

  # The wikilink's edge target prefers the picker-stamped doc id (camelCase
  # "docId" on the wire; "doc_id" also accepted — mirroring the render-side
  # precedence in PortableDoc.Render.Inline) over the human-titled "target".
  defp inline_node_target(%{"type" => "wikilink"} = node) do
    case first_present([Map.get(node, "docId"), Map.get(node, "doc_id"), Map.get(node, "target")]) do
      nil -> []
      to -> [{Barkpark.Content.published_id(to), "references"}]
    end
  end

  defp inline_node_target(%{"type" => "valueref", "target" => target})
       when is_binary(target) and target != "" do
    [{Barkpark.Content.published_id(target), "valueref"}]
  end

  defp inline_node_target(_node), do: []

  # lvw-t4 — provenance targets from the `content["proposals"]` sidecar
  # (`%{block_id => %{"source" => doc_id, "agent" => …, …}}`, written by
  # `Barkpark.Content.Papers.Proposals`). Emits one `proposal-source` pair per
  # distinct source doc, so the published paper keeps a provenance edge for
  # every approved machine assertion. Not a BodyWalk signal: the sidecar hangs
  # off `content`, not the block list.
  defp proposal_source_targets(%{"proposals" => proposals}) when is_map(proposals) do
    proposals
    |> Map.values()
    |> Enum.flat_map(fn
      %{"source" => source} when is_binary(source) and source != "" ->
        [{Barkpark.Content.published_id(source), "proposal-source"}]

      _ ->
        []
    end)
  end

  defp proposal_source_targets(_content), do: []

  defp first_present(values) do
    Enum.find(values, fn v -> is_binary(v) and v != "" end)
  end
end
