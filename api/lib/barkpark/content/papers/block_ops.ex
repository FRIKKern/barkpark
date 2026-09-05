defmodule Barkpark.Content.Papers.BlockOps do
  @moduledoc """
  Papers — the block-ops / write path, extracted from `Barkpark.Content.Papers`
  (Modularity decomposition: `papers.ex` was a god-module).

  This module owns the five public write functions and their private helpers:

    * `upsert_blocks_doc/3` — whole-doc upsert + whole-HTML broadcast for any
      type in the closed `["paper", "session"]` whitelist, walled by default
      (charter D26 — see the function doc). `upsert_paper/2` is now a thin
      `upsert_blocks_doc("paper", attrs, opts)` wrapper (session-handoff
      Task 2 — the "generalized upsert" off the hardcoded `"paper"` type).
    * `apply_paper_block_op/4` — single portable-doc op + delta broadcast.
    * `apply_paper_block_ops/4` — atomic batch of ops + one delta broadcast.
    * `apply_document_block_op/5` — generalized block-op for any
      Expectation-bearing document (the Beta block editor's write path).

  `Barkpark.Content.Papers` keeps its public API byte-identical by delegating
  these functions here. The read-side helpers (`get_paper/3`, `get_blocks_doc/4`,
  `resolve_blocks_for_edit/3`) stay in `Papers`; this module calls back to them.
  The extraction preserves the former public API. HTML-only papers additionally
  fail closed on BlockOps until an explicit revision-fenced conversion exists.
  """

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Repo
  alias Barkpark.Content

  alias Barkpark.Content.{
    AuthoringWall,
    Broadcast,
    Document,
    DraftId,
    Encryption,
    Labels,
    Sheets,
    Writer
  }

  alias Barkpark.Content.Papers
  alias Barkpark.Content.Papers.Hollow
  alias Barkpark.PortableDoc.{FieldVocabulary, HtmlSanitizer, Patch, Projection, Render, Slots}
  alias Barkpark.Preview
  alias Barkpark.Repo.IdempotencyStore

  @paper_type "paper"
  @paper_default_dataset "production"
  @html_conversion_message "HTML-only papers are read-only until an explicit revision-fenced conversion preserves the authored HTML preimage."

  # The closed blocks-type whitelist — the SOLE copy (compile-time module
  # attribute, required so `upsert_blocks_doc/3`'s guard clause can pattern
  # against it). `Barkpark.Content.Papers.blocks_types/0` /
  # `Barkpark.Content.blocks_types/0` both delegate here rather than keeping
  # an independent literal, so there is exactly one place to widen the list.
  @blocks_types ["paper", "session"]

  @doc "The closed whitelist of document types that ride the blocks-doc write path."
  def blocks_types, do: @blocks_types

  @doc "Whether `type` is in the blocks-doc whitelist (`blocks_types/0`)."
  def blocks_type?(type), do: type in @blocks_types

  @doc """
  Upsert a blocks-doc keyed by `{dataset, slug}` — `type` must be in the
  closed whitelist `["paper", "session"]` (`Content.blocks_types/0`), else
  `{:error, :not_a_blocks_type}`. Generalized off the original paper-only
  `upsert_paper/2` (session-handoff Task 2); `upsert_paper/2` below is now a
  thin `upsert_blocks_doc("paper", attrs, opts)` wrapper, byte-identical to
  its pre-generalization behavior.

  `attrs` accepts string or atom keys: `slug` (required), and either
  `body_html` OR `blocks` (a "paper" write only — "session" and any future
  non-paper type always normalizes a missing `blocks` to `[]`, no HTML-only
  leg). When `blocks` is given, `body_html` is (re)rendered from it as the
  derived cache. Optionally `dataset`, `source_doc`, `goal_id`, `event_type`,
  and the label spine's `tags` (weighted `[{tag, strength, rationale}]`) +
  `description` — persisted into a PAPER's content so the wall and search
  read them (this fixed allowlist stays paper-only). A non-paper type instead
  merges every OTHER caller-supplied attr straight into content as metadata
  (a session's `status`, `harness`, `session_uuid`, … land as-is). The
  monotonic integer streaming rev (`content["rev"]`) is bumped on every
  write.

  ## The publish wall (authoring-excellence D26)

  This path births PUBLISHED rows via direct Repo writes, so it mounts the
  SAME `Barkpark.Content.AuthoringWall` chain `Lifecycle.publish_document/4`
  runs — on a synthesized in-memory ref, BEFORE the row write. Enforcement is
  ON by default; wall rejections surface RAW (`{:error, {:label_spine, d}}`,
  `{:error, {:unknown_tag, p}}`, `{:error, {:duplicate_of, p}}` — never
  flattened into the plugin `{:halted, _}` shape). Pre-wall papers
  grandfather via the `(slug, dataset)` exemption ledger exactly like
  Lifecycle publishes; fresh papers are never exempt (D6). The wall's own
  `@walled_types` (`~w(paper task)`) scopes label-spine/dedup enforcement — a
  "session" write passes both as a no-op, the same posture any other
  non-walled content type gets.

  `opts`:

    * `:bypass_wall` — `true` skips the wall (AND its main_tag stamp) for an
      AUDITED internal projection that cannot retry (charter D23-b/D26). Every
      bypass call site carries a one-line rationale comment — the grep-able
      ledger of exceptions. Default `false`.

  On success, broadcasts `{:paper_updated, %{slug, dataset, html, rev, …}}` to
  `paper_topic(slug, dataset)` and returns `{:ok, %Document{}}`. Returns
  `{:error, changeset}` on validation/constraint failure.
  """
  def upsert_blocks_doc(type, attrs, opts \\ [])

  def upsert_blocks_doc(type, _attrs, _opts) when type not in @blocks_types,
    do: {:error, :not_a_blocks_type}

  # PAPER leg — unchanged, unlocked, byte-identical to the pre-fix path.
  def upsert_blocks_doc(@paper_type, attrs, opts) when is_map(attrs) and is_list(opts),
    do: do_upsert_blocks_doc(@paper_type, attrs, opts)

  # NON-PAPER leg (today: "session") — SERIALIZED against the OTHER writer of
  # the same row, `Barkpark.Content.Sessions.append_event/5`.
  #
  # The race this closes: `do_upsert_blocks_doc/3` reads `existing` (its
  # pre-write lookup), then builds `content` from `existing.content` as
  # `base_content` and finally persists it. A session's `content["events"]`
  # trail is never sent by an upsert caller ("events" is in
  # `@blocks_doc_reserved_attrs`) — it survives ONLY by riding that
  # `base_content` carry-over. So an `append_event/5` that COMMITS between the
  # read and the write is silently overwritten: the checkpoint publishes and
  # the just-logged milestone vanishes from the trail.
  #
  # `append_event/5` already serializes on `pg_advisory_xact_lock(hashtext(
  # "session:" <> slug))`. Taking the SAME key here, and doing the `existing`
  # read INSIDE that transaction, makes the two writers mutually exclusive: an
  # append either lands before this upsert's read (and is carried over) or
  # waits behind its commit (and appends to the freshly-written content).
  # `pg_advisory_xact_lock` is released at commit/rollback — no unlock path to
  # leak. A slug-less write (no row to race on) skips the lock entirely.
  def upsert_blocks_doc(type, attrs, opts) when is_map(attrs) and is_list(opts) do
    case attrs["slug"] || attrs[:slug] do
      slug when is_binary(slug) and slug != "" ->
        Repo.transaction(fn ->
          _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["#{type}:#{slug}"])
          do_upsert_blocks_doc(type, attrs, opts)
        end)
        |> case do
          # The inner result IS the return value — errors are NOT rolled back
          # because every failure leg returns before (or IS) the single Repo
          # write, so there is nothing partial to undo, and rolling back would
          # rewrite `{:error, reason}` into `{:error, reason}` via a different
          # code path for no gain.
          {:ok, inner} -> inner
          {:error, reason} -> {:error, reason}
        end

      _ ->
        do_upsert_blocks_doc(type, attrs, opts)
    end
  end

  defp do_upsert_blocks_doc(type, attrs, opts) do
    attrs = normalize_paper_attrs(attrs)
    slug = attrs["slug"]
    dataset = attrs["dataset"] || @paper_default_dataset

    # The pre-write lookup MUST be scoped to THIS write's tenant, not unscoped.
    # An unscoped `get_paper(slug, dataset)` resolves the slug across EVERY
    # workspace (slugs are per-workspace), so a same-slug write in workspace B
    # would find workspace A's row and UPDATE it — re-stamping A's row with B's
    # scope and hijacking A's paper. Scoping the lookup to the write's resolved
    # workspace keeps the two papers DISTINCT, matching the per-workspace
    # uniqueness the Wave-2 index flip established (barkpark-w9dg). The scope is
    # the explicit one in attrs, else the seeded Default — identical to the
    # write-stamp fallback below, so the lookup sees exactly the row the write
    # would update.
    existing = slug && get_existing_blocks_doc_for_write(type, slug, dataset, attrs)

    # Tenancy scope for the row stamp, resolved BEFORE the content build so
    # the sheet-embed hydration below can fetch same-scope sheets (M0a). Same
    # contract as the stamp it feeds (W1.5-C, below): an explicit caller
    # scope ALWAYS wins; a brand-new row falls back to the seeded Default; an
    # UPDATE without an explicit scope resolves to `%{}` (nothing stamped, the
    # existing row's scope preserved) and hydration scopes by the existing row.
    scope_opts = paper_scope_opts(attrs)

    # Fail-closed scope stamp (felix-w26): put_scope_attrs now returns
    # {:ok, attrs} | {:error, reason} — a refused dataset resolution surfaces
    # as the error (this fn is already error-shaped for every caller), never a
    # silent dataset_id=NULL stamp. The UPDATE-without-explicit-scope arm
    # stamps nothing, exactly as before.
    scope_attrs_result =
      cond do
        scope_opts != [] ->
          stamped_scope_attrs(dataset, scope_opts)

        existing ->
          {:ok, %{}}

        true ->
          stamped_scope_attrs(dataset, [])
      end

    with {:ok, scope_attrs} <- scope_attrs_result do
      upsert_blocks_doc_stamped(type, attrs, opts, dataset, slug, existing, scope_attrs)
    end
  end

  # Stamp a one-key attrs map to harvest ONLY the resolved scope ids — the
  # "dataset" key is the resolver's input, not part of the stamp.
  defp stamped_scope_attrs(dataset, scope_opts) do
    with {:ok, stamped} <- Content.put_scope_attrs(%{"dataset" => dataset}, scope_opts) do
      {:ok, Map.delete(stamped, "dataset")}
    end
  end

  # The post-stamp tail of do_upsert_blocks_doc/3 — body unchanged, split out
  # so the fail-closed scope stamp above can error before any content build.
  defp upsert_blocks_doc_stamped(type, attrs, opts, dataset, slug, existing, scope_attrs) do
    embed_scope =
      if scope_attrs == %{} and existing do
        %{
          "dataset" => dataset,
          "dataset_id" => existing.dataset_id,
          "workspace_id" => existing.workspace_id
        }
      else
        Map.put(scope_attrs, "dataset", dataset)
      end

    # R2 fix (Option A): assign a stable per-block id at INGEST so every block
    # has a UNIQUE "id" before storage/render. Id-less blocks otherwise all
    # collapse to the same LiveView stream/DOM id (`blocks-`), so Phoenix's
    # stream dedupes them and only the LAST block renders in the live <article>.
    # `ensure_block_ids/1` ONLY fills a missing/blank id (positional `block-N`,
    # recursing into sections) — it NEVER overwrites an author/op-supplied id, so
    # DocPatchOp block-addressing (ops target blocks by id) stays stable across
    # ops and re-ingests of the same structure.
    #
    # M0a: hydrate `"sheet"` block snapshots from their referenced sheets at
    # ingest, BEFORE the body_html render below — a paper embedding an
    # EXISTING sheet shows its values on the first read.
    #
    # A non-paper type (session, …) carries no legacy HTML-only leg, so a
    # missing "blocks" key on a BRAND-NEW doc is metadata-only content, not an
    # opaque body_html write — it defaults to `[]` and rides the SAME
    # normalization pipeline every paper block list gets. But that default
    # must NOT fire on an UPDATE: a metadata-only upsert against an EXISTING
    # session (e.g. a bare status change) supplies no "blocks" key meaning
    # "leave the blocks alone", not "wipe them to []" — defaulting
    # unconditionally would re-render body_html to "" and blank the stored
    # blocks on every metadata-only save. So the `[]` default is scoped to
    # `existing == nil` only; on an update the missing key stays `nil` and
    # falls through to the `other -> other` branch below, whose carry-over
    # legs (see `write_encrypted_blocks_doc/8`) preserve the existing
    # blocks/body_html byte-for-byte. Papers keep the historical `nil`
    # passthrough unconditionally (their `other -> other` branch is the
    # legacy HTML-only leg, not a session-style carry-over).
    raw_blocks =
      if type != @paper_type and existing == nil,
        do: attrs["blocks"] || [],
        else: attrs["blocks"]

    blocks =
      case raw_blocks do
        list when is_list(list) ->
          # Same chokepoint, two normalizers: `ensure_block_ids` fills id-less
          # blocks; `normalize_list_items` coerces legacy flat-STRING list items
          # to the canonical inline-array shape (the obsidian list-item-crash fix)
          # so the canvas's reconstructed shape matches what is stored (no spurious
          # shape-flip patch on load). Both are additive + idempotent + recurse
          # into sections; both are render-preserving.
          list
          |> maybe_seed_template(type, existing, attrs)
          |> ensure_block_ids()
          |> normalize_render_shapes()
          |> Sheets.hydrate_sheet_blocks(embed_scope, slug)

        other ->
          other
      end

    # Doctrine (pdd-t4): the row title IS the locked title block's text — one
    # truth. Additive: papers with no role:"title" block keep their given title.
    attrs =
      attrs
      |> Papers.Template.derive_title(blocks)
      |> Papers.Template.stamp_article_style(blocks)

    # Field-encryption CHOKEPOINT (Phase 2). Encrypt bound block values for any
    # schema field marked `encrypted: true` BEFORE they are rendered into the
    # body_html cache / projected into content[fieldName] / persisted — so the
    # paper write path stores ciphertext-at-rest exactly like Writer does. Run
    # here (pre-render) rather than only pre-changeset so the rendered body_html
    # (a stored + broadcast surface) redacts the encrypted field instead of
    # leaking plaintext. Projection then copies the envelope into
    # content[fieldName]. Byte-identical no-op when the "paper" schema marks
    # nothing encrypted (or this is an HTML-only, block-less write); fail closed
    # (HIGH-3) when a marked block cannot be sealed — REJECT, never persist.
    # Doctrine gate (pdd-t3) — the DIRECT paper write path bypasses plugin
    # lifecycle hooks (this writes via Repo, not Content.mutations), so the
    # template shape is enforced here too; the Bulldocs before_save hook covers
    # the mutate path. Same halt shape as a plugin veto so every caller
    # (Studio, ingest, bp) renders it identically.
    # Quality gate (p-quality-gate): a hollow RESULT — nothing beyond the
    # enforced title/featured skeleton — is refused, always. Papers publish
    # in place through this path (ingest/chat/mutate stubs; Studio never
    # calls it), so there is no birth exemption: a machine POSTing a
    # title-only stub gets the honest hard stop instead of a hollow
    # published paper. HTML-only writes (no blocks list) stay exempt.
    with [] <- template_declaration_errors(type, blocks),
         :ok <- validate_render_shapes_for_type(type, blocks),
         :ok <- maybe_reject_hollow_result(type, blocks),
         :ok <- reject_new_field_loss(existing_paper_blocks(existing), blocks),
         {:ok, blocks} <-
           encrypt_blocks_for_type(
             type,
             blocks,
             dataset,
             scope_attrs["workspace_id"] || (existing && existing.workspace_id)
           ) do
      write_encrypted_blocks_doc(type, blocks, attrs, existing, dataset, slug, scope_attrs, opts)
    else
      errors when is_list(errors) ->
        {:error, {:halted, "paper template violated: " <> Enum.join(errors, "; ")}}

      other ->
        other
    end
  end

  @doc "The paper-only entry point — `upsert_blocks_doc(\"paper\", attrs, opts)`. See its @doc above."
  def upsert_paper(attrs, opts \\ []), do: upsert_blocks_doc(@paper_type, attrs, opts)

  # Paper-only: the locked title-heading template is a paper doctrine concern
  # (D11/pdd-t4), not a generic blocks-doc one. Sessions (and any future
  # non-paper blocks type) keep their caller-supplied block list byte-for-byte
  # — no auto-seeded skeleton.
  defp maybe_seed_template(list, @paper_type, existing, attrs),
    do: Papers.Template.maybe_seed(list, existing, attrs)

  defp maybe_seed_template(list, _type, _existing, _attrs), do: list

  # Paper-only: `Papers.Template.paper_declarations()` (title/featured/ingress)
  # is the paper doctrine's structural vocabulary — irrelevant to a session's
  # blocks. Additive for non-paper types: no declarations, no errors.
  defp template_declaration_errors(@paper_type, blocks), do: Papers.Template.validate(blocks)
  defp template_declaration_errors(_type, _blocks), do: []

  defp validate_render_shapes_for_type(@paper_type, blocks) when is_list(blocks),
    do: validate_render_shapes(blocks)

  defp validate_render_shapes_for_type(_type, _blocks), do: :ok

  # Paper-only: the hollow-result quality gate (p-quality-gate, D3) enforces
  # the PAPER doctrine's "title but no content" copy — not a generic
  # metadata-bearing blocks-doc concern. A metadata-only session (no body
  # blocks) is a legitimate write, not a hollow paper.
  defp maybe_reject_hollow_result(@paper_type, blocks), do: reject_hollow_result(blocks)
  defp maybe_reject_hollow_result(_type, _blocks), do: :ok

  # The persistence tail of upsert_blocks_doc/3, reached ONLY once bound blocks
  # are sealed (or there was nothing to seal). Split out so the encryption
  # chokepoint can fail closed without re-indenting the whole builder.
  defp write_encrypted_blocks_doc(type, blocks, attrs, existing, dataset, slug, scope_attrs, opts) do
    # Per-doc article marker. An ingest/POST may set `style: "article"` in
    # attrs; otherwise it sticks at whatever the existing doc already carries
    # (so a partial update never silently demotes an article paper). Threaded
    # into render_opts so the body_html cache is rendered in the article palette.
    style = Labels.paper_style(attrs, existing)

    render_opts =
      Labels.paper_render_opts(dataset, style, paper_scope(existing, scope_attrs))

    body_html =
      cond do
        is_list(blocks) -> Render.render_blocks(blocks, render_opts)
        # Legacy HTML-only leg: an external producer supplied opaque body_html
        # with no blocks. Scrub it through the strict allowlist BEFORE store so
        # a <script>/onerror= payload never persists (defensive; the reader CSP
        # is the second layer). See Barkpark.PortableDoc.HtmlSanitizer.
        is_binary(attrs["body_html"]) -> HtmlSanitizer.sanitize(attrs["body_html"])
        true -> (existing && get_in(existing.content || %{}, ["body_html"])) || ""
      end

    next_rev = paper_next_rev(existing)

    base_content = (existing && existing.content) || %{}

    # Stamp the render version ONLY when body_html was freshly rendered from
    # blocks. The other two legs are NOT interchangeable, so they do not share
    # an `else`:
    #
    #   verbatim  — the caller supplied opaque body_html that no renderer of
    #     ours produced. A "body_html_sv" carried over from an earlier rendered
    #     write now describes bytes it never rendered: a stamp that LIES. Delete
    #     it. NEVER a sentinel value — a sentinel is by construction != the
    #     current version, so any reader applying "stamp != digest => drift"
    #     routes it into the OVERWRITE branch and discards the caller's HTML.
    #     Absent is the legacy class readers already fail closed on.
    #
    #   carry-over — a metadata-only update rewrites the EXISTING body_html
    #     byte-for-byte, so an existing stamp still describes exactly those
    #     bytes and stays TRUE. Deleting here would demote a coherent paper into
    #     the fail-closed unknown class and manufacture false 422s.
    content =
      cond do
        is_list(blocks) ->
          put_body_html(base_content, body_html)

        is_binary(attrs["body_html"]) ->
          base_content
          |> Map.put("body_html", body_html)
          |> Map.delete("body_html_sv")

        true ->
          Map.put(base_content, "body_html", body_html)
      end
      |> maybe_put_paper("blocks", if(is_list(blocks), do: blocks))
      |> maybe_put_paper("style", style)
      |> maybe_put_paper("source_doc", attrs["source_doc"])
      |> maybe_put_paper("goal_id", attrs["goal_id"])
      |> maybe_put_paper("event_type", attrs["event_type"])
      # Label-spine passthrough (D26): a caller-supplied weighted `tags` array
      # + `description` persist into the paper's content, so a compliant
      # ingest POST can pass the wall below and search/readers see the labels.
      # Absent keys leave any existing content labels untouched (an update
      # without tags never strips a labeled paper).
      |> maybe_put_paper("tags", attrs["tags"])
      |> maybe_put_paper("description", attrs["description"])
      |> maybe_put_paper("dedup_bypass", attrs["dedup_bypass"])
      |> maybe_put_paper("reader_checks", attrs["reader_checks"])
      # Session-handoff Task 2 ("generalized upsert"): the fixed known-key
      # allowlist above stays PAPER-ONLY (byte-identical behavior). Sessions
      # (and any future metadata-bearing blocks type) instead pass through
      # every OTHER caller-supplied attr verbatim — the brief's "blocks body +
      # metadata fields" contract (e.g. a session's status/harness/etc. land
      # in content as-is). Reserved keys already handled explicitly above (or
      # by the surrounding pipeline) are excluded so this never double-writes
      # or clobbers a derived key.
      |> maybe_put_blocks_doc_metadata(type, attrs)
      |> Map.put("rev", next_rev)
      # Project-on-write (Exp-P2): when this write carries a block list, project
      # the bound-field index + content["body"] from it. The SOLE writer of
      # content[fieldName]/content["body"], alongside apply_paper_block_op/3.
      # An HTML-only (legacy) write with no blocks skips projection untouched.
      |> maybe_project(blocks, type, dataset, slug, paper_scope(existing, scope_attrs))

    title = paper_title(content, slug)

    # THE WALL (charter D26) — the fifth and LAST mount. This path births
    # PUBLISHED rows via direct Repo writes below, so the shared AuthoringWall
    # chain runs HERE, on a synthesized in-memory ref, before anything is
    # persisted. The ref's doc_id is the SLUG (papers key `(slug, dataset)`
    # with no `drafts.` prefix), so (a) the exemption ledger grandfathers
    # pre-wall papers exactly like Lifecycle publishes, and (b) the self-id
    # reaches the E4 dedup wall's incumbent exclusion — a paper republish can
    # never near-duplicate ITSELF. Errors return RAW wall tuples (422/422/409
    # via Errors), never flattened into {:halted, _}. On success `content`
    # gains the D7 main_tag stamp — ingest-born papers are denormalized like
    # any lifecycle publish. `bypass_wall: true` (audited call sites only)
    # skips both.
    #
    # `AuthoringWall.enforce/5`'s gates are scoped to `@walled_types = ~w(paper
    # task)` — a non-walled type (e.g. "session") passes the label-spine/dedup
    # gates as a no-op catch-all, exactly like any other non-walled user
    # content type. Threading `type` through here is safe by construction.
    case enforce_blocks_wall(type, content, title, existing, dataset, slug, scope_attrs, opts) do
      {:ok, content} ->
        persist_blocks_doc(
          type,
          content,
          attrs,
          existing,
          dataset,
          slug,
          scope_attrs,
          title,
          opts
        )

      {:error, _} = error ->
        error
    end
  end

  # The Repo write + broadcast tail, reached only once the wall passed (or an
  # audited caller bypassed it).
  defp persist_blocks_doc(type, content, attrs, existing, dataset, slug, scope_attrs, title, opts) do
    doc_attrs = %{
      "doc_id" => slug,
      "type" => type,
      "dataset" => dataset,
      "title" => title,
      "status" => "published",
      "content" => content,
      "rev" => generate_rev()
    }

    # Stamp tenancy scope on the paper row. W1.5-C: an ingest/Studio caller MAY
    # thread an explicit workspace/project (via `attrs["workspace_id"]` /
    # `["project_id"]`) — when present it ALWAYS wins, so the surface is ready
    # the moment paper ingest starts sending the goal's scope. Absent it, this
    # falls back to the seeded Default workspace/project (same contract as
    # create_document/4) — without that a NULL-workspace paper is invisible to
    # the now-scoped Studio desk (B8/qucz). An UPDATE only re-stamps when the
    # caller asserted an explicit scope; otherwise `scope_attrs` resolved to
    # `%{}` above and the existing row's scope is preserved.
    doc_attrs = Map.merge(doc_attrs, scope_attrs)

    changeset =
      Document.changeset(existing || %Document{}, doc_attrs)

    result =
      if existing do
        Repo.update(changeset)
      else
        Repo.insert(changeset)
      end

    case result do
      {:ok, doc} ->
        save_upsert_revision(doc, type, dataset, existing, opts)
        broadcast_paper_update(doc)
        enqueue_edge_projection(doc)
        # P6.U1: append a goal-path lifecycle event ALONGSIDE the paper save,
        # gated strictly on a present `event_type` so ordinary streaming saves
        # never create events. The paper save is the source of truth — an
        # event-insert failure is logged and swallowed, never propagated.
        #
        # W1.5-C: the event FOLLOWS the paper's (goal's) scope — stamp it with
        # the saved doc's resolved workspace/project (Default fallback already
        # applied to the doc above) so a goal's events share the goal's scope.
        maybe_append_paper_event(attrs, slug, doc)
        {:ok, doc}

      error ->
        error
    end
  end

  # [paper-upsert-unlogged-clobber] Record the version-history row for a paper
  # upsert. THE ASYMMETRY THIS CLOSES: `Content.upsert_document/4` pipes its
  # result through `Broadcast.tap_broadcast/7`, which calls `save_revision/5`
  # UNCONDITIONALLY — every write through the writer path leaves a snapshot. The
  # paper path above instead called only `broadcast_paper_update/1`, a bare
  # PubSub fan-out that saves NO revision. So `upsert_paper/2` replaced a
  # PUBLISHED paper's whole `content` under a fresh opaque `rev` while
  # `bp doc history` stood still, and the state it overwrote was never captured
  # anywhere — not merely hard to find, gone. Every seal citing such a revision
  # became unverifiable, and a legitimate bulk migration became
  # indistinguishable from an accidental clobber.
  #
  # Measured on the live corpus before the fix by lead-corpus (2026-09-02, one
  # `bp doc query paper --all` dump of all 1050 published papers; ledger row
  # `task-45307192c1b0e1ef` — note its ORIGINAL description undercounts by an
  # order of magnitude, having sampled a single 30-paper wave cohort, and was
  # corrected in a later stage note): 485 of 1050 published papers were
  # rewritten inside a 46-second window on 2026-08-17 (15:40:09.987Z →
  # 15:40:55.791Z), with further sweeps on 08-23 (131 + 54), 08-25 (153) and
  # 09-02 (51), and `intuition-atlas-verdict` is live and published with a
  # revision history of count 0 — born here, never logged.
  #
  # NOT one runaway script: `barkpark-changelog-2026-07-17` has history through
  # 2026-08-24T17:12Z and then an unlogged write on 08-25 — a different day and
  # a different batch from the 08-17 sweep. Several callers reach this one
  # low-level write, which is why the fix belongs HERE and not in any caller.
  #
  # STATED PRECISELY, because the stronger claim was never established: what was
  # measured is that this path DID NOT RECORD WHAT IT CHANGED. Whether it was
  # obliged to is a question nobody verified beforehand — this commit decides it
  # by making the path log, rather than asserting an intent it inherited.
  #
  # WHY LOG, NOT FORBID: this is the legitimate Bulldocs ingest / `bp paper`
  # publish entry point. Refusing a republish would break authoring outright. A
  # migration must stay possible — it must just leave a trace. Both legs record:
  # the UPDATE leg as "update" (the clobber), the INSERT leg as "create" (the
  # count-0 case). `attrs` is deliberately NOT consulted for the action — the
  # row's prior existence is the ground truth for which happened.
  #
  # BEST-EFFORT, matching `maybe_save_batch_revision/3` and
  # `maybe_append_paper_event/3`: the paper save is the source of truth, and
  # `save_revision/5` is the non-bang variant that already logs its own failures
  # ([revision-loss-silent] in broadcast.ex). Failing an otherwise-valid content
  # write because history could not be persisted would be worse than the write
  # landing with a logged gap.
  defp save_upsert_revision(%Document{} = doc, type, dataset, existing, opts) do
    action = if existing, do: "update", else: "create"

    Broadcast.save_revision(doc, type, dataset, action, Keyword.get(opts, :user_id))

    :ok
  end

  # Append a `paper_events` row when this upsert carries a non-empty
  # `event_type`. Decoupled from W7 — pure Postgres via
  # `Barkpark.Plugins.Bulldocs.Events`. Failures are logged, never raised.
  #
  # W1.5-C: the event inherits the saved paper document's workspace/project —
  # the paper already resolved Default-fallback (new rows) or kept its existing
  # scope (updates), so the event always lands in the paper/goal's workspace.
  defp maybe_append_paper_event(attrs, slug, %Document{} = doc) do
    event_type = attrs["event_type"]

    if is_binary(event_type) and event_type != "" do
      event_attrs = %{
        "goal_id" => attrs["goal_id"],
        "paper_slug" => slug,
        "event_type" => event_type,
        "source_doc" => attrs["source_doc"],
        "payload_html" => attrs["payload_html"],
        "branch" => attrs["branch"] || "main",
        "workspace_id" => doc.workspace_id,
        "project_id" => doc.project_id
      }

      case Barkpark.Plugins.Bulldocs.Events.create_event(event_attrs) do
        {:ok, _event} ->
          :ok

        {:error, reason} ->
          require Logger
          Logger.warning("paper_events append failed for #{inspect(slug)}: #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end

  @doc """
  Apply a single portable-doc `op` (a DocPatchOp map) to a paper's block list,
  persist the new block list + a refreshed `body_html` cache + a bumped
  streaming rev, then broadcast a **delta** frame.

  Flow mirrors the former `Barkpark.Papers.apply_block_op/3`:

    1. Load the paper. Unknown slug ⇒ `{:error, :not_found}`. An HTML-only
       paper is rejected before patching so opaque authored bytes cannot be
       replaced by an implicit empty block list.
    2. Apply via `Barkpark.PortableDoc.Patch.apply_patch/2`.
    3. Render the affected block + refresh the whole `content["body_html"]`.
    4. Persist `content["blocks"]` + `content["body_html"]` + bumped
       `content["rev"]`.
    5. Broadcast `{:paper_block, %{op_kind, block_id, fragment_html, position,
       rev}}` on the per-doc topic.

  Returns `{:ok, %{block:, fragment_html:, op_kind:, block_id:, position:,
  rev:}}` on success. When `opts[:if_rev]` is present, it must match the
  paper's current streaming revision and the final row update is atomically
  fenced; omitting it preserves the legacy last-write-wins contract.
  """
  def apply_paper_block_op(slug, op, dataset \\ @paper_default_dataset, opts \\ [])
      when is_binary(slug) and is_map(op) do
    with %Document{} = doc <- get_block_op_paper(slug, dataset, opts),
         :ok <- reject_implicit_html_conversion(doc),
         if_rev = Keyword.get(opts, :if_rev),
         :ok <- check_paper_if_rev(doc, if_rev),
         blocks = get_in(doc.content || %{}, ["blocks"]) || [],
         # Doctrine backstop (pdd-t20): the OP layer enforces the paper
         # constraint VOCABULARY (cardinality + relative order) alongside the
         # locked-placement checks Patch already runs. The PAPER declaration set
         # is passed by the caller (core stays generic, D10); D12's
         # only-when-before-valid guard keeps the legacy corpus untouched (D3).
         {:ok, patched} <-
           Patch.apply_patch(blocks, op, constraints: Papers.Template.paper_declarations()),
         # Quality-gate RATCHET (p-quality-gate): an op may not hollow OUT a
         # paper that had real content — papers publish in place, so a
         # hollowed canvas edit would BE a hollow published paper. A fresh,
         # still-hollow paper (seeded title + empty tpl-body) stays freely
         # editable: the ratchet only fires on the non-hollow → hollow edge.
         :ok <- ratchet_hollow(blocks, patched),
         # Field-loss RATCHET (pd-note-block): the same clean → lossy edge for a
         # note/card block whose prose was authored under a key the renderer
         # ignores. An already-lossy block persists; a clean one cannot be edited
         # into the lossy shape.
         :ok <- reject_new_field_loss(blocks, patched),
         # Route the op-applied list through the SAME chokepoint before
         # persisting: a NEW op-inserted block carrying no id (clients normally
         # mint ids, but the op payload is not guaranteed to) would otherwise be
         # stored id-less. `normalize_list_items` likewise canonicalizes any
         # flat-string list item the op carried (the obsidian crash fix). Both are
         # additive + idempotent — they only fill a missing id / coerce a string
         # item, never disturb an op-supplied id or a canonical inline item. Run
         # BEFORE locate so the affected block + fragment_html see the final list.
         new_blocks = patched |> ensure_block_ids() |> normalize_render_shapes(),
         # Field-encryption CHOKEPOINT (Phase 2): encrypt marked bound block
         # values BEFORE locate/render/project, so the streaming editor stores
         # ciphertext-at-rest and the delta fragment + body_html cache redact the
         # encrypted field. No-op when nothing in the "paper" schema is marked;
         # fail closed (HIGH-3) when a marked block cannot be sealed.
         {:ok, new_blocks} <- encrypt_paper_blocks(new_blocks, dataset, doc.workspace_id),
         {:ok, affected} <- locate_paper_affected(op, new_blocks) do
      op_kind = Map.get(op, "op")
      rev = paper_next_rev(doc)
      # Carry the doc's stored article marker into the render so both the
      # body_html cache and the delta fragment match the article palette.
      style = get_in(doc.content || %{}, ["style"])
      scope = [workspace_id: doc.workspace_id, project_id: doc.project_id]
      render_opts = Labels.paper_render_opts(dataset, style, scope)
      body_html = Render.render_blocks(new_blocks, render_opts)

      fragment_html =
        case affected.block do
          nil -> nil
          block -> Render.render_block(block, render_opts)
        end

      content =
        (doc.content || %{})
        |> Map.put("blocks", new_blocks)
        |> put_body_html(body_html)
        |> Map.put("rev", rev)
        # Project-on-write (Exp-P2): the SOLE writer of content[fieldName] and
        # content["body"]. Re-derives the bound-field index + body from the
        # block list we just computed, so Classic queries stay in sync with the
        # blocks and never drift. Threads the PRE-patch `blocks` as old_blocks so
        # an unbind (fieldName→nil) clears the now-orphaned content[fieldName].
        |> Projection.project(blocks, new_blocks, project_opts(render_opts, slug, doc))

      title = paper_title(content, slug)

      changeset =
        Document.changeset(doc, %{
          "content" => content,
          "title" => title,
          "rev" => generate_rev()
        })

      case fenced_or_plain_paper_update(changeset, doc, opts) do
        {:ok, saved} ->
          frame = %{
            op_kind: op_kind,
            block_id: affected.block_id,
            fragment_html: fragment_html,
            position: affected.position,
            rev: rev
          }

          broadcast_paper_block(slug, doc.workspace_id, dataset, frame)
          enqueue_edge_projection(saved)

          {:ok,
           %{
             block: affected.block,
             fragment_html: fragment_html,
             op_kind: op_kind,
             block_id: affected.block_id,
             position: affected.position,
             rev: rev
           }}

        {:error, changeset} ->
          {:error, changeset}
      end
    else
      nil -> {:error, :not_found}
      {:error, _reason} = err -> err
    end
  end

  @doc """
  Apply a LIST of portable-doc ops to a paper's block list **atomically** —
  the batch twin of `apply_paper_block_op/4`.

  All-or-nothing: the ops fold over the paper's block list in order; the FIRST
  op that fails halts the fold and the function returns the error with the
  paper **UNCHANGED** (no Repo write, no rev bump, no broadcast). Only when
  every op applies cleanly is the result persisted **once** (one row update,
  one rev bump) and a single delta frame broadcast.

  Flow:

    1. Load the paper (scoped). Unknown slug ⇒ `{:error, :not_found}`. An
       HTML-only paper is rejected before the fold, preserving its authored
       bytes and revision without a write.
    2. Fold the ops through `Barkpark.PortableDoc.Patch.apply_patch/2`,
       collecting each op's affected block id against the intermediate state.
       Halt + return `{:error, reason}` on the first failure (the same tagged
       tuples `apply_paper_block_op/4` surfaces), leaving the paper untouched.
    3. On full success: render the new block list, refresh the `body_html`
       cache, project-on-write, bump `content["rev"]` once, persist once.
    4. Broadcast one `{:paper_block, …}` delta frame carrying the new rev and
       the list of affected block ids.

  Returns `{:ok, %{slug:, op_count:, rev:, block_ids:}}` on success — the
  MINIMAL batch receipt (no per-op fragment_html). An empty `ops` list is a
  no-op that still loads the paper and returns the receipt at the current rev
  with `op_count: 0` and no block_ids, without writing.
  """
  def apply_paper_block_ops(slug, ops, dataset \\ @paper_default_dataset, opts \\ [])
      when is_binary(slug) and is_list(ops) do
    with %Document{} = doc <- get_block_op_paper(slug, dataset, opts),
         {:ok, receipt, effects} <- persist_paper_block_ops(doc, slug, ops, dataset, opts) do
      run_paper_batch_effects(effects, dataset, opts)
      {:ok, receipt}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = err -> err
    end
  end

  @doc """
  Apply one request-identified paper-op batch once within the idempotency
  store's bounded retention window (24 hours by default; the editor retries for
  at most one hour).

  The request id is scoped to the physical paper row, its complete tenant
  identity, and the authenticated principal. The ops plus `:if_rev` form the
  payload fingerprint. A matching retry returns the original receipt without
  rechecking the now-stale revision and without repeating post-commit effects;
  reuse for different input fails closed. This facade must own its transaction
  boundary so those effects run only after the actual commit; calling it from
  an already-open transaction is rejected before any read, claim, or mutation.
  """
  def apply_paper_block_ops_once(
        slug,
        ops,
        dataset,
        request_id,
        principal_key,
        opts \\ []
      )

  def apply_paper_block_ops_once(slug, ops, dataset, request_id, principal_key, opts)
      when is_binary(slug) and is_list(ops) and is_binary(dataset) and is_list(opts) do
    with false <- Repo.in_transaction?(),
         {:ok, request_id} <- normalize_paper_ops_request_id(request_id),
         {:ok, principal_key} <- normalize_paper_ops_principal(principal_key),
         %Document{} = doc <- get_block_op_paper(slug, dataset, opts) do
      key_hash = paper_ops_key_hash(doc, request_id, principal_key)
      exact_scope = "paper_ops:v1:" <> paper_ops_payload_fingerprint(ops, opts)

      Repo.transaction(fn ->
        case IdempotencyStore.claim_exact(key_hash, exact_scope) do
          :claimed ->
            maybe_after_idempotency_claim(opts)

            case get_block_op_paper(slug, dataset, opts) do
              %Document{id: current_id} = current_doc when current_id == doc.id ->
                case persist_paper_block_ops(current_doc, slug, ops, dataset, opts) do
                  {:ok, receipt, effects} ->
                    maybe_before_idempotency_complete(opts)

                    case IdempotencyStore.complete_exact(key_hash, exact_scope, receipt) do
                      :ok -> {:applied, receipt, effects}
                      {:error, reason} -> Repo.rollback(reason)
                    end

                  {:error, reason} ->
                    Repo.rollback(reason)
                end

              _ ->
                Repo.rollback(:not_found)
            end

          {:replay, stored_receipt} ->
            case normalize_stored_paper_ops_receipt(stored_receipt) do
              {:ok, receipt} -> {:replayed, receipt}
              {:error, reason} -> Repo.rollback(reason)
            end

          :in_progress ->
            Repo.rollback(:idempotency_in_progress)

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, {:applied, receipt, effects}} ->
          run_paper_batch_effects(effects, dataset, opts)
          {:ok, receipt, :applied}

        {:ok, {:replayed, receipt}} ->
          {:ok, receipt, :replayed}

        {:error, reason} ->
          {:error, reason}
      end
    else
      true -> {:error, :paper_ops_nested_transaction_unsupported}
      nil -> {:error, :not_found}
      {:error, _reason} = err -> err
    end
  end

  def apply_paper_block_ops_once(_slug, _ops, _dataset, _request_id, _principal_key, _opts),
    do: {:error, :invalid_paper_ops_request}

  defp persist_paper_block_ops(%Document{} = doc, slug, ops, dataset, opts) do
    with if_rev = Keyword.get(opts, :if_rev),
         :ok <- check_paper_if_rev(doc, if_rev),
         {:ok, blocks} <- resolve_batch_paper_blocks(doc, if_rev),
         {:ok, folded, block_ids} <- fold_paper_ops(blocks, ops),
         # Same quality-gate RATCHET as the single-op path, applied to the
         # atomic batch RESULT: the whole batch is refused (paper unchanged)
         # when it would hollow out a non-hollow paper.
         :ok <- ratchet_hollow(blocks, folded),
         # Same field-loss RATCHET as the single-op path, on the atomic batch
         # RESULT: the whole batch is refused (paper unchanged) when it would
         # newly strand a note/card block's prose under an unread key.
         :ok <- reject_new_field_loss(blocks, folded),
         # Same chokepoint as the single-op path: an op-inserted block lacking an
         # id is filled, and any flat-string list item is canonicalized, before
         # persistence. Both additive + idempotent, so a batch of well-formed
         # (id-bearing, canonical-item) ops is byte-identical through it.
         normalized = folded |> ensure_block_ids() |> normalize_render_shapes(),
         # Field-encryption CHOKEPOINT (Phase 2): same as the single-op path —
         # encrypt marked bound block values before render/project/persist so the
         # batch write stores ciphertext-at-rest. No-op for an unmarked schema;
         # fail closed (HIGH-3) when a marked block cannot be sealed.
         {:ok, new_blocks} <- encrypt_paper_blocks(normalized, dataset, doc.workspace_id) do
      cond do
        ops == [] ->
          # Nothing to apply — report the current rev, no write, no broadcast.
          {:ok,
           %{
             slug: slug,
             op_count: 0,
             rev: paper_current_rev(doc),
             block_ids: []
           }, nil}

        true ->
          rev = paper_next_rev(doc)
          style = get_in(doc.content || %{}, ["style"])
          scope = [workspace_id: doc.workspace_id, project_id: doc.project_id]
          render_opts = Labels.paper_render_opts(dataset, style, scope)
          body_html = Render.render_blocks(new_blocks, render_opts)

          content =
            (doc.content || %{})
            |> Map.put("blocks", new_blocks)
            |> put_body_html(body_html)
            |> Map.put("rev", rev)
            # Pre-patch `blocks` as old_blocks: a batch that unbinds a field
            # clears the orphan content[fieldName]; non-unbind ops ⇒ dropped == [].
            |> Projection.project(blocks, new_blocks, project_opts(render_opts, slug, doc))

          title = paper_title(content, slug)

          changeset =
            Document.changeset(doc, %{
              "content" => content,
              "title" => title,
              "rev" => generate_rev()
            })

          case fenced_or_plain_paper_update(changeset, doc, opts) do
            {:ok, saved} ->
              frame = %{
                op_kind: :batch,
                block_id: List.last(block_ids),
                block_ids: block_ids,
                fragment_html: nil,
                position: nil,
                rev: rev
              }

              {:ok,
               %{
                 slug: slug,
                 op_count: length(ops),
                 rev: rev,
                 block_ids: block_ids
               }, {saved, slug, frame}}

            {:error, :precondition_failed} = err ->
              err

            {:error, changeset} ->
              {:error, changeset}
          end
      end
    else
      {:error, _reason} = err -> err
    end
  end

  defp run_paper_batch_effects(nil, _dataset, _opts), do: :ok

  defp run_paper_batch_effects({%Document{} = saved, slug, frame}, dataset, opts) do
    broadcast_paper_block(slug, saved.workspace_id, dataset, frame)
    enqueue_edge_projection(saved)
    maybe_save_batch_revision(saved, dataset, opts)
    :ok
  end

  defp normalize_paper_ops_request_id(request_id) when is_binary(request_id) do
    case Ecto.UUID.cast(request_id) do
      {:ok, canonical} -> {:ok, canonical}
      :error -> {:error, :invalid_request_id}
    end
  end

  defp normalize_paper_ops_request_id(_), do: {:error, :invalid_request_id}

  defp normalize_paper_ops_principal(principal_key) when is_binary(principal_key) do
    case String.trim(principal_key) do
      "" -> {:error, :missing_principal}
      canonical -> {:ok, canonical}
    end
  end

  defp normalize_paper_ops_principal(_), do: {:error, :missing_principal}

  # Internal contention seam: the unboxed two-connection regression pauses the
  # winning transaction after INSERT so the losing INSERT is forced to observe
  # a genuinely in-flight Postgres uniqueness conflict. No host passes it.
  defp maybe_after_idempotency_claim(opts) do
    case Keyword.get(opts, :after_idempotency_claim) do
      fun when is_function(fun, 0) -> fun.()
      _ -> :ok
    end
  end

  # Test-only fault seam: lets the transaction regression remove/corrupt the
  # pending receipt after the document UPDATE, proving completion failure rolls
  # the document back too. Production hosts never set this option.
  defp maybe_before_idempotency_complete(opts) do
    case Keyword.get(opts, :before_idempotency_complete) do
      fun when is_function(fun, 0) -> fun.()
      _ -> :ok
    end
  end

  defp paper_ops_key_hash(%Document{} = doc, request_id, principal_key) do
    {
      "paper_ops:v1",
      doc.id,
      doc.workspace_id,
      doc.project_id,
      doc.dataset_id,
      doc.dataset,
      principal_key,
      request_id
    }
    |> deterministic_hash()
  end

  defp paper_ops_payload_fingerprint(ops, opts) do
    {ops, Keyword.get(opts, :if_rev)}
    |> deterministic_hash()
  end

  defp document_op_key_hash(
         %Document{} = doc,
         target_doc_id,
         type,
         request_id,
         principal_key
       ) do
    {
      "document_op:v1",
      target_doc_id,
      type,
      doc.workspace_id,
      doc.project_id,
      doc.dataset_id,
      doc.dataset,
      principal_key,
      request_id
    }
    |> deterministic_hash()
  end

  defp document_op_payload_fingerprint(op, opts) do
    {op, Keyword.get(opts, :if_rev)}
    |> deterministic_hash()
  end

  defp deterministic_hash(term) do
    term
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp normalize_stored_paper_ops_receipt(%{
         "slug" => slug,
         "op_count" => op_count,
         "rev" => rev,
         "block_ids" => block_ids
       })
       when is_binary(slug) and is_integer(op_count) and is_integer(rev) and
              is_list(block_ids) do
    {:ok, %{slug: slug, op_count: op_count, rev: rev, block_ids: block_ids}}
  end

  defp normalize_stored_paper_ops_receipt(_),
    do: {:error, :idempotency_receipt_invalid}

  defp normalize_stored_document_op_receipt(%{
         "block" => block,
         "block_id" => block_id,
         "op_kind" => op_kind,
         "position" => position,
         "written_doc_id" => written_doc_id,
         "written_row_id" => written_row_id,
         "rev" => rev
       })
       when is_map(block) and (is_binary(block_id) or is_nil(block_id)) and
              is_binary(op_kind) and (is_integer(position) or is_nil(position)) and
              is_binary(written_doc_id) and is_binary(written_row_id) and is_binary(rev) do
    {:ok,
     %{
       block: block,
       block_id: block_id,
       op_kind: op_kind,
       position: position,
       written_doc_id: written_doc_id,
       written_row_id: written_row_id,
       rev: rev
     }}
  end

  defp normalize_stored_document_op_receipt(_),
    do: {:error, :idempotency_receipt_invalid}

  defp finish_document_op_transaction(
         {:ok, {:applied, receipt, {{:ok, %Document{} = saved}, payload}}},
         _dataset,
         _previous_doc,
         _opts
       ) do
    Broadcast.flush_deferred_broadcasts()
    _ = Writer.finish_deferred_after_save({:ok, saved}, payload)
    {:ok, receipt, :applied}
  end

  defp finish_document_op_transaction(
         {:ok, {:replayed, receipt}},
         _dataset,
         _previous_doc,
         _opts
       ) do
    Broadcast.clear_deferred_broadcasts()
    Writer.clear_deferred_after_save()
    {:ok, receipt, :replayed}
  end

  defp finish_document_op_transaction({:error, reason}, _dataset, _previous_doc, _opts) do
    Broadcast.clear_deferred_broadcasts()
    Writer.clear_deferred_after_save()
    {:error, reason}
  end

  # Atomic fold: thread the block list through each op via Patch.apply_patch/2,
  # collecting the affected block id per op against the post-op state. Halts on
  # the first failure (returning that op's tagged error) so a partial batch is
  # never persisted. Affected ids are de-duped while preserving first-seen order.
  defp fold_paper_ops(blocks, ops) do
    # Doctrine backstop (pdd-t20): thread the PAPER constraint declarations into
    # every op of the atomic fold, so a batch op that breaks a cardinality /
    # relative-order rule halts the fold exactly like a locked-block op (the
    # paper stays UNCHANGED). Same declaration set as the single-op path.
    constraints = Papers.Template.paper_declarations()

    Enum.reduce_while(ops, {:ok, blocks, []}, fn op, {:ok, acc, ids} ->
      # HOIST (PDS-D458): `ensure_block_ids` runs PER OP, inside the fold, not
      # once after it. Two defects share this one root — the batch used to read
      # its receipt one step BEFORE the id existed, and to thread a still-id-less
      # block into the next op:
      #
      #   1. RECEIPT. `locate_paper_affected` reads the id out of the post-op
      #      list. Minting after the fold meant an id-less append/insert-after
      #      located a `nil` block_id, the `nil -> ids` clause below dropped it,
      #      and the batch answered `{"ok":true,…,"block_ids":[]}` about a block
      #      it HAD minted and persisted — `ok: true` withholding the only
      #      addressable identifier it created. The single-op path (:582) always
      #      minted before locate and reported it correctly; the two shapes of
      #      one route disagreed.
      #   2. COLLISION. `Patch`'s duplicate guard is `id_exists?(blocks, block_id
      #      (block))`, and `block_id/1` is a bare `Map.get` — so an id-less
      #      block asks "does any block have id nil?". With minting deferred, the
      #      FIRST id-less append left a nil-id block in the accumulator and the
      #      SECOND one collided with it: 422 `duplicate_id` on a batch with no
      #      duplicates. Minting per op leaves no nil-id block in `acc`, so the
      #      real duplicate check (a literal id already present) still fires and
      #      the phantom one cannot.
      #
      # Additive + idempotent, exactly as at the other chokepoints: a batch of
      # id-bearing ops is byte-identical through it, and the post-fold
      # `ensure_block_ids` at the caller is then a no-op that stays as the
      # belt-and-braces chokepoint.
      with {:ok, patched} <- Patch.apply_patch(acc, op, constraints: constraints),
           next = ensure_block_ids(patched),
           {:ok, affected} <- locate_paper_affected(op, next) do
        new_ids =
          case affected.block_id do
            nil -> ids
            id -> if id in ids, do: ids, else: ids ++ [id]
          end

        {:cont, {:ok, next, new_ids}}
      else
        {:error, _reason} = err -> {:halt, err}
      end
    end)
  end

  # The CURRENT streaming rev (no bump) — used by the empty-batch no-op receipt.
  defp paper_current_rev(%Document{content: content}) when is_map(content) do
    case Map.get(content, "rev") do
      n when is_integer(n) -> n
      _ -> 0
    end
  end

  defp paper_current_rev(_), do: 0

  defp reject_implicit_html_conversion(%Document{content: content}) when is_map(content) do
    case {Map.get(content, "blocks"), Map.get(content, "body_html")} do
      {blocks, _html} when is_list(blocks) -> :ok
      {_no_blocks, html} when is_binary(html) -> {:error, {:halted, @html_conversion_message}}
      _ -> :ok
    end
  end

  defp reject_implicit_html_conversion(_doc), do: :ok

  # A small legacy cohort stores its authoritative PortableDoc list under
  # content.body.blocks while also carrying the rendered body_html cache. That
  # is block-bearing content, not opaque HTML-only authorship. Permit its
  # one-time promotion to content.blocks only on the atomic batch path and only
  # when the caller supplied an optimistic revision fence. True HTML-only rows
  # remain read-only, and the single-op path remains unable to convert either
  # legacy shape implicitly.
  defp resolve_batch_paper_blocks(%Document{content: content}, if_rev) when is_map(content) do
    top_blocks = Map.get(content, "blocks")
    nested_blocks = get_in(content, ["body", "blocks"])

    cond do
      is_list(top_blocks) ->
        {:ok, top_blocks}

      is_list(nested_blocks) and not is_nil(if_rev) ->
        {:ok, nested_blocks}

      is_list(nested_blocks) ->
        {:error,
         {:halted,
          "Legacy body.blocks papers require an explicit revision-fenced batch conversion."}}

      is_binary(Map.get(content, "body_html")) ->
        {:error, {:halted, @html_conversion_message}}

      true ->
        {:ok, []}
    end
  end

  defp resolve_batch_paper_blocks(_doc, _if_rev), do: {:ok, []}

  # PROVENANCE tap for attributed batch writes (lvw-t2 accept-baseline, D4).
  # When the caller supplies `:revision_action`, record a revision row off the
  # SAVED doc carrying that action string + the caller's `:actor_user_id` —
  # version history then shows WHO performed the sanctioned mutation (block-op
  # writes record no revision by default, so an accepted baseline would
  # otherwise be unattributable). Best-effort: a failed revision insert never
  # rolls back the already-persisted write (same posture as
  # maybe_append_paper_event/3).
  defp maybe_save_batch_revision(%Document{} = saved, dataset, opts) do
    case Keyword.get(opts, :revision_action) do
      action when is_binary(action) and action != "" ->
        case Broadcast.save_revision(
               saved,
               @paper_type,
               dataset,
               action,
               Keyword.get(opts, :actor_user_id)
             ) do
          {:ok, _rev} ->
            :ok

          {:error, reason} ->
            require Logger

            Logger.warning(
              "batch revision (#{action}) failed for #{inspect(saved.doc_id)}: #{inspect(reason)}"
            )

            :ok
        end

      _ ->
        :ok
    end
  end

  # [blockops-unfenced-cas] Fenced batch persist — the write-path mirror of
  # `Writer.fenced_or_plain_update/3`. `check_paper_if_rev/2` validated the
  # client's `ifRev` against the row it READ, but a plain `Repo.update` then
  # issues `UPDATE … WHERE id = pk` (last-write-wins). Two concurrent batches
  # both holding the same base rev both pass the check; the second silently
  # CLOBBERS the first despite a satisfied precondition (lost update). When the
  # client asserted a precondition (`opts[:if_rev]` present), fence the persist
  # on the row's OPAQUE rev read at load (`doc.rev`): the write lands only if the
  # row's rev is STILL that value; otherwise 0 rows change and we surface
  # `{:error, :precondition_failed}` (→ 412) exactly as `check_paper_if_rev`
  # would. With NO `ifRev` (the client sent none) the original unfenced
  # last-write-wins `Repo.update` is unchanged.
  defp fenced_or_plain_paper_update(changeset, %Document{rev: rev} = doc, opts) do
    case Keyword.get(opts, :if_rev) do
      nil ->
        Repo.update(changeset)

      _present when is_binary(rev) and rev != "" ->
        fenced_paper_update(changeset, doc, rev, opts)

      # No opaque rev to fence on (legacy row) — fall back to the plain write.
      _present ->
        Repo.update(changeset)
    end
  end

  defp fenced_paper_update(%Ecto.Changeset{valid?: false} = changeset, _doc, _expected, _opts),
    do: {:error, changeset}

  defp fenced_paper_update(%Ecto.Changeset{} = changeset, %Document{} = doc, expected, opts) do
    # Test seam: a 0-arity fun under `opts[:before_fenced_write]` simulates a
    # concurrent writer committing in the window between the guard read
    # (`check_paper_if_rev`) and this fenced UPDATE — the same race
    # `WriterFenceTest` drives via a `before_save` hook. No production caller
    # sets it (the ingest controller threads only `:if_rev`).
    case Keyword.get(opts, :before_fenced_write) do
      fun when is_function(fun, 0) -> fun.()
      _ -> :ok
    end

    # Set from the changeset's computed changes (encrypted content, the freshly
    # generated rev, projected title). `updated_at` is stamped here since
    # `update_all` bypasses the schema's autogenerated timestamp. The
    # `WHERE rev = expected` clause is the fence: a concurrent batch that bumped
    # the rev — already committed OR still in-flight (Postgres row-locks the
    # UPDATE until that txn commits, then re-evaluates the WHERE) — leaves 0 rows
    # matched, so a stale batch can never clobber the newer one.
    set =
      changeset.changes
      |> Map.to_list()
      |> Keyword.put_new(:updated_at, DateTime.utc_now())

    query =
      from(d in Document,
        where: d.id == ^doc.id and d.rev == ^expected,
        select: d
      )

    case Repo.update_all(query, set: set) do
      {1, [saved]} -> {:ok, saved}
      {0, _} -> {:error, :precondition_failed}
    end
  end

  # M3 optimistic-concurrency guard. When the caller supplies an `ifRev`, reject
  # the batch BEFORE applying any op unless it matches the paper's current rev.
  # Absent `ifRev` (nil) keeps the prior behaviour (always proceed). The expected
  # value may arrive as an integer or a stringified integer (the wire shape);
  # both are compared against the integer `content["rev"]`.
  defp check_paper_if_rev(_doc, nil), do: :ok

  defp check_paper_if_rev(%Document{} = doc, expected) do
    current = paper_current_rev(doc)

    case normalize_if_rev(expected) do
      :invalid -> {:error, :precondition_failed}
      ^current -> :ok
      _other -> {:error, :precondition_failed}
    end
  end

  defp normalize_if_rev(n) when is_integer(n), do: n

  defp normalize_if_rev(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> :invalid
    end
  end

  defp normalize_if_rev(_), do: :invalid

  @doc """
  Apply a single portable-doc `op` to ANY Expectation-bearing document's block
  list (Exp-P3.2 — the generalization of `apply_paper_block_op/3` off the
  hardcoded `"paper"` type onto an arbitrary `{doc_id, type}`).

  This is the Beta block editor's write path for a non-paper document (a post):
  the same DocPatchOps the paper pane emits (`patch-block`, `insert-after`,
  `append-block`, `remove-block`, `move-block`, `replace-block`) apply to the
  document's `content["blocks"]`, then the content is re-projected
  (`Projection.project/3` — bound blocks → `content[fieldName]`, free blocks →
  `content["body"]`) and persisted through the canonical `upsert_document/4`
  path, which broadcasts `{:doc_updated,…}` + fires lifecycle hooks exactly
  like a Classic save.

  Synthesis-on-first-edit (Exp-P2/P3.1): a document with no stored
  `content["blocks"]` synthesizes its block list in memory via
  `resolve_blocks_for_edit/3`, applies the op to that, and the write persists
  the result — the first Beta edit is what materializes the blocks on disk.

  The block list is the SAME one Classic reads through projection — never a
  separate copy. Returns `{:ok, %{block, block_id, op_kind, position}}` on
  success, mirroring `apply_paper_block_op/3`'s result shape (minus the
  paper-only streaming `rev`/`fragment_html`, which the document editor does
  not stream). `opts` is forwarded to `upsert_document/4` for hook context.
  """
  @spec apply_document_block_op(String.t(), String.t(), map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def apply_document_block_op(doc_id, type, op, dataset, opts \\ [])
      when is_binary(doc_id) and is_binary(type) and is_map(op) do
    with {:ok, %Document{} = doc} <- Content.get_document(doc_id, type, dataset, opts),
         :ok <- reject_implicit_html_conversion(doc),
         {blocks, _synth?} = Papers.resolve_blocks_for_edit(doc, type, dataset),
         {:ok, new_blocks} <- Patch.apply_patch(blocks, op),
         {:ok, affected} <- locate_paper_affected(op, new_blocks) do
      content =
        (doc.content || %{})
        |> Map.put("blocks", new_blocks)
        # Project-on-write — the SOLE writer of content[fieldName]/content["body"]
        # for this document, identical to the paper path. Bound title → "title",
        # free body blocks → content["body"]. Pre-patch `blocks` as old_blocks so
        # a Beta-editor unbind clears the orphaned content[fieldName].
        |> Projection.project(blocks, new_blocks, doc_project_opts(dataset, type, doc))

      # Derive the row title from the bound title field if present (matches the
      # Classic-save title precedence), else keep the document's current title.
      new_title = blank_to_nil(Map.get(content, "title")) || doc.title

      attrs = %{
        "doc_id" => DraftId.draft_id(DraftId.published_id(doc_id)),
        "title" => new_title,
        "status" => doc.status,
        "content" => content
      }

      case Content.upsert_document(type, attrs, dataset, opts) do
        {:ok, saved} ->
          {:ok,
           %{
             block: affected.block,
             block_id: affected.block_id,
             op_kind: Map.get(op, "op"),
             position: affected.position,
             # Session-handoff (final review, F5): the row this path actually
             # WROTE is the `drafts.<slug>` twin (see `attrs["doc_id"]` above),
             # NOT the published `<slug>` row a reader resolves. Naming it in
             # the result lets an HTTP receipt be honest about which document
             # changed instead of echoing the requested slug.
             written_doc_id: attrs["doc_id"],
             written_row_id: saved.id,
             rev: saved.rev
           }}

        {:error, _} = err ->
          err
      end
    else
      {:error, :not_found} -> {:error, :not_found}
      {:error, _reason} = err -> err
    end
  end

  @doc """
  Apply one request-identified Beta document block operation exactly once.

  The request identity is bound to the stable draft target, tenancy, principal,
  operation payload, and optimistic revision. The completed receipt also binds
  the physical row UUID, so deleting and recreating the same document leaf can
  never inherit an old success. Matching retries return the original receipt
  without repeating the write. This facade also owns the generic writer's
  deferred effect queue and flushes it only after commit.

  `apply_document_block_op/5` remains the compatible keyless API.
  """
  @spec apply_document_block_op_once(
          String.t(),
          String.t(),
          map(),
          String.t(),
          String.t(),
          String.t(),
          keyword()
        ) :: {:ok, map(), :applied | :replayed} | {:error, term()}
  def apply_document_block_op_once(
        doc_id,
        type,
        op,
        dataset,
        request_id,
        principal_key,
        opts \\ []
      )

  def apply_document_block_op_once(
        doc_id,
        type,
        op,
        dataset,
        request_id,
        principal_key,
        opts
      )
      when is_binary(doc_id) and is_binary(type) and is_map(op) and is_binary(dataset) and
             is_list(opts) do
    with false <- Repo.in_transaction?(),
         {:ok, request_id} <- normalize_paper_ops_request_id(request_id),
         {:ok, principal_key} <- normalize_paper_ops_principal(principal_key),
         target_doc_id = DraftId.draft_id(DraftId.published_id(doc_id)),
         {:ok, %Document{} = doc} <-
           get_document_op_base(target_doc_id, doc_id, type, dataset, opts) do
      key_hash = document_op_key_hash(doc, target_doc_id, type, request_id, principal_key)
      exact_scope = "document_op:v1:" <> document_op_payload_fingerprint(op, opts)

      Broadcast.clear_deferred_broadcasts()
      Writer.clear_deferred_after_save()

      try do
        Repo.transaction(fn ->
          case IdempotencyStore.claim_exact(key_hash, exact_scope) do
            :claimed ->
              maybe_after_idempotency_claim(opts)

              case lock_document_op_base(target_doc_id, doc_id, type, dataset, opts) do
                {:ok, %Document{id: current_id}} when current_id == doc.id ->
                  write_opts = Keyword.put(opts, :defer_after_save, true)

                  case apply_document_block_op(doc.doc_id, type, op, dataset, write_opts) do
                    {:ok, receipt} ->
                      maybe_before_idempotency_complete(opts)

                      case IdempotencyStore.complete_exact(key_hash, exact_scope, receipt) do
                        :ok ->
                          case Writer.take_deferred_after_save() do
                            {{:ok, %Document{id: row_id}}, _payload} = deferred
                            when row_id == receipt.written_row_id ->
                              {:applied, receipt, deferred}

                            _ ->
                              Repo.rollback(:document_after_save_effect_missing)
                          end

                        {:error, reason} ->
                          Repo.rollback(reason)
                      end

                    {:error, reason} ->
                      Repo.rollback(reason)
                  end

                _ ->
                  Repo.rollback(:not_found)
              end

            {:replay, stored_receipt} ->
              with {:ok, %Document{id: current_row_id}} <-
                     lock_document_op_base(target_doc_id, doc_id, type, dataset, opts),
                   {:ok, %{written_row_id: written_row_id} = receipt} <-
                     normalize_stored_document_op_receipt(stored_receipt) do
                if written_row_id == current_row_id do
                  {:replayed, receipt}
                else
                  Repo.rollback(:idempotency_target_replaced)
                end
              else
                {:error, reason} -> Repo.rollback(reason)
              end

            :in_progress ->
              Repo.rollback(:idempotency_in_progress)

            {:error, reason} ->
              Repo.rollback(reason)
          end
        end)
        |> finish_document_op_transaction(dataset, doc, opts)
      rescue
        exception ->
          Broadcast.clear_deferred_broadcasts()
          Writer.clear_deferred_after_save()
          reraise exception, __STACKTRACE__
      catch
        kind, reason ->
          Broadcast.clear_deferred_broadcasts()
          Writer.clear_deferred_after_save()
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    else
      true -> {:error, :document_op_nested_transaction_unsupported}
      {:error, _reason} = err -> err
    end
  end

  def apply_document_block_op_once(
        _doc_id,
        _type,
        _op,
        _dataset,
        _request_id,
        _principal_key,
        _opts
      ),
      do: {:error, :invalid_document_op_request}

  defp get_document_op_base(target_doc_id, requested_doc_id, type, dataset, opts) do
    case Content.get_document(target_doc_id, type, dataset, opts) do
      {:ok, %Document{} = draft} -> {:ok, draft}
      {:error, :not_found} -> Content.get_document(requested_doc_id, type, dataset, opts)
      {:error, _reason} = err -> err
    end
  end

  defp lock_document_op_base(target_doc_id, requested_doc_id, type, dataset, opts) do
    case get_document_op_base(target_doc_id, requested_doc_id, type, dataset, opts) do
      {:ok, %Document{} = current} ->
        query =
          from(d in Document,
            where:
              d.id == ^current.id and d.doc_id == ^current.doc_id and d.type == ^current.type and
                d.dataset == ^current.dataset,
            lock: "FOR SHARE"
          )
          |> nullable_identity_filter(:dataset_id, current.dataset_id)
          |> nullable_identity_filter(:workspace_id, current.workspace_id)
          |> nullable_identity_filter(:project_id, current.project_id)

        case Repo.one(query) do
          %Document{} = locked -> {:ok, locked}
          nil -> {:error, :idempotency_target_replaced}
        end

      {:error, _reason} = err ->
        err
    end
  end

  defp nullable_identity_filter(query, field_name, nil),
    do: from(d in query, where: is_nil(field(d, ^field_name)))

  defp nullable_identity_filter(query, field_name, value),
    do: from(d in query, where: field(d, ^field_name) == ^value)

  @doc """
  Apply an ordered batch of block ops to ONE FIELD's block array — the write
  path of a schema `richText` field that opted into the block editor
  (`"editor": "blocks"`, Gyldendal parity stage E1).

  The field's stored value is the shape `Projection.project_body/2` writes:
  `%{"blocks" => [...], "html" => rendered}` — so the Classic reader
  (`Forms.classic_form_value/1`) and every renderer keep working unchanged. A
  legacy plain string is upgraded to one paragraph block on first edit; an
  absent value starts empty.

  Deliberately NOT `apply_document_block_op/5`: that path writes the
  document-level `content["blocks"]` partition and re-projects every bound
  field, so routing a field edit through it would collide with the Beta
  document editor on any doc that has both. This one touches exactly
  `content[field]` and nothing else.

  The batch is checked against the field's declared vocabulary
  (`FieldVocabulary.validate/2`) BEFORE anything is written — the client
  vetoes the same vocabulary calmly, this is the truth.

  Returns `{:ok, %{field, blocks, written_doc_id}}` or `{:error, reason}`.
  """
  @spec apply_field_block_ops(String.t(), String.t(), String.t(), [map()], String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def apply_field_block_ops(doc_id, type, field, ops, dataset, opts \\ [])
      when is_binary(doc_id) and is_binary(type) and is_binary(field) and is_list(ops) do
    with {:ok, %Document{} = doc} <- Content.get_document(doc_id, type, dataset, opts),
         {:ok, field_def} <- field_definition(type, dataset, field, opts),
         blocks = field_blocks(Map.get(doc.content || %{}, field)),
         {:ok, new_blocks} <- Patch.apply_patches(blocks, ops),
         :ok <- FieldVocabulary.validate(FieldVocabulary.from_field(field_def), new_blocks) do
      scope = [workspace_id: doc.workspace_id, project_id: doc.project_id]

      content =
        (doc.content || %{})
        |> Map.put(
          field,
          # task-c46967eb3dc49e77: this field body is read on a SCREEN — the
          # Studio field editor and the paper/document readers — so it names
          # `:article` instead of letting `Render.render_block/2`'s
          # `Map.get(opts, :style, :email)` default stamp mail typography into
          # a persisted field. Siblings: #15973 (document `content[body][html]`),
          # #16037 (papers `body_html`).
          Projection.project_body(
            new_blocks,
            Map.put(Labels.render_opts(dataset, scope), :style, :article)
          )
        )

      attrs = %{
        "doc_id" => DraftId.draft_id(DraftId.published_id(doc_id)),
        "title" => doc.title,
        "status" => doc.status,
        "content" => content
      }

      case Content.upsert_document(type, attrs, dataset, opts) do
        {:ok, _saved} ->
          {:ok, %{field: field, blocks: new_blocks, written_doc_id: attrs["doc_id"]}}

        {:error, _} = err ->
          err
      end
    else
      {:error, _reason} = err -> err
    end
  end

  # The field's raw schema map — the vocabulary rides on it. A field that did
  # not opt into the block editor is refused: the Classic form owns it.
  defp field_definition(type, dataset, field, opts) do
    with {:ok, schema} <-
           Content.resolve_schema(type, dataset, Keyword.take(opts, [:workspace_id, :project_id])),
         %{} = f <- Enum.find(schema.fields || [], &(Map.get(&1, "name") == field)),
         true <- FieldVocabulary.blocks_field?(f) do
      {:ok, f}
    else
      :error -> {:error, :not_found}
      nil -> {:error, {:no_such_field, field}}
      false -> {:error, {:not_a_blocks_field, field}}
      other -> other
    end
  end

  @doc """
  The block array behind a field value, in every shape a `richText` field has
  ever stored: the projected body map, a legacy plain string (one paragraph),
  or nothing.
  """
  @spec field_blocks(term()) :: [map()]
  def field_blocks(%{"blocks" => blocks}) when is_list(blocks), do: blocks

  def field_blocks(text) when is_binary(text) do
    case String.trim(text) do
      "" ->
        []

      t ->
        [
          %{
            "id" => "b-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower),
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => t}]
          }
        ]
    end
  end

  def field_blocks(_), do: []

  # ── Papers — internal ──────────────────────────────────────────────────────

  # The AuthoringWall mount for the direct blocks-doc write path (charter
  # D26). Synthesizes an in-memory `%Document{}` ref carrying exactly what the
  # wall reads — doc_id (the slug = the published id), title, the FINAL
  # content (labels included), dataset and the resolved tenancy scope (the E3
  # registry read scopes workspace-or-global) — and runs the SAME chain
  # Lifecycle delegates to. Returns `{:ok, content}` with the main_tag stamp
  # applied, or a raw wall error tuple. `bypass_wall: true` short-circuits
  # BOTH (an unwalled write must stay byte-identical to the pre-mount
  # behaviour — no stamp, no ledger touch).
  #
  # `type` threads straight into `AuthoringWall.enforce/5`, whose gates are
  # scoped to its own `@walled_types = ~w(paper task)` — passing "session"
  # here hits that module's catch-all clauses (no label-spine requirement, no
  # dedup check), the same no-op posture every other non-walled content type
  # gets. Only "paper" (and, elsewhere, "task") is ever actually walled.
  defp enforce_blocks_wall(type, content, title, existing, dataset, slug, scope_attrs, opts) do
    if Keyword.get(opts, :bypass_wall, false) do
      {:ok, content}
    else
      scope = paper_scope(existing, scope_attrs)

      ref = %Document{
        doc_id: slug,
        type: type,
        dataset: dataset,
        title: title,
        content: content,
        workspace_id: scope[:workspace_id],
        project_id: scope[:project_id]
      }

      AuthoringWall.enforce(ref, type, slug, dataset,
        workspace_id: scope[:workspace_id],
        project_id: scope[:project_id]
      )
    end
  end

  # Quality gate, whole-write seam (p-quality-gate): a block-bearing upsert
  # whose RESULT is hollow (skeleton-only, Hollow.hollow?/1) is refused with
  # the same {:error, {:halted, msg}} shape as a plugin veto, so every caller
  # (ingest, chat, bp, mutate stubs) renders the honest copy identically.
  # Non-list blocks (HTML-only / carried-over writes) are exempt.
  defp reject_hollow_result(blocks) when is_list(blocks) do
    if Hollow.hollow?(blocks) do
      {:error, {:halted, Hollow.message()}}
    else
      :ok
    end
  end

  defp reject_hollow_result(_no_blocks_list), do: :ok

  # Quality gate, op-path RATCHET (p-quality-gate): halt only on the
  # non-hollow → hollow edge. Fresh hollow papers (seeded title + empty
  # tpl-body paragraph) stay freely editable; a paper that HAS content can
  # never be edited back down to the bare skeleton.
  defp ratchet_hollow(prev_blocks, new_blocks) do
    if not Hollow.hollow?(prev_blocks) and Hollow.hollow?(new_blocks) do
      {:error, {:halted, Hollow.ratchet_message()}}
    else
      :ok
    end
  end

  # Silent-content-loss RATCHET (pd-note-block-silent-content-loss). A note/card
  # block in the lossy shape (`Slots.lossy_shape?/1`: renders no prose while an
  # unknown key holds authored text) is refused with the plugin-veto halt shape —
  # but ONLY when it is NEWLY lossy. Ratchet by block id: a block already lossy in
  # `prev_blocks` may persist (the existing live losses stay editable, so their
  # next save does not brick, and they get repaired deliberately), while a clean
  # block edited into the lossy shape — or a fresh lossy block — is rejected. Runs
  # on EVERY paper write with NO locked-block precondition (unlike
  # Papers.Template.validate/1, which 416/419 papers skip). Non-list blocks
  # (HTML-only writes) flatten to [] and are exempt.
  defp reject_new_field_loss(prev_blocks, new_blocks) do
    already_lossy = lossy_block_ids(prev_blocks)

    new_blocks
    |> flatten_typed_blocks()
    |> Enum.find(fn block ->
      Slots.lossy_shape?(block) and not MapSet.member?(already_lossy, Map.get(block, "id"))
    end)
    |> case do
      nil -> :ok
      block -> {:error, {:halted, field_loss_message(block)}}
    end
  end

  # The ids of blocks ALREADY in the lossy shape, so the ratchet never bricks an
  # existing loss (an id-less lossy block is treated as new — it cannot be matched).
  defp lossy_block_ids(blocks) do
    blocks
    |> flatten_typed_blocks()
    |> Enum.filter(&Slots.lossy_shape?/1)
    |> Enum.map(&Map.get(&1, "id"))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  # Flatten a block list to every typed block, recursing through `section`
  # containers (their child list under `"blocks"`), so a note/card nested in a
  # section is checked too. A non-list input yields [].
  defp flatten_typed_blocks(blocks) when is_list(blocks) do
    Enum.flat_map(blocks, fn
      %{"blocks" => children} = block when is_list(children) ->
        [block | flatten_typed_blocks(children)]

      block ->
        [block]
    end)
  end

  defp flatten_typed_blocks(_), do: []

  defp field_loss_message(block) do
    type = Map.get(block, "type", "block")

    "This #{type} block would render empty — its text is authored under a key " <>
      "the renderer ignores. Move the prose into the block's content field."
  end

  # The stored blocks of the existing paper row (the prev side of the upsert
  # ratchet), or [] for a brand-new paper / an HTML-only row.
  defp existing_paper_blocks(nil), do: []

  defp existing_paper_blocks(%Document{} = existing),
    do: get_in(existing.content || %{}, ["blocks"]) || []

  # Resolve which block an op affected (post-apply) plus its top-level position.
  # Identical to the former Barkpark.Papers.locate_affected/2, except the
  # append/insert clauses now read the STORED block out of `new_blocks` rather
  # than trusting the op payload — so an op whose `block` carried no id reports
  # the id `ensure_block_ids` just minted, keeping the broadcast frame's block_id
  # and the persisted block in sync.
  #
  # CALLER CONTRACT (was falsified until PDS-D458, and this comment asserted the
  # false half): a caller that wants a non-nil `block_id` for an id-less
  # append/insert-after MUST run `ensure_block_ids` over `new_blocks` BEFORE
  # calling this. `apply_paper_block_op/4` does so at :582; the BATCH fold did
  # NOT — it minted once AFTER the fold, so this function was handed a list
  # whose freshly-appended block was still id-less, which is exactly how the
  # batch receipt came to withhold the id it had minted and persisted.
  # `fold_paper_ops/2` now mints per op, so both paper paths honour it.
  # `apply_document_block_op/5` still does not (its ids are minted downstream in
  # `upsert_document`), so an id-less block op on a DOCUMENT reports block_id
  # nil — a known, untouched gap on a different surface, not this contract.
  defp locate_paper_affected(%{"op" => "append-block", "block" => block}, new_blocks) do
    position = length(new_blocks) - 1
    stored = Enum.at(new_blocks, position) || block
    {:ok, %{block: stored, block_id: Map.get(stored, "id"), position: position}}
  end

  defp locate_paper_affected(%{"op" => "insert-after", "afterId" => after_id} = op, new_blocks) do
    block = Map.get(op, "block") || %{}

    case Map.get(block, "id") do
      id when is_binary(id) and id != "" ->
        {:ok, %{block: block, block_id: id, position: paper_top_level_index(new_blocks, id)}}

      _ ->
        # The op block carried no id — `ensure_block_ids` minted one in
        # `new_blocks`. The inserted block sits directly after `afterId`.
        position =
          case paper_top_level_index(new_blocks, after_id) do
            nil -> nil
            anchor_idx -> anchor_idx + 1
          end

        stored = position && Enum.at(new_blocks, position)

        {:ok,
         %{block: stored || block, block_id: stored && Map.get(stored, "id"), position: position}}
    end
  end

  defp locate_paper_affected(%{"op" => kind, "id" => id}, new_blocks)
       when kind in ["patch-block", "replace-block"] do
    block = paper_find_block(new_blocks, id)
    {:ok, %{block: block, block_id: id, position: paper_top_level_index(new_blocks, id)}}
  end

  defp locate_paper_affected(%{"op" => "remove-block", "id" => id}, _new_blocks) do
    {:ok, %{block: nil, block_id: id, position: nil}}
  end

  # move-block: the moved block kept its id + content; report it at its NEW
  # top-level index so the View-pane stream can re-place it correctly.
  defp locate_paper_affected(%{"op" => "move-block", "id" => id}, new_blocks) do
    block = paper_find_block(new_blocks, id)
    {:ok, %{block: block, block_id: id, position: paper_top_level_index(new_blocks, id)}}
  end

  defp locate_paper_affected(op, _new_blocks), do: {:error, {:invalid_op, op}}

  defp paper_top_level_index(blocks, id) do
    Enum.find_index(blocks, fn b -> Map.get(b, "id") == id end)
  end

  defp paper_find_block(blocks, id) do
    Enum.find_value(blocks, fn block ->
      cond do
        Map.get(block, "id") == id -> block
        Map.get(block, "type") == "section" -> paper_find_block(Map.get(block, "blocks", []), id)
        true -> nil
      end
    end)
  end

  @doc """
  R2 fix (Option A). Walk a block list and fill a stable positional id
  (`block-<index>`, sections recurse with a `<parent>.<index>` prefix) for
  any block that lacks one. A block already carrying a non-blank "id" is left
  untouched, so author/op-supplied ids — which DocPatchOps address blocks by —
  survive byte-identical and stay resolvable. Sections recurse so a nested
  id-less child also gets a unique id (the stream only keys on top-level ids,
  but `apply_paper_block_op` addresses children too).

  Coverage (the three id-less shapes a block can take):

    * ABSENT — no `"id"` key at all → gets `<prefix>-<index>`.
    * BLANK  — `"id" => ""` or `"id" => nil` → gets `<prefix>-<index>`.
    * NESTED — recursion covers any block carrying a `"blocks"` list — sections
      are the only id-addressable nested container, so they are the only thing
      recursed. (composite / arrayOf inline children nest under `"items"` /
      `"content"`, are inline — not id-addressable blocks — and are NOT
      recursed.) The recursion prefix is the parent's (now-ensured) id, keeping
      child ids unique and deterministic.

  Collision-safe WITHIN each list (and each nested list). Before minting, the
  set of all present non-blank ids at this level is collected. The positional
  candidate `<prefix>-<index>` is checked against that set PLUS every id already
  minted this pass; if taken, a deterministic suffix (`-<k>`, k incrementing
  from 1) is appended until free. So a MIXED list — an id-bearing block whose
  literal id collides with the positional slot of an id-less block, or two
  id-less blocks resolving to the same slot — can never produce DUPLICATE ids.

  Idempotent: re-running over an already-id-bearing list is a no-op (a present
  non-blank id is preserved exactly). This is the SINGLE chokepoint every write
  path that persists `content["blocks"]` routes through — the paper upsert path
  (`upsert_paper`), the document write path (`Content.Writer.create_document` /
  `upsert_document`, covering the Sanity-shaped mutation + legacy-create
  ingress), the op-fold paths (`apply_paper_block_op` / `apply_paper_block_ops`),
  and the backfill Mix task all call it, so an id-less block can never reach
  storage.

  Post-condition: within any block list (and each nested list), all ids are
  UNIQUE.
  """
  @spec ensure_block_ids(list()) :: list()
  def ensure_block_ids(blocks) when is_list(blocks), do: ensure_block_ids(blocks, "block")

  defp ensure_block_ids(blocks, prefix) when is_list(blocks) do
    # Seed the working set with EVERY present non-blank id at this level, so a
    # minted positional id can never collide with a literal id already present
    # (the mixed-paper duplicate-id corruption). The set then grows as each
    # id-less block is filled, so two id-less blocks at the same level can't
    # collide either.
    taken = present_ids(blocks)

    {ensured, _taken} =
      blocks
      |> Enum.with_index()
      |> Enum.map_reduce(taken, fn {block, index}, taken ->
        ensure_block_id(block, prefix, index, taken)
      end)

    ensured
  end

  # The set of all present, non-blank string ids in a block list (this level
  # only — nested lists carry their own scope).
  defp present_ids(blocks) do
    Enum.reduce(blocks, MapSet.new(), fn block, acc ->
      case is_map(block) && Map.get(block, "id") do
        id when is_binary(id) and id != "" -> MapSet.put(acc, id)
        _ -> acc
      end
    end)
  end

  # Returns `{ensured_block, taken'}` — the block with a guaranteed-unique id
  # (recursing into a section's children), and the working id-set extended with
  # any id this block now occupies. A present non-blank id is preserved exactly
  # (already in `taken`); an id-less block mints a collision-free positional id.
  defp ensure_block_id(block, prefix, index, taken) when is_map(block) do
    {id, taken} =
      case Map.get(block, "id") do
        existing when is_binary(existing) and existing != "" ->
          # Already present and already counted in `taken` via present_ids/1.
          {existing, taken}

        _ ->
          id = unique_id(prefix, index, taken)
          {id, MapSet.put(taken, id)}
      end

    block = Map.put(block, "id", id)

    block =
      case Map.get(block, "blocks") do
        children when is_list(children) ->
          Map.put(block, "blocks", ensure_block_ids(children, id))

        _ ->
          block
      end

    {block, taken}
  end

  defp ensure_block_id(block, _prefix, _index, taken), do: {block, taken}

  @doc """
  Normalize legacy FLAT-STRING list items to the canonical inline-ARRAY shape
  (the obsidian list-item-crash corpus fix).

  ## Why

  The canonical `list` block stores each item as an INLINE ARRAY —
  `%{"type" => "list", "items" => [[%{"type" => "text", "value" => "…"}], …]}`.
  But 7 legacy papers (webhook-* / qstash-* / ga4-* specs) store list items as
  FLAT STRINGS — `"items" => ["text one", "text two"]`. The continuous canvas
  (and the per-block editor) project a list through `convert.js`'s
  `inlineArrayToTiptap`, which runs `.forEach` on each item — a flat string
  THROWS ("forEach is not a function"), crashing BOTH editors the moment such a
  paper opens. `convert.js` now coerces a string item defensively so it never
  throws; this normalizer fixes the STORED data so the editor's reconstructed
  (inline-array) shape matches what is on disk — no spurious shape-flip patch on
  the first canvas load (the same churn the id-less backfill prevents).

  ## Contract

    * **Render-IDENTICAL** — a string item `"x"` becomes
      `[%{"type" => "text", "value" => "x"}]`. `compose.ex` renders BOTH the same
      (`compose_inline_children("x") == compose_inline_children([%{…value=>"x"}])`
      → `["x"]`), so `content["body_html"]` is byte-identical before and after.
      The change is item SHAPE only; item CONTENT (the text) is unchanged.
    * **Additive + idempotent** — a canonical inline-ARRAY item is left BYTE-
      IDENTICAL (the fast path), so re-running over an already-normalized list
      writes nothing. Only a non-array (string / scalar) item is coerced.
    * **Recurses into sections** — exactly like `ensure_block_ids`, it recurses
      into a block's `"blocks"` list (sections) so a list nested in a section is
      normalized too.

  Coverage (the item shapes a list can carry):

    * STRING — `"text"` → `[%{"type" => "text", "value" => "text"}]`.
    * INLINE ARRAY — `[%{"type" => "text", …}]` → unchanged (canonical).
    * other scalar (number) → its string form as one text node.
    * `nil` item → `[]` (an empty list item), never a crash.

  This is routed through the SAME write chokepoints `ensure_block_ids` uses (the
  paper upsert path, the document write path, the op-fold paths, the scaffold),
  so a flat-string list item can never reach storage from a fresh write; the
  backfill Mix task repairs the EXISTING corpus.
  """
  @spec normalize_list_items(list()) :: list()
  def normalize_list_items(blocks) when is_list(blocks) do
    Enum.map(blocks, &normalize_block_list_items/1)
  end

  def normalize_list_items(other), do: other

  @doc """
  Canonicalize the lossless persisted block dialects that otherwise render
  differently across Paper readers.

  The transform is deliberately conservative: wrappers carrying metadata are
  retained byte-for-byte for the tolerant readers, while unambiguous wrappers
  are reduced to the canonical wire shape. It is recursive and idempotent.

  Beyond the wrapper reductions, two rescue arms run here (the ONE write
  chokepoint every producer path routes through — pe-w1-write-path-normalizer):

    * `notes`/`cards` ITEMS that arrive as bare strings (or inline arrays)
      become text maps, and `pipeline` NODES become TITLE maps (the key its
      readers render) — the readers address item FIELDS
      through `get/2`, which is nil on a binary, so the raw shape renders an
      EMPTY row while the paper answers 200 (live: `heggemsnes-act`). The arm
      is TYPE-KEYED, never generic over `items` — `byline` string items are
      the canonical designed shape (compose.ex joins stringish items; 215
      live papers) and pass through byte-identical.
    * text-KEYED inline leaves (`%{"type" => "text", "text" => …}`, the
      TipTap dialect) become value-keyed — the renderer reads ONLY `value`
      (render/inline.ex), so a text-keyed leaf renders as the empty string
      and a paragraph whose only leaf carries it VANISHES (live:
      `deploy-reliability-wave-4-2026-08-06`). Leaves already carrying a
      `value` are left byte-identical.
  """
  @spec normalize_render_shapes(list()) :: list()
  def normalize_render_shapes(blocks) when is_list(blocks) do
    blocks
    |> normalize_list_items()
    |> Enum.map(&normalize_render_block/1)
    |> Enum.map(&normalize_inline_leaf_dialect/1)
  end

  def normalize_render_shapes(other), do: other

  @doc """
  Reject a block list holding an ELEMENT that is not an object, at any nesting
  level the render walk descends.

  ## Why this exists next to `validate_render_shapes/1`

  `validate_render_shapes/1` is the PAPER publish gate: it is deliberately
  strict (list items, table rows/cells, legacy list dialects) and only runs for
  `@paper_type`. This one is the TYPE floor every document write needs, and it
  refuses exactly ONE shape — a non-map element — because that shape is the only
  one that CRASHES:

      Render.render_blocks/2   # `when is_list(blocks)` — the LIST is guarded
      |> Enum.map(&render_block(&1, opts))
      # render_block/2 is `when is_map(block)` — the ELEMENT is not

  so `["notamap"]` clears the list guard and then raises `FunctionClauseError`
  inside the write projection (`Content.Writer` → `Projection.project/4` →
  `Projection.project_body/2` → `Render.render_blocks/2`), which reaches the
  client as an uncaught 500 with an HTML body instead of the v1 JSON envelope.
  Every OTHER malformed shape the corpus produces already renders to `""`
  (`Compose.block_to_html/2` and `Compose.figure_html/3` both carry a non-map
  catch-all), so widening this beyond the element type would REJECT writes that
  are accepted today.

  ## Descent

  `"blocks"` and `"children"` — the same two container keys
  `normalize_render_shapes/1` and `render_shape_errors/2` descend, so the three
  walkers agree on what a nested block list is. A nested non-map is not itself a
  crash (the compose bridge renders it as `""`), but it is silent content LOSS
  behind a 200, so it is refused at the same door.

  Returns `:ok`, or `{:error, {:malformed_blocks, %{"blocks" => [path, …]}}}`,
  which `Barkpark.Content.Errors` renders as a 400 `malformed` envelope.
  """
  @spec validate_block_elements(term(), String.t()) ::
          :ok | {:error, {:malformed_blocks, map()}}
  def validate_block_elements(blocks, path \\ "blocks")

  def validate_block_elements(blocks, path) when is_list(blocks) and is_binary(path) do
    case block_element_errors(blocks, path) do
      [] -> :ok
      errors -> {:error, {:malformed_blocks, %{"blocks" => errors}}}
    end
  end

  # A non-list block root never reaches `render_blocks/2` (its `is_list` guard
  # holds) — the scaffold falls back to an empty paragraph and the projection
  # skips it. Nothing to refuse.
  def validate_block_elements(_blocks, _path), do: :ok

  defp block_element_errors(blocks, path) do
    blocks
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {block, index} when is_map(block) ->
        Enum.flat_map(["blocks", "children"], fn key ->
          case Map.get(block, key) do
            children when is_list(children) ->
              block_element_errors(children, "#{path}[#{index}].#{key}")

            _ ->
              []
          end
        end)

      {_block, index} ->
        ["#{path}[#{index}] must be an object"]
    end)
  end

  @doc """
  Reject a Paper block tree that still contains a reader-incompatible shape
  after normalization. Metadata-bearing wrappers are accepted when every
  reader has a lossless fallback for their content field.
  """
  @spec validate_render_shapes(term()) :: :ok | {:error, {:invalid_paper_structure, map()}}
  def validate_render_shapes(blocks) when is_list(blocks) do
    case render_shape_errors(blocks, "blocks") do
      [] -> :ok
      errors -> {:error, {:invalid_paper_structure, structure_refusal_details(blocks, errors)}}
    end
  end

  def validate_render_shapes(_),
    do:
      {:error,
       {:invalid_paper_structure,
        %{"blocks" => ["must be an array when a Paper declares a block body"]}}}

  # The refusal's registered hint tells the author to "Fix the listed block
  # paths", and the `blocks` messages do carry a POSITIONAL one
  # (`blocks[12].rows[0].cells[1] has no renderable inline content`). What they
  # never carried is the authored block ID — the token an author greps their own
  # document for, and the one the reporter of this wall had to BISECT a
  # 105-block Paper to recover ("the first rejecting block was b12"). A
  # positional index is only as good as the caller's copy of the list; the id
  # survives an insert above it. `block_ids` names the offending blocks
  # directly, deduplicated, in first-refusal order.
  #
  # Purely ADDITIVE: `blocks` stays byte-identical, and the key is OMITTED (not
  # emitted empty) when no offending block carries an id, so a block list
  # without ids refuses exactly as it always did.
  defp structure_refusal_details(blocks, errors) do
    ids =
      errors
      |> Enum.map(&leading_block_index/1)
      |> Enum.uniq()
      |> Enum.flat_map(fn
        nil ->
          []

        index ->
          case Enum.at(blocks, index) do
            %{"id" => id} when is_binary(id) and id != "" -> [id]
            _ -> []
          end
      end)

    case ids do
      [] -> %{"blocks" => errors}
      ids -> %{"blocks" => errors, "block_ids" => ids}
    end
  end

  defp leading_block_index(message) when is_binary(message) do
    case Regex.run(~r/^blocks\[(\d+)\]/, message) do
      [_, index] -> String.to_integer(index)
      _ -> nil
    end
  end

  defp leading_block_index(_), do: nil

  defp render_shape_errors(blocks, prefix) do
    blocks
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {block, index} when is_map(block) ->
        render_block_errors(block, "#{prefix}[#{index}]")

      {_block, index} ->
        ["#{prefix}[#{index}] must be an object"]
    end)
  end

  defp render_block_errors(%{"type" => "list"} = block, path) do
    case Map.get(block, "items") do
      items when is_list(items) ->
        items
        |> Enum.with_index()
        |> Enum.flat_map(fn
          {item, _index} when is_list(item) ->
            []

          {%{"content" => content}, _index} when is_list(content) ->
            []

          {%{"text" => text}, _index} when is_binary(text) ->
            []

          {_item, index} ->
            ["#{path}.items[#{index}] has no renderable inline content"]
        end)

      _ ->
        ["#{path}.items must be an array"]
    end
  end

  defp render_block_errors(%{"type" => type}, path)
       when type in [
              "bulletList",
              "bullet_list",
              "bullet-list",
              "bulletedList",
              "bulleted_list",
              "bulleted-list",
              "orderedList",
              "ordered_list",
              "ordered-list"
            ],
       do: ["#{path}.type must be list before the block reaches readers"]

  defp render_block_errors(%{"type" => "table"} = block, path) do
    rows = Map.get(block, "rows")

    cond do
      not is_list(rows) ->
        ["#{path}.rows must be an array"]

      valid_record_table?(block, rows) ->
        []

      true ->
        row_errors =
          rows
          |> Enum.with_index()
          |> Enum.flat_map(fn {row, index} ->
            render_table_row_errors(row, "#{path}.rows[#{index}]")
          end)

        head_errors =
          case Map.get(block, "head") || Map.get(block, "header") do
            nil ->
              []

            [] ->
              []

            # `head: true` (either spelling) is the PROMOTE-ROW-0 dialect the
            # renderer already speaks: compose.ex matches `{true, [first |
            # rest]}` and lifts row 0 into the head row, and renders `{true,
            # []}` as a headless table. The gate spoke neither — the flag fell
            # through to `render_table_row_errors(true, path)`, whose catch-all
            # refused a block its own reader composes end to end. The promoted
            # cells are `rows[0]`, which `row_errors` above has already
            # validated, so there is nothing left for this arm to check.
            true ->
              []

            head ->
              render_table_row_errors(head, "#{path}.head")
          end

        head_errors ++ row_errors
    end
  end

  defp render_block_errors(block, path) do
    Enum.flat_map(["blocks", "children"], fn key ->
      case Map.get(block, key) do
        children when is_list(children) -> render_shape_errors(children, "#{path}.#{key}")
        _ -> []
      end
    end)
  end

  defp render_table_row_errors(%{"cells" => cells}, path) when is_list(cells),
    do: render_table_cell_errors(cells, path)

  defp render_table_row_errors(cells, path) when is_list(cells),
    do: render_table_cell_errors(cells, path)

  defp render_table_row_errors(_row, path), do: ["#{path} has no renderable cells"]

  defp render_table_cell_errors(cells, path) do
    cells
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {cell, _index} when is_list(cell) ->
        []

      {%{"content" => content}, _index} when is_list(content) ->
        []

      {%{"text" => text}, _index} when is_binary(text) ->
        []

      {_cell, index} ->
        ["#{path}.cells[#{index}] has no renderable inline content"]
    end)
  end

  defp valid_record_table?(%{"columns" => columns}, rows)
       when is_list(columns) and columns != [] do
    keys =
      if Enum.all?(columns, &is_map/1),
        do: Enum.map(columns, &Map.get(&1, "key")),
        else: []

    Enum.all?(columns, &is_map/1) and
      Enum.all?(keys, &(is_binary(&1) and &1 != "")) and
      Enum.uniq(keys) == keys and
      Enum.all?(columns, fn column ->
        label = Map.get(column, "label")
        is_nil(label) or is_binary(label)
      end) and
      Enum.all?(rows, fn row ->
        is_map(row) and Map.keys(row) -- keys == [] and
          Enum.all?(Map.values(row), &record_table_scalar?/1)
      end)
  end

  defp valid_record_table?(_block, _rows), do: false

  defp normalize_render_block(%{"type" => type} = block)
       when type in [
              "bulletList",
              "bullet_list",
              "bullet-list",
              "bulletedList",
              "bulleted_list",
              "bulleted-list",
              "orderedList",
              "ordered_list",
              "ordered-list"
            ] do
    normalize_legacy_list_shape(block, type in ["orderedList", "ordered_list", "ordered-list"])
  end

  defp normalize_render_block(%{"type" => "list", "content" => content} = block)
       when is_list(content) do
    normalize_legacy_list_shape(block, Map.get(block, "ordered") == true)
  end

  defp normalize_render_block(%{"type" => "list", "items" => items} = block)
       when is_list(items) do
    Map.put(block, "items", Enum.map(items, &normalize_wrapped_list_item/1))
  end

  defp normalize_render_block(%{"type" => "table", "content" => content} = block)
       when is_list(content) or is_map(content) do
    normalize_legacy_table_shape(block)
  end

  defp normalize_render_block(%{"type" => "table"} = block) do
    block
    |> canonicalize_table_headers_key()
    |> normalize_table_shape()
  end

  defp normalize_render_block(%{"type" => "callout", "text" => text} = block)
       when is_binary(text) do
    content = Map.get(block, "content")
    slots = Map.get(block, "slots")

    if String.trim(text) != "" and content in [nil, []] and slots in [nil, %{}] do
      block
      |> Map.delete("text")
      |> Map.put("content", [%{"type" => "text", "value" => text}])
    else
      block
    end
  end

  # `notes`/`cards` items are addressed as MAPS by every reader
  # (`components.ex` reads `label`/`title`/`text` through `get/2`, which is
  # nil on a binary) — an agent raised on prose blocks hands them bare strings
  # (or inline arrays) and the row renders EMPTY behind a 200. Rescue the two
  # derivable shapes into the text-map dialect; canonical map items pass
  # byte-identical (idempotent).
  # TYPE-KEYED on purpose: `byline` string items are the DESIGNED shape
  # (compose.ex:231-245 joins stringish items; 215 live papers = 28% of the
  # corpus) — a generic items-must-be-maps arm is forbidden.
  defp normalize_render_block(%{"type" => type, "items" => items} = block)
       when type in ["notes", "cards"] and is_list(items) do
    Map.put(block, "items", Enum.map(items, &normalize_widget_item/1))
  end

  # Pipeline nodes get their OWN rescue key: every pipeline reader renders
  # `title` (components.ex pipeline_html, pdrender stageRenderer, the web
  # projection's `title`/`detail`) and NONE reads `text` — a `%{"text" => s}`
  # rescue here would rewrite stored bytes into a shape that still renders an
  # empty node (proven against Components.pipeline_html/1 in the independent
  # second review of #11616).
  defp normalize_render_block(%{"type" => "pipeline", "nodes" => nodes} = block)
       when is_list(nodes) do
    Map.put(block, "nodes", Enum.map(nodes, &normalize_pipeline_node/1))
  end

  defp normalize_render_block(block) when is_map(block) do
    Enum.reduce(["blocks", "children"], block, fn key, normalized ->
      case Map.get(normalized, key) do
        children when is_list(children) ->
          Map.put(normalized, key, normalize_render_shapes(children))

        _ ->
          normalized
      end
    end)
  end

  defp normalize_render_block(block), do: block

  # ONE widget item/node → the text-map dialect the readers understand. A map
  # (the canonical shape) is untouched; a bare string becomes `%{"text" => s}`;
  # an inline ARRAY flattens to its plain text. An inline array with NO
  # derivable text — or any other scalar — is left as-is: this is a rescue
  # arm, never a destroyer.
  defp normalize_widget_item(item) when is_binary(item), do: %{"text" => item}

  defp normalize_widget_item(item) when is_list(item) do
    case inline_plain_text(item) do
      "" -> item
      text -> %{"text" => text}
    end
  end

  defp normalize_widget_item(item), do: item

  # ONE pipeline node → the title-map dialect the pipeline readers render.
  # Same rescue discipline as normalize_widget_item, different key.
  defp normalize_pipeline_node(node) when is_binary(node), do: %{"title" => node}

  defp normalize_pipeline_node(node) when is_list(node) do
    case inline_plain_text(node) do
      "" -> node
      text -> %{"title" => text}
    end
  end

  defp normalize_pipeline_node(node), do: node

  # Flatten an inline array (or one inline node) to concatenated PLAIN text,
  # marks dropped: a leaf contributes its `value` (or TipTap `text`), a mark
  # node its flattened `children`/`content`, a bare string itself.
  defp inline_plain_text(nodes) when is_list(nodes),
    do: nodes |> Enum.map(&inline_plain_text/1) |> Enum.join()

  defp inline_plain_text(s) when is_binary(s), do: s
  defp inline_plain_text(n) when is_number(n), do: to_string(n)

  defp inline_plain_text(%{} = node) do
    cond do
      is_binary(Map.get(node, "value")) -> Map.get(node, "value")
      is_binary(Map.get(node, "text")) -> Map.get(node, "text")
      is_list(Map.get(node, "children")) -> inline_plain_text(Map.get(node, "children"))
      is_list(Map.get(node, "content")) -> inline_plain_text(Map.get(node, "content"))
      true -> ""
    end
  end

  defp inline_plain_text(_), do: ""

  # ── inline-leaf dialect (TipTap `text` → canonical `value`) ────────────────
  #
  # The canonical text leaf carries `value`. `Render.Inline.compose_inline/2`
  # has dual-read `value || text` since 2026-08-23 (and its Go twin through
  # `attrStrFirst(n, "value", "text")`), so a TipTap-dialect leaf no longer
  # renders as "" — but that tolerance is a SAFETY NET at one reader, not a
  # contract every consumer honours, and this is the chokepoint whose job is to
  # store ONE shape. Normalize at the write
  # chokepoint over every inline-bearing surface: block `content`, list
  # `items`, table `rows`/`head` cells, and nested `blocks`/`children`
  # containers. A leaf already carrying `value` is left byte-identical
  # (`value` wins at render), as is everything that is not a text leaf.
  defp normalize_inline_leaf_dialect(%{} = block) do
    block
    |> normalize_inline_under("content")
    |> normalize_list_item_leaves()
    |> normalize_table_leaves()
    |> normalize_nested_block_leaves()
  end

  defp normalize_inline_leaf_dialect(other), do: other

  defp normalize_inline_under(%{} = block, key) do
    case Map.get(block, key) do
      nodes when is_list(nodes) -> Map.put(block, key, normalize_inline_nodes(nodes))
      _ -> block
    end
  end

  defp normalize_list_item_leaves(%{"type" => "list", "items" => items} = block)
       when is_list(items) do
    Map.put(
      block,
      "items",
      Enum.map(items, fn
        item when is_list(item) -> normalize_inline_nodes(item)
        item -> item
      end)
    )
  end

  defp normalize_list_item_leaves(block), do: block

  defp normalize_table_leaves(%{"type" => "table"} = block) do
    block =
      case Map.get(block, "rows") do
        rows when is_list(rows) ->
          Map.put(block, "rows", Enum.map(rows, &normalize_table_row_leaves/1))

        _ ->
          block
      end

    # BOTH head spellings. `header` is first-class at the gate
    # (`render_block_errors/2` reads `head || header`) and at the renderer
    # (compose.ex `declared_head` falls back to `header`), but this rescue only
    # ever reached `head` — so a TipTap text-keyed leaf inside a `header` cell
    # got no dialect normalization and rendered as the empty string forever,
    # exactly the failure #11616 closed on every other inline-bearing surface.
    Enum.reduce(["head", "header"], block, fn key, acc ->
      case Map.get(acc, key) do
        cells when is_list(cells) -> Map.put(acc, key, normalize_table_cells_leaves(cells))
        _ -> acc
      end
    end)
  end

  defp normalize_table_leaves(block), do: block

  defp normalize_table_row_leaves(row) when is_list(row), do: normalize_table_cells_leaves(row)

  defp normalize_table_row_leaves(%{"cells" => cells} = row) when is_list(cells),
    do: Map.put(row, "cells", normalize_table_cells_leaves(cells))

  defp normalize_table_row_leaves(row), do: row

  defp normalize_table_cells_leaves(cells) do
    Enum.map(cells, fn
      cell when is_list(cell) ->
        normalize_inline_nodes(cell)

      %{"content" => content} = cell when is_list(content) ->
        Map.put(cell, "content", normalize_inline_nodes(content))

      cell ->
        cell
    end)
  end

  defp normalize_nested_block_leaves(block) do
    Enum.reduce(["blocks", "children"], block, fn key, acc ->
      case Map.get(acc, key) do
        children when is_list(children) ->
          Map.put(acc, key, Enum.map(children, &normalize_inline_leaf_dialect/1))

        _ ->
          acc
      end
    end)
  end

  defp normalize_inline_nodes(nodes), do: Enum.map(nodes, &normalize_inline_node/1)

  defp normalize_inline_node(%{"type" => "text", "text" => text} = leaf) when is_binary(text) do
    if Map.has_key?(leaf, "value") do
      leaf
    else
      leaf |> Map.delete("text") |> Map.put("value", text)
    end
  end

  defp normalize_inline_node(%{} = node) do
    Enum.reduce(["children", "content"], node, fn key, acc ->
      case Map.get(acc, key) do
        list when is_list(list) -> Map.put(acc, key, normalize_inline_nodes(list))
        _ -> acc
      end
    end)
  end

  defp normalize_inline_node(other), do: other

  defp normalize_wrapped_list_item(%{"content" => content} = item)
       when is_list(content) and map_size(item) == 1,
       do: content

  defp normalize_wrapped_list_item(%{"text" => text} = item)
       when is_binary(text) and map_size(item) == 1,
       do: [%{"type" => "text", "value" => text}]

  defp normalize_wrapped_list_item(item), do: item

  defp normalize_legacy_list_shape(block, ordered_default) do
    source =
      Enum.find_value(["items", "content", "children"], fn key ->
        case Map.get(block, key) do
          items when is_list(items) -> items
          _ -> nil
        end
      end)

    with items when is_list(items) <- source,
         {:ok, normalized_items} <- map_legacy_inline_items(items) do
      style =
        String.downcase(to_string(Map.get(block, "style") || Map.get(block, "listStyle") || ""))

      ordered =
        ordered_default or Map.get(block, "ordered") == true or
          style in ~w(ordered number numbered decimal)

      block
      |> Map.drop(["content", "children", "items", "style", "listStyle"])
      |> Map.put("type", "list")
      |> Map.put("ordered", ordered)
      |> Map.put("items", normalized_items)
    else
      _ -> block
    end
  end

  defp map_legacy_inline_items(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case normalize_legacy_list_item(item) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :error -> :error
    end
  end

  defp normalize_legacy_list_item(%{"id" => id} = item) when is_binary(id) do
    if Map.keys(item) -- ["id", "content", "text"] == [] and
         (is_list(Map.get(item, "content")) or is_binary(Map.get(item, "text"))) do
      {:ok, item}
    else
      normalize_legacy_inline(item)
    end
  end

  defp normalize_legacy_list_item(item), do: normalize_legacy_inline(item)

  defp normalize_legacy_inline(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_list(decoded) or is_map(decoded) ->
        normalize_legacy_inline(decoded)

      _ ->
        {:ok, [%{"type" => "text", "value" => value}]}
    end
  end

  defp normalize_legacy_inline(nil), do: {:ok, []}

  defp normalize_legacy_inline(value) when is_number(value) or is_boolean(value),
    do: {:ok, [%{"type" => "text", "value" => to_string(value)}]}

  defp normalize_legacy_inline(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case normalize_legacy_inline(value) do
        {:ok, inline} -> {:cont, {:ok, acc ++ inline}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp normalize_legacy_inline(%{"type" => "text", "value" => value} = node)
       when is_binary(value),
       do: {:ok, [Map.delete(node, "text")]}

  defp normalize_legacy_inline(%{"type" => type, "content" => content})
       when type in [
              "paragraph",
              "listItem",
              "list_item",
              "tableCell",
              "table_cell",
              "tableHeader",
              "table_header"
            ] and is_list(content),
       do: normalize_legacy_inline(content)

  defp normalize_legacy_inline(%{"content" => content} = wrapper)
       when is_list(content) and map_size(wrapper) == 1,
       do: normalize_legacy_inline(content)

  defp normalize_legacy_inline(%{"text" => text} = wrapper)
       when is_binary(text) and map_size(wrapper) == 1,
       do: {:ok, [%{"type" => "text", "value" => text}]}

  defp normalize_legacy_inline(%{"type" => type} = inline) when is_binary(type) and type != "",
    do: {:ok, [inline]}

  defp normalize_legacy_inline(_value), do: :error

  defp normalize_legacy_table_shape(%{"content" => content} = block) do
    {head, rows} =
      case content do
        content when is_map(content) ->
          {Map.get(content, "head") || Map.get(content, "header"), Map.get(content, "rows")}

        content when is_list(content) ->
          {nil, content}

        _ ->
          {nil, nil}
      end

    with rows when is_list(rows) <- rows,
         {:ok, normalized_rows, header_flags} <- normalize_legacy_table_rows(rows),
         {:ok, explicit_head} <- normalize_optional_legacy_head(head) do
      {resolved_head, resolved_rows} =
        cond do
          is_list(explicit_head) -> {explicit_head, normalized_rows}
          normalized_rows != [] and hd(header_flags) -> {hd(normalized_rows), tl(normalized_rows)}
          true -> {nil, normalized_rows}
        end

      normalized =
        block
        |> Map.drop(["content", "head", "header", "rows"])
        |> Map.put("type", "table")
        |> Map.put("rows", resolved_rows)

      if is_list(resolved_head), do: Map.put(normalized, "head", resolved_head), else: normalized
    else
      _ -> block
    end
  end

  defp normalize_legacy_table_shape(block), do: block

  defp normalize_legacy_table_rows(rows) do
    Enum.reduce_while(rows, {:ok, [], []}, fn row, {:ok, row_acc, flag_acc} ->
      case normalize_legacy_table_row(row) do
        {:ok, cells, header?} ->
          {:cont, {:ok, [cells | row_acc], [header? | flag_acc]}}

        :error ->
          {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed_rows, reversed_flags} ->
        {:ok, Enum.reverse(reversed_rows), Enum.reverse(reversed_flags)}

      :error ->
        :error
    end
  end

  defp normalize_legacy_table_row(row) when is_list(row),
    do: normalize_legacy_table_cells(row, false)

  defp normalize_legacy_table_row(row) when is_map(row) do
    cells =
      if is_list(Map.get(row, "content")),
        do: Map.get(row, "content"),
        else: Map.get(row, "cells")

    if is_list(cells) do
      cell_headers =
        Enum.map(cells, fn
          %{"header" => true} -> true
          %{"type" => type} when type in ["tableHeader", "table_header"] -> true
          _ -> false
        end)

      header? = Map.get(row, "header") == true or (cells != [] and Enum.all?(cell_headers))
      normalize_legacy_table_cells(cells, header?)
    else
      :error
    end
  end

  defp normalize_legacy_table_row(_row), do: :error

  defp normalize_legacy_table_cells(cells, header?) do
    case map_legacy_inline_values(cells) do
      {:ok, normalized} -> {:ok, normalized, header?}
      :error -> :error
    end
  end

  defp normalize_optional_legacy_head(nil), do: {:ok, nil}

  defp normalize_optional_legacy_head(head) when is_list(head),
    do: map_legacy_inline_values(head)

  defp normalize_optional_legacy_head(_head), do: :error

  defp map_legacy_inline_values(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case normalize_legacy_inline(value) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :error -> :error
    end
  end

  defp normalize_table_shape(%{"rows" => rows} = block) when is_list(rows) do
    case normalize_record_table(block, rows) do
      {:ok, record_table} ->
        record_table

      :not_record_table ->
        normalize_array_table(block, rows)
    end
  end

  defp normalize_table_shape(block), do: block

  defp normalize_record_table(%{"columns" => columns} = block, rows)
       when is_list(columns) and columns != [] do
    keys =
      if Enum.all?(columns, &is_map/1),
        do: Enum.map(columns, &Map.get(&1, "key")),
        else: []

    valid? =
      Enum.all?(columns, &is_map/1) and
        Enum.all?(keys, &(is_binary(&1) and &1 != "")) and
        Enum.uniq(keys) == keys and
        Enum.all?(columns, fn column ->
          label = Map.get(column, "label")
          is_nil(label) or is_binary(label)
        end) and
        Enum.all?(rows, fn row ->
          is_map(row) and Map.keys(row) -- keys == [] and
            Enum.all?(Map.values(row), &record_table_scalar?/1)
        end)

    if valid? do
      head =
        Enum.map(columns, fn column ->
          [%{"type" => "text", "value" => Map.get(column, "label") || Map.get(column, "key")}]
        end)

      normalized_rows =
        Enum.map(rows, fn row ->
          Enum.map(keys, fn key ->
            [%{"type" => "text", "value" => record_table_text(Map.get(row, key))}]
          end)
        end)

      {:ok,
       block
       |> Map.delete("columns")
       |> Map.put("head", head)
       |> Map.put("rows", normalized_rows)}
    else
      :not_record_table
    end
  end

  defp normalize_record_table(_block, _rows), do: :not_record_table

  defp record_table_scalar?(value),
    do: is_nil(value) or is_binary(value) or is_number(value) or is_boolean(value)

  defp record_table_text(nil), do: ""
  defp record_table_text(value), do: to_string(value)

  # The `headers` (PLURAL) head spelling — the one dialect that reached exactly
  # ONE reader. The Bulldocs BPML printer has always accepted it
  # (`printer.ex` — `alias_get(b, ["head", "header", "headers", "columns"])`),
  # so a BPML export printed the header row. Nothing else did: compose.ex
  # resolves `head` / `header` / `columns` / a legacy header ROW and drops
  # `headers` on the floor, so the authored header row rendered as NOTHING
  # behind a 200; `render_block_errors/2` reads `head || header`, so its cells
  # were never validated (an unrenderable one published clean, and the wall
  # named no path because it never looked); and neither the inline-leaf rescue
  # nor the bare-string cell rescue keys on it. That is what makes a `bp doc
  # get` of a `headers`-keyed table un-round-trippable: the bytes come back and
  # go back in, and the head is silently not there.
  #
  # Canonicalize the key ONCE, here at the write chokepoint, and all three
  # surfaces inherit the dialect for free. Renaming only — cell bytes are
  # untouched. A block that already declares a non-empty `head` keeps BOTH keys
  # verbatim: `head` wins in every reader, and dropping the twin would delete
  # authored content this function has no mandate to judge.
  defp canonicalize_table_headers_key(block) do
    with cells when is_list(cells) and cells != [] <- Map.get(block, "headers"),
         head when head in [nil, []] <- Map.get(block, "head") do
      block |> Map.delete("headers") |> Map.put("head", cells)
    else
      _ -> block
    end
  end

  defp table_head_or_header(block) do
    case Map.get(block, "head") do
      nil -> Map.get(block, "header")
      [] -> Map.get(block, "header")
      head -> head
    end
  end

  defp normalize_array_table(block, rows) do
    block =
      if is_list(Map.get(block, "head")) and Map.get(block, "head") != [] and
           Map.get(block, "header") == true,
         do: Map.delete(block, "header"),
         else: block

    block =
      case {table_head_or_header(block), Map.get(block, "columns")} do
        {head, columns} when head in [nil, []] and is_list(columns) and columns != [] ->
          cond do
            Enum.all?(columns, fn
              %{"text" => text} = column when is_binary(text) -> map_size(column) == 1
              _ -> false
            end) ->
              block
              |> Map.delete("columns")
              |> Map.put(
                "head",
                Enum.map(columns, fn %{"text" => text} ->
                  [%{"type" => "text", "value" => text}]
                end)
              )

            Enum.all?(columns, &record_table_scalar?/1) ->
              block
              |> Map.delete("columns")
              |> Map.put(
                "head",
                Enum.map(columns, fn value ->
                  [%{"type" => "text", "value" => record_table_text(value)}]
                end)
              )

            true ->
              block
          end

        _ ->
          block
      end

    {block, rows} =
      case {table_head_or_header(block), rows} do
        {true, [first | rest]} ->
          case normalize_legacy_table_row(first) do
            {:ok, cells, _header?} ->
              {block |> Map.delete("header") |> Map.put("head", cells), rest}

            :error ->
              {block, rows}
          end

        {head, [%{"header" => true, "cells" => cells} = row | rest]}
        when head in [nil, []] and is_list(cells) and map_size(row) == 2 ->
          {Map.put(block, "head", Enum.map(cells, &normalize_wrapped_table_cell/1)), rest}

        {head, [%{"cells" => cells} | rest]}
        when head in [nil, []] and is_list(cells) ->
          if cells != [] and Enum.all?(cells, &(is_map(&1) and Map.get(&1, "header") == true)) do
            {Map.put(block, "head", Enum.map(cells, &normalize_header_table_cell/1)), rest}
          else
            {block, rows}
          end

        _ ->
          {block, rows}
      end

    rows = Enum.map(rows, &normalize_wrapped_table_row/1)
    block = Map.put(block, "rows", rows)

    # An explicit `head` (one row of cells) gets the same per-cell rescue the
    # body rows get — a bare-string head cell (`"head" => ["Name", "Age"]`)
    # would otherwise refuse at the gate while its body twin publishes.
    case Map.get(block, "head") do
      head when is_list(head) ->
        Map.put(block, "head", Enum.map(head, &normalize_wrapped_table_cell/1))

      _ ->
        block
    end
  end

  defp normalize_wrapped_table_row(%{"cells" => cells} = row)
       when is_list(cells) and map_size(row) == 1,
       do: Enum.map(cells, &normalize_wrapped_table_cell/1)

  defp normalize_wrapped_table_row(%{"cells" => cells, "header" => header} = row)
       when is_list(cells) and header != true and map_size(row) == 2,
       do: Enum.map(cells, &normalize_wrapped_table_cell/1)

  defp normalize_wrapped_table_row(row) when is_list(row),
    do: Enum.map(row, &normalize_wrapped_table_cell/1)

  # A cells-map row carrying EXTRA keys (id, header flags, …) keeps its wrapper
  # — the gate accepts the shape — but its CELLS still get the per-cell rescue,
  # so a bare-string cell inside it publishes instead of refusing.
  defp normalize_wrapped_table_row(%{"cells" => cells} = row) when is_list(cells),
    do: Map.put(row, "cells", Enum.map(cells, &normalize_wrapped_table_cell/1))

  defp normalize_wrapped_table_row(row), do: row

  defp normalize_wrapped_table_cell(%{"content" => content} = cell)
       when is_list(content) and map_size(cell) == 1,
       do: flatten_table_cell_content(content)

  defp normalize_wrapped_table_cell(%{"text" => text} = cell)
       when is_binary(text) and map_size(cell) == 1,
       do: [%{"type" => "text", "value" => text}]

  # A bare-string cell becomes ONE canonical inline array — the renderer
  # already tolerates the bare binary (render/inline.ex scalar clause), but the
  # gate refused it ("has no renderable inline content") even though its text
  # is fully derivable. Truly unrescuable cells (textless maps, numbers, nil)
  # still fall through to the gate's existing refusal.
  defp normalize_wrapped_table_cell(cell) when is_binary(cell),
    do: [%{"type" => "text", "value" => cell}]

  defp normalize_wrapped_table_cell(cell), do: cell

  defp normalize_header_table_cell(%{"content" => content}) when is_list(content),
    do: flatten_table_cell_content(content)

  defp normalize_header_table_cell(%{"text" => text}) when is_binary(text),
    do: [%{"type" => "text", "value" => text}]

  defp normalize_header_table_cell(cell), do: cell

  defp flatten_table_cell_content(content) do
    Enum.flat_map(content, fn
      %{"type" => "paragraph", "content" => inline} when is_list(inline) -> inline
      item -> [item]
    end)
  end

  # Normalize ONE block. A `list` block has its `items` coerced item-by-item to
  # canonical inline arrays; every other block is untouched EXCEPT for recursion
  # into a nested `"blocks"` container (sections), mirroring ensure_block_ids.
  defp normalize_block_list_items(%{"type" => "list", "items" => items} = block)
       when is_list(items) do
    Map.put(block, "items", Enum.map(items, &normalize_list_item/1))
  end

  defp normalize_block_list_items(block) when is_map(block) do
    case Map.get(block, "blocks") do
      children when is_list(children) ->
        Map.put(block, "blocks", normalize_list_items(children))

      _ ->
        block
    end
  end

  defp normalize_block_list_items(block), do: block

  # Coerce ONE list item to a canonical inline ARRAY. A list (already an inline
  # array) is returned BYTE-IDENTICAL — the idempotent fast path. A binary becomes
  # a single text inline node (render-identical, see the moduledoc). Any other
  # scalar coerces to its string form; nil → an empty item.
  defp normalize_list_item(item) when is_list(item), do: item

  defp normalize_list_item(item) when is_binary(item),
    do: [%{"type" => "text", "value" => item}]

  defp normalize_list_item(nil), do: []

  defp normalize_list_item(item) when is_number(item),
    do: [%{"type" => "text", "value" => to_string(item)}]

  defp normalize_list_item(item), do: item

  # The positional candidate `<prefix>-<index>`, disambiguated deterministically
  # if already taken: append `-1`, `-2`, … until free. Deterministic (no
  # randomness) so the same input always yields the same ids, and the appended
  # suffix is itself re-checked against `taken` so it can never collide.
  defp unique_id(prefix, index, taken) do
    candidate = "#{prefix}-#{index}"

    if MapSet.member?(taken, candidate) do
      disambiguate(candidate, taken, 1)
    else
      candidate
    end
  end

  defp disambiguate(base, taken, k) do
    candidate = "#{base}-#{k}"

    if MapSet.member?(taken, candidate) do
      disambiguate(base, taken, k + 1)
    else
      candidate
    end
  end

  # `documents.title` is derived, in priority order, from:
  #   1. the PROJECTED bound title field (`content["title"]`) — Exp-P2: a bound
  #      title field-block is the explicit, editor-authored title, so it wins
  #      and the Classic query (Envelope) surfaces it as the row title;
  #   2. the first heading block's text (legacy heading-driven papers);
  #   3. the slug (the desk list always needs a title).
  defp paper_title(content, slug) when is_map(content) do
    blocks = Map.get(content, "blocks")

    heading_text =
      if is_list(blocks) do
        Enum.find_value(blocks, fn b ->
          if Map.get(b, "type") == "heading", do: blank_to_nil(Map.get(b, "text"))
        end)
      end

    blank_to_nil(Map.get(content, "title")) || heading_text || slug
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s) when is_binary(s), do: s
  defp blank_to_nil(_), do: nil

  # NET-NEW reprojection wiring (wire §7.5 — portabledoc-inline-liveref-taskchip-wire).
  # The three paper writers (`upsert_paper` via `write_encrypted_paper`,
  # `apply_paper_block_op`, `apply_paper_block_ops`) persist via raw
  # `Repo.insert`/`Repo.update` — they bypass `Content.fire_after/3`, so without
  # this call no valueref/wikilink-creating paper edit would EVER reproject the
  # content graph. Fires the SAME lifecycle entry point `fire_after` wires
  # (`EdgeProjector.Lifecycle.enqueue_rebuild`), UN-gated on a link diff: every
  # ordinary Content save already enqueues un-gated, and the worker debounces
  # (schedule_in 5s + a 30s Oban unique window on `(rebuild, scope)`), so a
  # streaming-edit op storm collapses into one per-scope rebuild. Contract:
  # always `:ok` — an enqueue failure is logged inside Lifecycle and must never
  # fail the paper write. (`apply_document_block_op` is NOT wired here: it
  # persists through `upsert_document/4`, which already fires `fire_after`.)
  defp enqueue_edge_projection(%Document{} = doc) do
    Barkpark.EdgeProjector.Lifecycle.enqueue_rebuild(%{
      event: :after_save,
      doc: doc,
      dataset: doc.dataset,
      ctx: nil
    })
  end

  defp broadcast_paper_update(%Document{} = doc) do
    content = doc.content || %{}

    msg =
      {:paper_updated,
       %{
         slug: doc.doc_id,
         dataset: doc.dataset,
         html: Map.get(content, "body_html"),
         rev: Map.get(content, "rev"),
         source_doc: Map.get(content, "source_doc"),
         goal_id: Map.get(content, "goal_id"),
         event_type: Map.get(content, "event_type"),
         # The writing process' pid, so a subscriber that is ALSO the writer
         # (a Studio LiveView editing its own paper) can skip the redundant
         # self-refetch — see the `sender == self()` guards in
         # StudioLive lifecycle handlers. Unknown to other consumers (ignored).
         sender: self()
       }}

    # Workspace-scope the topic (barkpark-n56v): stamp the doc's own
    # workspace_id so the frame only reaches subscribers of THIS tenant. nil
    # (legacy) normalizes to the Default ws inside paper_topic, matching the
    # public viewer's resolved workspace.
    Phoenix.PubSub.broadcast(
      Barkpark.PubSub,
      Broadcast.paper_topic(doc.doc_id, doc.workspace_id, doc.dataset),
      msg
    )
  end

  defp broadcast_paper_block(slug, workspace_id, dataset, frame) do
    # Stamp the writing process' pid so a subscriber that is ALSO the writer
    # (a Studio LiveView editing its own paper) skips the redundant self-echo
    # refetch — the initiator already has the confirmed state (and re-reads it
    # synchronously in `paper_ops/2`). Without this the async self-echo runs a
    # DB reload that, in tests, outlives the render_hook and races the shared
    # sandbox teardown (`client exited`). Mirrors the document `sender` guards.
    Phoenix.PubSub.broadcast(
      Barkpark.PubSub,
      Broadcast.paper_topic(slug, workspace_id, dataset),
      {:paper_block, Map.put(frame, :sender, self())}
    )
  end

  # Allow callers to pass atom OR string keys (controller params are strings,
  # internal callers/tests may use atoms). Stringify, dropping nils.
  defp normalize_paper_attrs(attrs) do
    Enum.reduce(attrs, %{}, fn {k, v}, acc ->
      key = if is_atom(k), do: Atom.to_string(k), else: k
      if is_nil(v), do: acc, else: Map.put(acc, key, v)
    end)
  end

  defp maybe_put_paper(map, _key, nil), do: map
  defp maybe_put_paper(map, key, value), do: Map.put(map, key, value)

  # Keys the surrounding `write_encrypted_blocks_doc/8` pipeline already reads
  # explicitly (as an upsert attr, a paper-only allowlisted content field, or a
  # pipeline control opt) — excluded from the generic session-metadata
  # passthrough below so it can never double-write or clobber a derived key.
  # NOTE: "title" is deliberately NOT reserved here. For a paper, `title`
  # never reaches `content` through this path at all (a paper clause below is
  # a full no-op) — its row title instead comes from a PROJECTED bound title
  # field-block or the first heading (see `paper_title/2`). For a non-paper
  # type there is no such projection, so `content["title"]` — and therefore
  # the Document row's `title` (`paper_title/2` reads `content["title"]`
  # first) — has NO OTHER writer; reserving "title" here would silently drop
  # every session's title on every write.
  # "events" is reserved too (session-handoff Task 4 fix): a session's
  # `content["events"]` trail is written ONLY through
  # `Barkpark.Content.Sessions.append_event/5`'s advisory-lock + CAS path —
  # never through this generic metadata passthrough. Without this reservation
  # an in-process `upsert_blocks_doc("session", %{"events" => [...]})` (or a
  # caller merely echoing a session's own read payload back as an update body)
  # would silently overwrite the append-only trail via the same merge this
  # function performs for every other unreserved key.
  #
  # "conversations" is reserved for the same reason (session-conversations
  # slice): the harness-conversation registry is written ONLY through
  # `Barkpark.Content.Sessions.touch_conversation/5`'s advisory-lock + CAS
  # path — never through this generic metadata passthrough.
  @blocks_doc_reserved_attrs ~w(
    slug dataset blocks workspace_id project_id template style
    source_doc goal_id event_type tags description body_html payload_html
    branch bypass_wall dedup_bypass events conversations
  )

  # Session-handoff Task 2 ("generalized upsert"): `write_encrypted_blocks_doc`'s
  # known-key allowlist (`maybe_put_paper("source_doc", …)` etc.) stays
  # PAPER-ONLY — byte-identical to the pre-Task-2 behavior, per the brief. A
  # session (or any future metadata-bearing blocks type) instead gets every
  # OTHER caller-supplied attr merged into content verbatim — the task's
  # "blocks body + metadata fields" contract (a session's `status`,
  # `harness`, `session_uuid`, … land in content as-is, no fixed allowlist to
  # maintain per field).
  defp maybe_put_blocks_doc_metadata(content, @paper_type, _attrs), do: content

  defp maybe_put_blocks_doc_metadata(content, _type, attrs) do
    attrs
    |> Map.drop(@blocks_doc_reserved_attrs)
    |> Enum.reduce(content, fn {k, v}, acc -> Map.put(acc, k, v) end)
  end

  # Write a FRESHLY-rendered body_html into the content map along with the
  # renderer's version stamp (`body_html_sv`). Only the sites that render
  # body_html FROM blocks call this — a verbatim / carried-over HTML write has
  # unknown provenance and must NOT claim a version (see upsert_paper's
  # block-less branch, which preserves any existing stamp). The stamp lets
  # `mix barkpark.rehydrate_body_html` detect a cache frozen by an older renderer.
  defp put_body_html(content, html) do
    content
    |> Map.put("body_html", html)
    |> Map.put("body_html_sv", Render.body_html_render_version())
  end

  # W1.5-C: build [workspace_id: …, project_id: …] from an EXPLICIT scope the
  # caller threaded through paper attrs (string keys, post-normalize). Returns
  # [] when no workspace_id is present — the Default-fallback path then applies.
  # project_id is only meaningful alongside a workspace_id (matches the
  # scope_to_workspace contract).
  defp paper_scope_opts(attrs) do
    case attrs["workspace_id"] do
      ws when is_binary(ws) and ws != "" ->
        case attrs["project_id"] do
          proj when is_binary(proj) and proj != "" -> [workspace_id: ws, project_id: proj]
          _ -> [workspace_id: ws]
        end

      _ ->
        []
    end
  end

  # The pre-write existing-doc lookup, SCOPED to this write's tenant so a
  # same-slug write in workspace B never finds (and clobbers) workspace A's row
  # (barkpark-w9dg). The scope mirrors the write-stamp fallback: an explicit
  # workspace in attrs wins; absent it, the seeded Default workspace — so the
  # flat, unscoped ingest keeps upserting its own Default-scoped row.
  #
  # `type`-generalized (session-handoff Task 2, off `Papers.get_paper/3`'s
  # hardcoded "paper"): a session write must find its OWN prior session row,
  # never a same-slug PAPER's — `Papers.get_blocks_doc/4` scopes the lookup by
  # `type` exactly like `get_paper/3` did for the paper-only case.
  defp get_existing_blocks_doc_for_write(type, slug, dataset, attrs) do
    case paper_scope_opts(attrs) do
      [_ | _] = opts ->
        Papers.get_blocks_doc(slug, type, dataset, opts)

      [] ->
        case Barkpark.Tenancy.get_default_workspace() do
          %{id: ws_id} when is_binary(ws_id) ->
            Papers.get_blocks_doc(slug, type, dataset, workspace_id: ws_id)

          # No seeded Default (fresh sandbox) — fall back to the prior unscoped
          # lookup so the very first single-tenant write still self-locates.
          _ ->
            Papers.get_blocks_doc(slug, type, dataset)
        end
    end
  end

  # The block-op doc load, SCOPED so a streaming op never resolves (and mutates)
  # a same-slug paper in another workspace (barkpark-af50). Mirrors the
  # write-side scope contract (get_existing_blocks_doc_for_write /
  # get_public_paper): an explicit workspace in opts wins; absent it, the
  # seeded Default workspace — the deterministic public/ingest tenant. Only
  # when no Default is seeded (fresh sandbox) does it fall back to the prior
  # unscoped lookup so a first single-tenant op still self-locates. Paper-only
  # — the streaming block-op functions (`apply_paper_block_op/4` and friends)
  # are out of session-handoff Task 2's scope.
  defp get_block_op_paper(slug, dataset, opts) do
    case Keyword.get(opts, :workspace_id) do
      ws when is_binary(ws) and ws != "" ->
        Papers.get_paper(slug, dataset,
          workspace_id: ws,
          project_id: Keyword.get(opts, :project_id)
        )

      _ ->
        case Barkpark.Tenancy.get_default_workspace() do
          %{id: ws_id} when is_binary(ws_id) ->
            Papers.get_paper(slug, dataset, workspace_id: ws_id)

          _ ->
            Papers.get_paper(slug, dataset)
        end
    end
  end

  # Project-on-write only when this write actually carries a block list. An
  # HTML-only legacy paper write (no blocks) leaves content[fieldName]/body
  # untouched — projection is the SOLE writer, so a no-block write must not
  # invent an empty body.
  defp maybe_project(content, blocks, type, dataset, slug, scope) when is_list(blocks) do
    # task-c46967eb3dc49e77 — A FIFTH style-less site, found by this row's
    # census and NOT in its filing. `write_encrypted_blocks_doc/8` renders
    # `content["body_html"]` through `Labels.paper_render_opts/3` (`:article`
    # since #16037) and then projects `content["body"]["html"]` through THESE
    # opts, which carried no `:style` — so `Render.render_block/2`'s
    # `Map.get(opts, :style, :email)` default decided and one paper row stored
    # its body twice, on TWO DIFFERENT SURFACES. Measured on b2529b02c via
    # `Content.upsert_paper/1` with a plain paragraph and no `content["style"]`:
    #
    #     body_html      => "<p>probe copy</p>"
    #     body["html"]   => "<p style=\"margin:0 0 16px;font-family:'Iowan Old
    #                        Style',…;font-size:17px;line-height:1.55;
    #                        color:#15211d\">probe copy</p>"
    #
    # This path persists via direct Repo writes (`persist_blocks_doc/9`), so
    # unlike the document leg it is NOT rescued downstream by
    # `Writer.maybe_project_document_content/2` — the email bytes really landed.
    render_opts =
      Labels.render_opts(dataset, scope)
      |> Map.put(:preview, blocks_doc_preview_opts(type, slug, scope))
      |> Map.put(:style, :article)

    Projection.project(content, blocks, render_opts)
  end

  defp maybe_project(content, _blocks, _type, _dataset, _slug, _scope), do: content

  # Paper-only preview shape (a reader URL exists) vs. the generic non-paper
  # blocks-doc shape (no canonical reader page — mirrors `doc_project_opts/3`,
  # the same split `apply_document_block_op/5` already draws for arbitrary
  # Expectation-bearing documents).
  defp blocks_doc_preview_opts(@paper_type, slug, scope), do: paper_preview_opts(slug, scope)

  defp blocks_doc_preview_opts(type, _slug, scope) do
    %{media_resolver: Preview.media_resolver(scope), doc_type: type}
  end

  # The :preview sub-map injected into render_opts so Projection.project derives a
  # rich content["preview"] card for a paper: the media resolver (bound to this
  # paper's tenancy scope so it never resolves another tenant's blob), the reader
  # url, and the raw doctype. Render.render_blocks ignores the extra key.
  defp paper_preview_opts(slug, scope) do
    %{
      media_resolver: Preview.media_resolver(scope),
      url: "/papers/#{slug}",
      doc_type: @paper_type
    }
  end

  # Add the paper :preview sub-map to an already-built render_opts (the streaming
  # block-op paths, where `doc` carries the tenancy scope).
  defp project_opts(render_opts, slug, %Document{} = doc) do
    scope = [workspace_id: doc.workspace_id, project_id: doc.project_id]
    Map.put(render_opts, :preview, paper_preview_opts(slug, scope))
  end

  # The :preview sub-map for a generic (non-paper) block-bearing document — the
  # raw doctype + a scope-bound media resolver. No reader url (arbitrary doctypes
  # have no canonical public page); Preview leaves manifest["url"] nil.
  defp doc_project_opts(dataset, type, %Document{} = doc) do
    scope = [workspace_id: doc.workspace_id, project_id: doc.project_id]

    # task-c46967eb3dc49e77: names `:article` rather than letting
    # `Render.render_block/2`'s `Map.get(opts, :style, :email)` default pick.
    # Defence in depth on THIS leg — `apply_document_block_op/5` finishes
    # through `Content.upsert_document/4`, whose
    # `Writer.maybe_project_document_content/2` re-projects the same keys on
    # the already-`:article` `doc_render_opts/3`, so nothing persisted here was
    # ever wrong. The paper leg above (`maybe_project/6`) is the one that was.
    Labels.render_opts(dataset, scope)
    |> Map.put(:preview, %{
      media_resolver: Preview.media_resolver(scope),
      doc_type: type
    })
    |> Map.put(:style, :article)
  end

  # Tenancy scope for the media resolver: an explicit caller scope wins, else the
  # existing row's scope, else global (nil) — matching how the paper row itself
  # resolves its workspace/project.
  defp paper_scope(existing, scope_attrs) do
    [
      workspace_id: scope_attrs["workspace_id"] || (existing && existing.workspace_id),
      project_id: scope_attrs["project_id"] || (existing && existing.project_id)
    ]
  end

  # Field-encryption CHOKEPOINT, `type`-generalized (session-handoff Task 2)
  # off the original paper-only `encrypt_paper_blocks/3`. Encrypt the bound
  # block values of any schema field marked `encrypted: true` by routing the
  # block list through `Encryption.encrypt_marked/4` (its `encrypt_bound_blocks`
  # half), against `type`'s OWN schema — a session write checks the SESSION
  # schema's `encrypted: true` fields (today: none — a byte-identical no-op),
  # never silently checking the paper schema. This is the SAME chokepoint
  # Writer uses; running it on the block list BEFORE render+projection means:
  # (a) the body_html cache and delta fragments redact the encrypted field
  # (Render redacts envelope values) instead of leaking plaintext, and (b)
  # Projection copies the resulting envelope into content[fieldName], so
  # content is ciphertext-at-rest by the changeset. Idempotent (re-encrypting
  # an envelope is a no-op) and a byte-identical no-op when `type`'s schema
  # marks nothing encrypted or this is an HTML-only (block-less) write.
  # Returns `{:ok, blocks}` (the encrypted block list) or `{:error, reason}` when
  # a marked-encrypted bound block cannot be sealed (HIGH-3, fail closed) — the
  # blocks-doc write paths surface the error instead of persisting
  # plaintext-at-rest. `workspace_id` attributes the DEK (charter D51-D54): it
  # MUST be the row's workspace so a later `reveal_fields` resolves the same
  # (workspace_id, scope) DEK that sealed the bound block. `nil` (an unscoped
  # write) → the NULL-workspace DEK.
  defp encrypt_blocks_for_type(type, blocks, dataset, workspace_id)
       when is_list(blocks) and is_binary(dataset) do
    case Encryption.encrypt_marked(%{"blocks" => blocks}, type, dataset, workspace_id) do
      {:ok, %{"blocks" => encrypted}} -> {:ok, encrypted}
      {:ok, _} -> {:ok, blocks}
      {:error, _} = err -> err
    end
  end

  defp encrypt_blocks_for_type(_type, blocks, _dataset, _workspace_id), do: {:ok, blocks}

  # Paper-only alias, kept for the streaming block-op paths
  # (`apply_paper_block_op/4`, `apply_paper_block_ops/4` — both out of this
  # task's scope) that still call it by its original name/arity.
  defp encrypt_paper_blocks(blocks, dataset, workspace_id),
    do: encrypt_blocks_for_type(@paper_type, blocks, dataset, workspace_id)

  # Next monotonic streaming rev for a paper. Starts at 1 for a fresh paper;
  # increments the stored integer otherwise.
  defp paper_next_rev(nil), do: 1

  defp paper_next_rev(%Document{content: content}) when is_map(content) do
    case Map.get(content, "rev") do
      n when is_integer(n) -> n + 1
      _ -> 1
    end
  end

  defp paper_next_rev(_), do: 1

  # The document's opaque string `rev` (mutation-spine version), distinct from
  # the integer streaming `content["rev"]`. Pure helper duplicated here so the
  # Papers module owns its own row-rev generation without coupling to the hub's
  # private `generate_rev/0` (concern E, Step 13).
  defp generate_rev do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
