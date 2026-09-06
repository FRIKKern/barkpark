defmodule BarkparkWeb.TasksController.Params do
  @moduledoc false
  # Param parsing, coercion, validation, query-filter, and render-shape helpers
  # extracted from `BarkparkWeb.TasksController` to keep the controller focused
  # on action control-flow. Every function here is pure-ish: it either parses a
  # raw param into a typed value, coerces a body field, applies a tenancy /
  # filter clause to an Ecto query, or renders a Document into the bd-compatible
  # shape the `bp task` CLI consumes. No `conn`, no action routing — the controller calls
  # these as `Params.<name>(...)`.

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Repo
  alias Barkpark.Content.{CallerContext, Document, DraftId, Envelope}
  alias Barkpark.Content.Scope
  alias Barkpark.Tasks.{Close, Criteria, QueueGate}
  alias Barkpark.Tasks.Edge
  alias Barkpark.Tasks.Query, as: TaskQuery

  # How much of a displaced disposition_reason a refusal envelope inlines. The
  # longest note measured on the live ledger is 1228 characters; a refusal that
  # quoted one whole would bury the remedy it is trying to hand over.
  @note_excerpt_limit 400

  # ─── Query filters (index / prime / lookup) ─────────────────────────────
  #
  # The content-jsonb filters (kind / lifecycle / parent / parent_id / label /
  # dataset / claim / order) live in `Barkpark.Tasks.Query` — ONE owner shared
  # with the live-plan fetcher so the semantics can't drift. These are thin
  # delegations. Tenancy (workspace / project / event_workspace) stays here as
  # a Scope wrapper.

  defdelegate maybe_filter_claim_worker(query, worker), to: TaskQuery

  # Tenancy: route through the ONE shared, fail-CLOSED helper (a nil
  # workspace_id yields zero rows, never every tenant's events) — the same
  # `Scope.scope_to_workspace/3` the ready-queue and claim paths use. HTTP
  # callers always carry a real workspace (Default scope via AssignDefaultScope),
  # so scoped requests are unchanged; only an internal nil-scoped caller flips
  # from all-tenant (fail-OPEN) to zero rows (fail-CLOSED, the safe default).
  def maybe_filter_event_workspace(query, ws_id),
    do: Scope.scope_to_workspace(query, ws_id, nil)

  # `parent`/`parent_id` are the prefix-agnostic child-of-task edge; `kind` /
  # `lifecycle` / `label` / `order` behave as documented in `Barkpark.Tasks.Query`.
  defdelegate maybe_filter_type(query, t), to: TaskQuery
  defdelegate maybe_filter_kind(query, k), to: TaskQuery
  defdelegate maybe_filter_lifecycle(query, s), to: TaskQuery
  defdelegate maybe_filter_parent(query, p), to: TaskQuery
  defdelegate maybe_filter_parent_id(query, p), to: TaskQuery
  defdelegate apply_index_order(query, parent), to: TaskQuery

  # tt5: `label=<exact>` — keep only docs whose `content.labels` JSON array
  # CONTAINS the exact label string. Backs the `bp task` label filter and any
  # arbitrary label → find every task holding a given claim. Tenancy-scoped via
  # the same workspace/project filters as the rest of the pipeline.
  #
  # Containment uses the scalar-membership form `labels @> to_jsonb(<text>)`,
  # NOT array-vs-array `labels @> '["x"]'::jsonb`. The stored jsonb arrays
  # (written by the W7 mirror) don't match a freshly-parsed array literal under
  # `@>` array containment, but scalar membership — the canonical "is this
  # element in the array" test — matches reliably (verified against the live
  # store). `to_jsonb(text)` builds the scalar jsonb operand inside Postgres,
  # so no client-side JSON encoding of the needle is needed.
  defdelegate maybe_filter_label(query, label), to: TaskQuery

  # Dataset discriminator (gap #4 fix). Without it a doc_id that collides across
  # DATASETS in one workspace/project resolves by drafts-CASE ordering alone —
  # effectively arbitrary across datasets, rooting the graph on the wrong doc and
  # silently dictating the traversal dataset via root.dataset. Mirrors add_edge's
  # resolve_doc_pk dataset branch and Graph.resolve_pk. v1 graph roots are
  # dataset-scoped to the optional `dataset` param (default: all datasets in
  # scope, published-preferred first row).
  defdelegate maybe_filter_dataset(query, dataset), to: TaskQuery

  # Tenancy boundary: route the workspace clause through the ONE shared,
  # fail-CLOSED helper (`Scope.scope_to_workspace/3`) — the SAME semantic the
  # ready-queue (Queue.ready_query) and claim (Tasks.Claim) paths now use, so
  # the tasks resource has a single nil-scope rule instead of three divergent
  # ones. A nil workspace_id yields zero rows (fail-CLOSED), never every
  # tenant's rows (the old fail-OPEN accident). HTTP callers always carry a real
  # workspace (Default scope via AssignDefaultScope), so scoped requests are
  # byte-identical; project narrowing rides the sibling helper below (applied
  # after this one, so the pair == scope_to_workspace(q, ws, project)).
  def maybe_filter_workspace(query, ws_id),
    do: Scope.scope_to_workspace(query, ws_id, nil)

  # Project is a leaf narrowing applied AFTER the workspace clause above; a nil
  # project means "do not narrow by project" (workspace-only scope), NOT "all
  # tenants" — the tenant boundary is already enforced by the workspace clause.
  def maybe_filter_project(query, nil), do: query

  def maybe_filter_project(query, p_id),
    do: from(d in query, where: d.project_id == ^p_id)

  # ─── Graph param parsing ────────────────────────────────────────────────

  def parse_direction("out"), do: :out
  def parse_direction("in"), do: :in
  def parse_direction(_), do: :both

  # perspective=drafts OR ?drafts=true → :drafts (token-gated, live extract).
  # Anything else → :published (the materialised default).
  #
  # DELIBERATELY NOT MERGED into `BarkparkWeb.AnonPerspective.parse/1` (the
  # canonical lenient parser). Two real differences, either of which a collapse
  # would silently destroy: this one takes the whole PARAMS MAP because it also
  # honours the `?drafts=true` alias, and its value set is NARROWER — the graph
  # surface declares `published | drafts`, with no `raw`. Merging would either
  # drop a working alias or widen the graph route to a perspective its manifest
  # entry does not offer. The strictness the fork used to cost is now bought
  # separately: `graph_show/2` refuses an unsupported value through
  # `BarkparkWeb.ReadPerspective` before this is reached.
  def parse_perspective(%{"perspective" => "drafts"}), do: :drafts
  def parse_perspective(%{"drafts" => v}) when v in ["true", "1", true], do: :drafts
  def parse_perspective(_), do: :published

  # Comma-separated query value → list of non-empty strings, or nil when absent.
  def csv_list(nil), do: nil

  def csv_list(v) when is_binary(v) do
    case v
         |> String.split(",", trim: true)
         |> Enum.map(&String.trim/1)
         |> Enum.reject(&(&1 == "")) do
      [] -> nil
      list -> list
    end
  end

  def csv_list(_), do: nil

  # ─── Body coercion ──────────────────────────────────────────────────────

  # Coerce a body field into a list of strings. Accepts a list (filtering
  # non-strings), a bare string (wrapped), or nil/anything-else (→ []).
  def string_list(v) when is_list(v), do: Enum.filter(v, &is_binary/1)
  def string_list(v) when is_binary(v), do: [v]
  def string_list(_), do: []

  # content.labels is a free-form JSON array; coerce missing / non-list to [].
  def labels_of(%{"labels" => labels}) when is_list(labels), do: labels
  def labels_of(_), do: []

  # content.papers is a JSON array of paper slugs; coerce missing / non-list to [].
  def papers_of(%{"papers" => papers}) when is_list(papers), do: papers
  def papers_of(_), do: []

  # Task 5 (session-handoff): content.sessions is a session-doc-id array,
  # written via /v1/tasks/:id/sessions. Mirrors papers_of/1 byte-for-byte.
  def sessions_of(%{"sessions" => sessions}) when is_list(sessions), do: sessions
  def sessions_of(_), do: []

  # ─── Render / shape ─────────────────────────────────────────────────────

  # axi-s1 (R1): parse the optional `?view=` request param into a render view.
  # ONLY the exact string "brief" opts in; absent, unknown, or non-string
  # values (Phoenix array/map params) all fall back to :full — the server
  # default STAYS full so SDK/Studio/taskboard consumers are untouched.
  def parse_view("brief"), do: :brief
  def parse_view(_), do: :full

  # Render a Document into the bd-compatible shape the `bp task` CLI consumes.
  # Keep the field set tight enough that it still maps cleanly onto the
  # bd-compatible `show` JSON shape, broad enough that list callers don't
  # lose information (priority, assignee, content.kind for filtering).
  #
  # axi-s1 (R1/R2): grows a `view` argument.
  #
  #   * `:full` (default) — the historical shape, with ONE de-dup: the
  #     `content` echo drops its `"claim"` key. The top-level `claim` is the
  #     single wire copy (every Go consumer + `TaskResolver.worker_of/1` read
  #     top-level; `content.claim` had zero HTTP-envelope readers). DB storage
  #     `content["claim"]` is untouched — it stays the write-path source of
  #     truth; only the response echo is de-duplicated.
  #   * `:brief` — the AXI brief card v2 (charter decisions 3 + 15/16): no
  #     content echo, no work digests, claim cut to {worker, epoch, now}, and
  #     the nine measured diet cuts below. `child_count` is NOT set here —
  #     list callers add it via `render_brief/2` from one batched query.
  # ─── field-visibility seal (fail-closed) ────────────────────────────────
  #
  # Redact a task document's `content` through the canonical Envelope
  # field-visibility chokepoint under the request's caller BEFORE it is rendered
  # into any wire shape. A `private` / `owner_only` / `readable_by` field the
  # caller may not see — and any encrypted-ciphertext field — is DROPPED from
  # `content`, so it can never reach the `content` echo NOR any top-level key
  # `render_doc` / `render_brief` / `render_doc_with_counts` / `child_summary`
  # promote off it (they all read `doc.content`).
  #
  # This is the missing sibling of the already-sealed Tasks read surfaces
  # (`Barkpark.Tasks.Query`'s measure/agg branch → `Envelope.field_readable?`,
  # and the board peek panel). This JSON echo never adopted the same seal.
  # LATENT today — a full schema scan found no task field declaring visibility,
  # so `redact/4` returns `content` unchanged and every response is
  # byte-identical for the already-readable case. It fails CLOSED the instant a
  # task field declares visibility: the field is redacted, never leaked.
  #
  # `caller` is the request principal (`CallerContext.from_conn/1`): an admin
  # token sees all (no redaction); a non-admin token / anonymous caller is
  # subject to the field's declared visibility. `schema` is the resolved "task"
  # `%SchemaDefinition{}` (nil ⇒ only encrypted ciphertext is dropped; declared
  # visibility needs the schema present). `Envelope.redact/4` is the same
  # `redact_by_field_visibility` chokepoint as `Envelope.render/3`.
  @spec seal(Document.t(), CallerContext.t(), term()) :: Document.t()
  def seal(%Document{} = doc, %CallerContext{} = caller, schema) do
    redacted = Envelope.redact(doc.content || %{}, schema, caller, Map.get(doc, :owner_id))
    %{doc | content: redacted}
  end

  def render_doc(doc, view \\ :full)

  def render_doc(%Document{} = doc, :full) do
    content = doc.content || %{}

    %{
      id: doc.id,
      doc_id: doc.doc_id,
      title: doc.title,
      status: doc.status,
      type: doc.type,
      dataset: doc.dataset,
      rev: doc.rev,
      kind: Map.get(content, "kind"),
      lifecycle_status: Map.get(content, "lifecycle_status"),
      priority: Map.get(content, "priority"),
      assignee: Map.get(content, "assignee"),
      parent_id: Map.get(content, "parent_id"),
      execution_policy: Map.get(content, "execution_policy"),
      queue_gate: Map.get(content, "queue_gate"),
      execution_class: QueueGate.execution_class(content),
      claim: Map.get(content, "claim"),
      # tt5: surface content.labels at the top level so a client's `.labels[]`
      # (e.g. `bp task show`'s label view + the `label=` list filter) works
      # end-to-end. Callers read `doc.labels`; without this they always saw [].
      labels: labels_of(content),
      # Phase A: surface content.papers at the top level the same way labels
      # are, so callers can read `doc.papers[]` without digging into content.
      papers: papers_of(content),
      # Task 5 (session-handoff): surface content.sessions the same way papers
      # are, so callers can read `doc.sessions[]` without digging into content.
      sessions: sessions_of(content),
      content: Map.delete(content, "claim"),
      inserted_at: doc.inserted_at,
      updated_at: doc.updated_at
    }
    # lvw-t6: {met,total} over content.acceptance_criteria — computed by the
    # single canonical owner (Barkpark.Tasks.Criteria). Key OMITTED when
    # criteria are absent/empty (wire §4: omit the segment, never "0/0").
    |> put_criteria_progress(content)
  end

  # axi-w2-s2 (charter decisions 15+16): brief card v2 — the nine measured
  # cuts, ENTIRELY inside the brief path (:full untouched):
  #
  #   (a) nil/absent keys are omitted wire-wide (see `prune_nils/1`);
  #   (b) the internal uuid `id` is dropped — `doc_id` is the only address any
  #       `bp` verb takes;
  #   (c) `claim` is emitted only when it carries SIGNAL (worker != nil OR a
  #       now-line) — no Go consumer reads claim.epoch pre-claim;
  #   (d) `claim.now.text` capped at #{@brief_now_text_limit} graphemes with a
  #       bare … marker (grapheme-safe — never splits a cluster);
  #   (e) `title` capped at #{@brief_title_limit} graphemes, same marker;
  #   (f) seconds-precision timestamps (`updated_at`, `claim.now.ts`);
  #   (g) `lifecycle_status` omitted when "open" — NEVER unconditionally:
  #       queue.ex admits open|blocked and blocked must survive on the card as
  #       the actionable exception;
  #   (h) `status` omitted when "published" (the task-contract steady state);
  #   (i) the criteria_met/criteria_total pair omitted when there are no
  #       criteria — adopting full view's own put_criteria_progress omission
  #       law (wire §4: omit the segment, never "0/0").
  #
  # Truncation honesty (charter law 2): the bare … is legal because doc_id is
  # on every card AND list responses append ONE top-level help[] line when any
  # truncation fired — see `maybe_put_brief_truncation_help/3`.
  @brief_title_limit 96
  @brief_now_text_limit 160
  @brief_truncation_help "truncated fields end with …; full record via bp task get <doc_id>"

  def render_doc(%Document{} = doc, :brief) do
    content = doc.content || %{}

    %{
      doc_id: doc.doc_id,
      title: truncate_graphemes(doc.title, @brief_title_limit),
      priority: Map.get(content, "priority"),
      assignee: Map.get(content, "assignee"),
      parent_id: Map.get(content, "parent_id"),
      updated_at: brief_timestamp(doc.updated_at)
    }
    |> put_unless(:status, doc.status, "published")
    |> put_unless(:lifecycle_status, Map.get(content, "lifecycle_status"), "open")
    |> put_brief_criteria(content)
    |> put_brief_labels(content)
    |> put_brief_engagement(content)
    |> put_brief_disposition(content)
    |> Map.put(:claim, brief_claim(Map.get(content, "claim")))
    |> prune_nils()
  end

  # LABELS ON THE BRIEF CARD (task-14eac58b39fd3692), additive and pruned.
  #
  # The brief card is a deliberate payload diet, so a new key needs a reason
  # this one has: WITHOUT labels the card cannot be reasoned about at all by
  # the readers that matter. A row carrying `landed:pr-NNNNN@sha` looks
  # identical on the wire to one that never shipped, so a lead reads met:false
  # criteria as untouched work and dispatches a builder that comes back
  # "already fixed" — the burn this row was filed for. Measured 2026-09-05:
  # 21 of 1,658 rows in `bp task ready` carry a landed:pr-* label, nine of them
  # at ZERO criteria met, and a census that filtered the ready card by label
  # returned a confident 0 because the field could never be present.
  #
  # ADDITIVE BY CONSTRUCTION: absent or empty labels prune away, so every card
  # that carried no labels is byte-identical to before. Labels are short tokens,
  # not prose, so no truncation arm is needed and charter law 2's help[] line is
  # unaffected.
  defp put_brief_labels(map, content) do
    case Map.get(content, "labels") do
      [_ | _] = labels -> Map.put(map, :labels, labels)
      _ -> map
    end
  end

  # Brief claim v2 = {worker, epoch, now} only — the identity + fencing +
  # now-line a board or resuming agent needs. work_digest / work_field_digests /
  # ts_iso / execution_policy are full-view (and `task get`) detail. A claim
  # with NEITHER a worker NOR a now-line carries no signal a list reader acts
  # on (cut c) → nil, which prune_nils/1 then omits from the card.
  defp brief_claim(%{} = claim) do
    worker = Map.get(claim, "worker")
    now = Map.get(claim, "now")

    if is_nil(worker) and is_nil(now) do
      nil
    else
      %{"worker" => worker, "epoch" => Map.get(claim, "epoch"), "now" => brief_now(now)}
      |> prune_nils()
    end
  end

  defp brief_claim(_), do: nil

  # The now-line rides the card with its text capped (cut d) and its timestamp
  # trimmed to seconds (cut f); `criterion` (a small int) survives untouched.
  defp brief_now(%{} = now) do
    now
    |> Map.take(["text", "ts", "criterion"])
    |> Map.update("text", nil, &truncate_graphemes(&1, @brief_now_text_limit))
    |> Map.update("ts", nil, &brief_timestamp/1)
    |> prune_nils()
  end

  defp brief_now(_), do: nil

  # Cut (i): same omission law as full view's put_criteria_progress —
  # Criteria.progress/1 is nil for absent/empty criteria, so a 0/0 pair never
  # reaches the wire.
  defp put_brief_criteria(map, content) do
    case Criteria.progress(content) do
      %{met: met, total: total} when total > 0 ->
        map |> Map.put(:criteria_met, met) |> Map.put(:criteria_total, total)

      _ ->
        map
    end
  end

  # tlv-s6 (TLV charter D15): the engagement companion — the thought-state
  # object map {object, holder, ts, note} that considering/researching rows
  # carry — rides the brief card as an ADDITIVE 14th key, present only when
  # the doc carries a non-empty map (same omission law as criteria_progress:
  # omit the segment, never an empty object). The 13 frozen brief fields are
  # untouched; lifecycle_status (already on the card) carries the thought
  # states for free via put_unless/4 above.
  defp put_brief_engagement(map, content) do
    case Map.get(content, "engagement") do
      %{} = engagement when map_size(engagement) > 0 -> Map.put(map, :engagement, engagement)
      _ -> map
    end
  end

  # pds-w27: the ADJUDICATION TERM rides the brief card, same additive law as
  # put_brief_engagement/2 above — present only when the row carries a term,
  # omitted (never "" and never null) when it does not, so the exact-key-set
  # contract on a minimal open row is untouched.
  #
  # THE TERM ONLY, and that is MEASURED, not taste. The hostile 50-card
  # tripwire below params' own tests had 2080 B of headroom under its 30,720 B
  # ceiling. Marginal cost over 50 cards:
  #
  #   * `,"disposition":"parked"`   = 23 B × 50 = 1150 B — fits, ~930 B spare.
  #   * `,"reopen_trigger":""`      = 20 B × 50 = 1000 B MORE, with a
  #     ZERO-LENGTH value: 1150 + 1000 = 2150 B > 2080 B. The trigger overflows
  #     the ceiling before a single character of content — no grapheme cap can
  #     rescue it, the cap would have to be negative.
  #   * `disposition_reason` averages 753 B (max 1612 B) per row — the worst-50
  #     full triple is 72,232 B, 34.7× the headroom.
  #
  # Both omitted companions already ride the FULL view (render_doc(_, :full) is
  # a whole-content passthrough): `bp task get <doc_id>` is the escape hatch
  # AXI charter law 2 asks for.
  #
  # NOTE for whoever caps a future brief field: brief_truncated?/1 below
  # inspects ONLY `title` and `claim.now.text`, and Tasks.Stage caps NEITHER
  # `reopen_trigger` NOR `disposition_reason`. A capped field shipped without a
  # third clause there truncates SILENTLY — charter law 2 violated by omission.
  # (Free reach: internal/cli/mcp_tasks.go forces view=brief on both its list
  # and prime reads, so the MCP agent surface gains this term with no change.)
  defp put_brief_disposition(map, content) do
    case Map.get(content, "disposition") do
      term when is_binary(term) and term != "" -> Map.put(map, :disposition, term)
      _ -> map
    end
  end

  # Cut (g)/(h): keep the key only when the value differs from the steady
  # state the reader already assumes; nil stays nil for prune_nils/1.
  defp put_unless(map, _key, steady, steady), do: map
  defp put_unless(map, key, value, _steady), do: Map.put(map, key, value)

  # Cut (a): a nil value IS absence — drop the key instead of shipping
  # `"assignee":null` fifty times per page.
  defp prune_nils(map), do: Map.reject(map, fn {_k, v} -> is_nil(v) end)

  # Cut (d)/(e): grapheme-safe cap with a bare … marker. The truncated value
  # NEVER exceeds `limit` graphemes (limit - 1 content + the marker), and a
  # multi-byte cluster (emoji, combining accents) is never split.
  defp truncate_graphemes(s, limit) when is_binary(s) do
    if String.length(s) > limit do
      s |> String.graphemes() |> Enum.take(limit - 1) |> Enum.join() |> Kernel.<>("…")
    else
      s
    end
  end

  defp truncate_graphemes(other, _limit), do: other

  # Cut (f): seconds precision. Structs are truncated (Jason renders them
  # ISO8601 without the fractional part); the now-line's ts is a stored
  # ISO8601 STRING, so its fractional seconds are trimmed textually.
  defp brief_timestamp(%DateTime{} = dt), do: DateTime.truncate(dt, :second)
  defp brief_timestamp(%NaiveDateTime{} = dt), do: NaiveDateTime.truncate(dt, :second)

  defp brief_timestamp(ts) when is_binary(ts),
    do: String.replace(ts, ~r/\.\d+(?=Z$|[+-]\d\d:?\d\d$)/, "")

  defp brief_timestamp(other), do: other

  # axi-s1: the brief LIST card = brief render_doc + `child_count` from
  # one batched grouped query (`batch_child_counts/2`) — never per-row.
  def render_brief(%Document{} = doc, child_counts) do
    doc
    |> render_doc(:brief)
    |> Map.put(:child_count, Map.get(child_counts, strip_draft_prefix(doc.doc_id), 0))
  end

  # ─── Brief truncation honesty (axi-w2-s2, charter law 2) ─────────────────
  #
  # When any card on a brief LIST response lost bytes to the … caps above, the
  # response carries ONE top-level help[] line naming the escape hatch. No
  # truncation → no line (an always-on banner would train readers to ignore
  # it). Checked against the RAW docs — the same inputs the render saw — so
  # the predicate can never drift from what actually got cut. Full view never
  # truncates, so it never carries the line.
  @doc """
  The `page` block every `/v1/tasks` list envelope carries: the window the
  server actually served.

  `has_more` is deliberately the CHEAP predicate `returned == limit` and not a
  `COUNT(*)`. This whole change exists because one unbounded read over
  `documents` was expensive; paying for a second scan just to narrate the first
  would reintroduce the cost under a new name. The predicate is exact in the
  direction that matters — `returned < limit` PROVES the page is the last one —
  and over-reports only on an exactly-full final page, which tells a caller to
  look again and find nothing. A reader that needs an exact total asks for one
  (`bp task ls --all`, which pages by offset with a lookahead anchor).

  `limit` is the EFFECTIVE limit after clamping, so `?limit=5000` reports 1000:
  the number the caller asked for is not the number they got, and this field is
  about what they got.
  """
  def page_meta(docs, page_opts) when is_list(docs) do
    limit = Keyword.fetch!(page_opts, :limit)
    returned = length(docs)

    %{
      limit: limit,
      offset: Keyword.fetch!(page_opts, :offset),
      returned: returned,
      has_more: returned == limit
    }
  end

  def maybe_put_brief_truncation_help(base, _docs, :full), do: base

  def maybe_put_brief_truncation_help(base, docs, :brief) do
    if Enum.any?(docs, &brief_truncated?/1),
      do: Map.put(base, :help, [@brief_truncation_help]),
      else: base
  end

  defp brief_truncated?(%Document{} = doc) do
    over_limit?(doc.title, @brief_title_limit) or
      over_limit?(get_in(doc.content || %{}, ["claim", "now", "text"]), @brief_now_text_limit)
  end

  defp over_limit?(s, limit) when is_binary(s), do: String.length(s) > limit
  defp over_limit?(_, _), do: false

  defp put_criteria_progress(map, content) do
    case Criteria.progress(content) do
      nil -> map
      progress -> Map.put(map, :criteria_progress, progress)
    end
  end

  # w7-08c (paper-y1c): batch edge-count maps so a list response
  # (ready/index) doesn't N+1 the task_edges table.
  #
  # Returns %{doc_id => {dependency_count, dependent_count}}. Single query
  # per side (outbound / inbound) joined on the candidate ids — preserves
  # the controller's tenancy contract by deriving ids from the already-
  # tenancy-scoped `docs` list.
  def batch_edge_counts([]), do: %{}

  def batch_edge_counts(docs) do
    ids = Enum.map(docs, & &1.id)

    # Outbound edges: from_id ∈ ids → this row depends on N blockers
    # (its dependency_count). Use a single grouped query.
    out_counts =
      from(e in Edge,
        where: e.from_id in ^ids,
        group_by: e.from_id,
        select: {e.from_id, count(e.id)}
      )
      |> Repo.all()
      |> Map.new()

    # Inbound edges: to_id ∈ ids → N rows depend on this one
    # (its dependent_count).
    in_counts =
      from(e in Edge,
        where: e.to_id in ^ids,
        group_by: e.to_id,
        select: {e.to_id, count(e.id)}
      )
      |> Repo.all()
      |> Map.new()

    Map.new(docs, fn d ->
      {d.id, {Map.get(out_counts, d.id, 0), Map.get(in_counts, d.id, 0)}}
    end)
  end

  # axi-s1 (R1): batch child-count map for brief list cards, mirroring
  # batch_edge_counts/1 — ONE grouped query over `type:"task"` rows keyed by
  # the drafts-stripped `content->>'parent_id'` (the SAME prefix-agnostic
  # match `maybe_filter_parent_id/2` / show's child rail use), so a list
  # response never N+1s the children lookup.
  #
  # Tenancy: the CHILD rows are filtered by the caller's workspace/project
  # scope — the same filters `show`'s child_tasks/2 applies. An unscoped copy
  # would count another tenant's children under a shared parent slug: a
  # cross-tenant existence-count leak.
  #
  # Returns %{drafts-stripped parent doc_id => child_count}; parents with no
  # children are simply absent (callers default to 0).
  #
  # dr-w34-s4 (review): TWIN COLLAPSE APPLIES HERE TOO, and this is the FIFTH
  # producer of a child count — the one the slice's brief called the "only
  # producer" list and missed. It groups on the SAME drafts-stripped
  # `parent_id` key that `maybe_filter_parent_id/2` matches on, so a
  # `drafts.<id>` shadow child is guaranteed to fall in its published parent's
  # bucket and count +2 exactly as `child_tasks/2` did. Without the collapse
  # here, `bp task get <epic>` and `bp task ls --view=brief` report DIFFERENT
  # child counts for the same epic — one number with two meanings, which is the
  # defect this wave exists to remove rather than relocate.
  def batch_child_counts(docs, scope \\ [])
  def batch_child_counts([], _scope), do: %{}

  def batch_child_counts(docs, scope) do
    parent_keys =
      docs
      |> Enum.map(&strip_draft_prefix(&1.doc_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case parent_keys do
      [] ->
        %{}

      keys ->
        from(d in Document,
          where: d.type == "task",
          where:
            fragment("regexp_replace(?->>'parent_id', '^drafts\\.', '')", d.content) in ^keys,
          group_by: fragment("regexp_replace(?->>'parent_id', '^drafts\\.', '')", d.content),
          select:
            {fragment("regexp_replace(?->>'parent_id', '^drafts\\.', '')", d.content),
             count(d.id)}
        )
        |> TaskQuery.collapse_twins()
        |> maybe_filter_workspace(Keyword.get(scope, :workspace_id))
        |> maybe_filter_project(Keyword.get(scope, :project_id))
        |> Repo.all()
        |> Map.new()
    end
  end

  # The prefix-agnostic doc_id key the parent-edge queries group on — the
  # Elixir-side twin of the SQL `regexp_replace(…, '^drafts\.', '')`. Delegates
  # the rule itself to DraftId.published_id/1 (the canonical owner); this
  # wrapper adds only the nil-safety these call sites need — DraftId's own
  # published_id/1 requires a binary and raises on nil.
  def strip_draft_prefix(nil), do: nil

  def strip_draft_prefix(doc_id) when is_binary(doc_id),
    do: DraftId.published_id(doc_id)

  # Augment the base render_doc map with the four count fields the
  # `bp task` list/ready shapes carry (dependency_count + dependent_count
  # from batch_edge_counts; comment_count fixed at 0 until the comment
  # substrate ships — TODO: wire when comment substrate exists;
  # `child_count` from `batch_child_counts/2`, the SAME producer the brief
  # card uses).
  #
  # ── ONE FIELD, ONE PLACE (task-3e0eda896a247776) ────────────────────────
  #
  # `child_count` used to answer THREE different things depending on which
  # door a reader walked through:
  #
  #     GET /v1/tasks?view=brief   docs[].child_count        the real number
  #     GET /v1/tasks   (default)  ABSENT                    -> reads as 0
  #     GET /v1/tasks/:doc_id      TOP-LEVEL child_count,    -> doc.child_count
  #                                absent from `doc`            reads as 0
  #
  # The fleet's standing triage heuristic is "skip a row with a high
  # child_count — an epic parent is not lane-sized". Two of the three doors
  # answer 0 for a `doc.child_count` read, so an epic ROOT passes that filter
  # as a leaf: measured on guerrilla, `task-57451a6ce0a0505e` carries 189
  # children and its 160 shards were swept toward a bulk-cancel list twice on
  # exactly this misread. Emitting the field on the full card and INSIDE `doc`
  # (`show` keeps its top-level copy for the readers already on it) makes
  # `doc.child_count` one number with one meaning on every reader.
  #
  # `child_counts` defaults to `%{}` so the pre-existing arity-2 call sites
  # keep compiling and keep their exact shape plus a `child_count: 0`; every
  # caller inside this app passes the real map.
  def render_doc_with_counts(%Document{} = doc, counts, child_counts \\ %{}) do
    {dep_count, dependent_count} = Map.get(counts, doc.id, {0, 0})

    doc
    |> render_doc()
    |> Map.put(:dependency_count, dep_count)
    |> Map.put(:dependent_count, dependent_count)
    |> Map.put(:comment_count, 0)
    |> Map.put(:child_count, Map.get(child_counts, strip_draft_prefix(doc.doc_id), 0))
  end

  # C2: a lightweight child summary — just enough to render the rail without
  # the full render_doc payload or a recursive child fetch (one level only).
  def child_summary(%Document{} = doc) do
    content = doc.content || %{}

    %{
      doc_id: doc.doc_id,
      title: doc.title,
      lifecycle_status: Map.get(content, "lifecycle_status"),
      execution_class: QueueGate.execution_class(content),
      inserted_at: doc.inserted_at
    }
    # Same omit-when-absent contract as render_doc — a parent's rail shows
    # each child's criteria progress without a per-child fetch.
    |> put_criteria_progress(content)
  end

  # ─── Opt building / int parsing / validation ────────────────────────────

  def put_opt(opts, _key, nil), do: opts
  def put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  def parse_ready_order(nil), do: {:ok, nil}
  def parse_ready_order(""), do: {:ok, nil}
  def parse_ready_order("closure_nearest"), do: {:ok, :closure_nearest}
  def parse_ready_order(_), do: {:error, :invalid_ready_order}

  # Public claim requests may supply only the highest-precedence explicit
  # override. Session/user/provider defaults are trusted server-side Claim opts,
  # not client-asserted provenance.
  def execution_policy_opts(params) do
    []
    |> put_opt(:execution_policy_override, Map.get(params, "execution_policy_override"))
  end

  def fetch_string(params, key) do
    case Map.get(params, key) do
      v when is_binary(v) and byte_size(v) > 0 -> {:ok, v}
      _ -> {:error, :missing, key}
    end
  end

  def fetch_int(params, key) do
    case Map.get(params, key) do
      n when is_integer(n) -> {:ok, n}
      s when is_binary(s) -> parse_int_strict(s, key)
      _ -> {:error, :missing, key}
    end
  end

  def parse_int_strict(s, key) do
    case Integer.parse(s) do
      {n, ""} -> {:ok, n}
      _ -> {:error, :missing, key}
    end
  end

  def parse_int(nil, default), do: default

  def parse_int(v, default) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      _ -> default
    end
  end

  def parse_int(v, _default) when is_integer(v), do: v

  # Phoenix parses `?limit[]=5` into a list and `?limit[a]=b` into a map — fail
  # soft to the default instead of a FunctionClauseError 500 (same array-param
  # class as the filter catch-alls in this module).
  def parse_int(_, default), do: default

  # Clamp an int param into [1, max] — mirrors the federated-search bound_limit
  # precedent so `?limit=-1` (Postgres rejects a negative LIMIT → 500) and
  # `?limit=999999999` (unbounded scan) can't reach the query. A nil default
  # passes through unclamped so the caller can apply its own floor (ready lets
  # Queue's @ready_default_limit stand in when the param is absent).
  def parse_limit(raw, default, max) do
    case parse_int(raw, default) do
      nil -> nil
      n -> n |> min(max) |> max(1)
    end
  end

  # Clamp an offset param into [0, 100_000] — the ONE floor convention every
  # /v1/tasks pagination path shares (ready/2 and index/2). Floor 0 so a raw
  # `?offset=-10` can never reach `OFFSET` as a negative (Postgres 500); ceiling
  # 100_000 so `?offset=99999999` can't drive an unbounded deep scan. Mirrors the
  # 3-site precedent (query_controller / search_controller / content/query) and
  # the tlv-bl-tasks-ls-offset-broken (D19) index clamp — previously ready/2 was
  # the sole offset in the codebase with a floor but no ceiling.
  def parse_offset(raw), do: raw |> parse_int(0) |> max(0) |> min(100_000)

  # ─── The keyset cursor on `GET /v1/tasks` (bl-api-tasks-stable-cursor) ────
  #
  # THE DEFECT the cursor closes. The index serves a WINDOW — `limit` rows of a
  # corpus ordered `desc: updated_at, desc: id`, capped at
  # `index_limit_cap/0`. Every write to any task re-stamps its `updated_at` and
  # rotates it to the head, so the window's TAIL falls off under ordinary
  # traffic. A reader that walks the window and then asks "is task X still
  # here?" gets the same answer — absent — whether X was CLOSED or merely
  # pushed past row 1000 by a thousand unrelated touches. Absence was not
  # decidable, and `internal/taskboard/merge.go` (the CLI lane) documents a
  # client-side heuristic built on top of that ambiguity (PR #14251).
  #
  # THE FIX is a keyset (seek) cursor over the tuple the ordering ALREADY uses
  # — `(updated_at, id)` for the default list, `(inserted_at, id)` for the
  # `parent=` rail — so paging is bounded by a WHERE clause instead of by
  # OFFSET, and a caller can walk past the cap to the end of the corpus. A row
  # that rotated out of page 1 is reachable on a later page; a row that went
  # terminal is REACHED and renders `lifecycle_status: "done"`. Absence now
  # means "not in the corpus", which is a fact a reader can act on.
  #
  # THE REJECTED ALTERNATIVE was a closed-since delta feed
  # (`GET /v1/tasks?closed_since=<ts>` returning only terminal transitions).
  # It answers ONE question — "which of the rows I knew about closed?" — and
  # answers it cheaply, but it is a SECOND source of truth about task state
  # with its own ordering, its own window and its own drift, and it still
  # cannot tell a caller about a row that rotated out WITHOUT closing (moved,
  # re-parented, relabelled). The keyset cursor makes the ONE list route
  # complete instead of adding a second incomplete one. `GET /v1/tasks/events`
  # already covers "what changed since" over `mutation_events`; a third feed
  # would have overlapped it.
  #
  # OPT-IN, so today's envelope is byte-stable. The `page` block gains
  # `next_cursor` ONLY when the caller spells `?cursor=` (any value, including
  # empty — empty means "page 1, and mint me a cursor"). A request that names
  # no `cursor` param gets the pre-change envelope, key for key.
  #
  # HONEST LIMIT, stated because a keyset over a MUTABLE key has one: the walk
  # is skip-free and duplicate-free for every row NOT written during it. A row
  # touched mid-walk re-stamps `updated_at` and rotates AHEAD of the cursor, so
  # that walk will not see it — the next walk from the head will. This is
  # strictly better than OFFSET paging (which shifts every subsequent page on
  # any insert) and it is the price of ordering by "most recently touched".
  # The `parent=` rail keys on `inserted_at`, which is immutable, so that walk
  # is exact.

  @cursor_version 1

  # The default cap on `?limit=`. Overridable per-environment so a test can
  # prove the ACROSS-THE-BOUNDARY property with a small corpus instead of
  # seeding 1001 real rows — the property under test is "paging reaches rows
  # the clamp excluded", and that property does not care whether the clamp is
  # 1000 or 4.
  @index_limit_cap 1000

  def index_limit_cap,
    do: Application.get_env(:barkpark, :tasks_index_limit_cap, @index_limit_cap)

  @doc """
  True when the caller spelled `?cursor=` at all — the opt-in signal that turns
  `page.next_cursor` on. Presence, not truthiness: `?cursor=` (empty) is a
  legitimate "start at the head and mint me one".
  """
  def cursor_requested?(params), do: Map.has_key?(params, "cursor")

  @doc """
  The keyset axis this request's ordering implies. Mirrors
  `Barkpark.Tasks.Query.apply_index_order/2` exactly — if that ordering ever
  changes, this must change with it or a cursor would seek on a column the
  query does not sort by.
  """
  def cursor_axis(parent) when is_binary(parent), do: :inserted_asc
  def cursor_axis(_), do: :updated_desc

  @doc """
  Parse `?cursor=` into `{:ok, nil}` (no cursor / page 1) or
  `{:ok, {axis, timestamp, id}}`, or `{:error, reason}`.

  Fail-CLOSED, the doctrine this module already applies to `filter[...]`: a
  cursor that cannot be decoded, carries an unknown version, or was minted
  under a DIFFERENT ordering than this request would use is a 400 naming the
  problem — never a silent restart from the head, which would look exactly
  like a completed walk and hand the caller a duplicate page it cannot detect.
  """
  def parse_index_cursor(params, parent) do
    case Map.get(params, "cursor") do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      raw when is_binary(raw) -> decode_cursor(raw, cursor_axis(parent))
      _ -> {:error, "cursor must be a string"}
    end
  end

  defp decode_cursor(raw, axis) do
    with {:ok, json} <- cursor_b64(raw),
         {:ok, %{"v" => @cursor_version, "k" => k, "t" => t, "i" => i}} <- cursor_json(json),
         {:ok, ^axis} <- cursor_axis_token(k),
         {:ok, ts, _off} <- DateTime.from_iso8601(t),
         true <- is_binary(i) and i != "" do
      {:ok, {axis, ts, i}}
    else
      {:ok, other_axis} when is_atom(other_axis) ->
        {:error,
         "cursor was minted for the #{cursor_axis_string(other_axis)} ordering but this " <>
           "request orders by #{cursor_axis_string(axis)} — re-page from the head"}

      _ ->
        {:error, "cursor is not a cursor this route minted"}
    end
  end

  defp cursor_b64(raw) do
    case Base.url_decode64(raw, padding: false) do
      {:ok, json} -> {:ok, json}
      :error -> :error
    end
  end

  defp cursor_json(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> :error
    end
  end

  defp cursor_axis_token("updated_at"), do: {:ok, :updated_desc}
  defp cursor_axis_token("inserted_at"), do: {:ok, :inserted_asc}
  defp cursor_axis_token(_), do: :error

  defp cursor_axis_string(:updated_desc), do: "updated_at DESC"
  defp cursor_axis_string(:inserted_asc), do: "inserted_at ASC"

  @doc """
  Seek past the cursor's row. The predicate is the row-value comparison the
  ordering implies — `(updated_at, id) < (t, i)` for the DESC list,
  `(inserted_at, id) > (t, i)` for the ASC rail — spelled as the equivalent
  `a < t OR (a = t AND id <=> i)` so it composes with the existing filters
  without a tuple constructor.
  """
  def apply_index_cursor(query, nil), do: query

  def apply_index_cursor(query, {:updated_desc, ts, id}) do
    from(d in query,
      where: d.updated_at < ^ts or (d.updated_at == ^ts and d.id < type(^id, :binary_id))
    )
  end

  def apply_index_cursor(query, {:inserted_asc, ts, id}) do
    from(d in query,
      where: d.inserted_at > ^ts or (d.inserted_at == ^ts and d.id > type(^id, :binary_id))
    )
  end

  @doc """
  The cursor that resumes AFTER the last row of this page, or `nil` when the
  page is short (which PROVES the walk is finished — the exact direction of
  `has_more`).

  Minted from the LAST doc actually rendered, so the cursor and the page it
  follows are derived from the same list.
  """
  def next_cursor([], _axis), do: nil

  def next_cursor(docs, axis) do
    last = List.last(docs)

    %{
      "v" => @cursor_version,
      "k" => cursor_axis_column(axis),
      "t" => DateTime.to_iso8601(cursor_axis_value(last, axis)),
      "i" => last.id
    }
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp cursor_axis_column(:updated_desc), do: "updated_at"
  defp cursor_axis_column(:inserted_asc), do: "inserted_at"

  defp cursor_axis_value(%Document{updated_at: v}, :updated_desc), do: v
  defp cursor_axis_value(%Document{inserted_at: v}, :inserted_asc), do: v

  # ─── `filter[...]` container (gr-bl-tasks-route-parent-filter-ignored) ────
  #
  # `GET /v1/tasks` reads its narrowing params FLAT (`?parent=`, `?kind=`, …).
  # A caller who reached for the `/v1/data/query` spelling — `?filter[parent_id]=x`,
  # the form the Cloud GUI Remake charter's GR126 remedy prescribes — used to get
  # a 200 with the WHOLE task page: the `filter` key was never read, so the
  # request was silently unfiltered. Not an error, not empty — a plausible page
  # of foreign rows (measured: 200 rows spanning eleven parents). A driver
  # sourcing a re-parent work-list from that response re-parents every foreign
  # row it contains, and every response reads 200 OK.
  #
  # So the container is now PARSED and fail-CLOSED, the same doctrine
  # `Content.Errors` already applies to `{:invalid_filter_op, …}` /
  # `{:invalid_flat_filter, …}` on the data-query surface (D75): a filter this
  # route cannot honour is a 400 that NAMES the offending key, never a silent
  # pass-through. Honouring `parent_id` alone would have MOVED the defect —
  # `filter[bogus]=1` would still have returned an unfiltered page.
  #
  # The whitelist is exactly the flat params `index/2` already implements
  # (plus `parent_id`, the generic spelling of `parent`); each maps to the
  # SAME `Barkpark.Tasks.Query` fragment as its flat twin, so there is no
  # second filter semantic to drift.
  @index_filter_keys ~w(kind label lifecycle_status parent parent_id phase_id type)

  # ─── The sibling read routes (task-e1b74c19174cb2c1) ─────────────────────
  #
  # The container above was fail-CLOSED on `GET /v1/tasks` alone. Its three
  # sibling READ routes in the same controller still ignored `filter` outright,
  # so a caller who learned the spelling on `/v1/tasks` and carried the habit
  # one route over got the ORIGINAL defect back — a 200 carrying an unfiltered
  # page. Measured live against guerrilla on 2026-09-01:
  #
  #   GET /v1/tasks/ready?filter[parent_id]=task-96a908af98698118
  #     → 200, 200 rows spanning 47 DISTINCT parent_ids
  #   GET /v1/tasks/ready?phase_id=task-96a908af98698118  (the honoured spelling)
  #     → 200, 18 rows, ONE parent_id
  #
  # `ready` is the queue agents CLAIM from, so that false confirmation is one
  # step from a write against a foreign epic.
  #
  # ONE parser, FOUR whitelists. Each route's whitelist is exactly the set of
  # narrowings the route's own machinery can actually apply — never a key it
  # would have to fake:
  #
  #   * `:index`  — the flat params `index/2` composes as Ecto where-clauses.
  #   * `:ready`  — `parent` / `parent_id` / `phase_id`. `Tasks.Queue.ready_query/1`
  #     narrows on exactly ONE parent axis (`:phase_id`, a prefix-agnostic
  #     `content.parent_id` match), so all three spellings name that ONE edge.
  #     `kind` / `lifecycle_status` / `type` / `label` are OUT: the ready query
  #     PINS `kind = "task"` and `lifecycle_status ∈ claimable_statuses/0` in its
  #     base WHERE — honouring them would either contradict the queue's own
  #     definition or need a second query the route does not have.
  #   * `:prime` — `worker` only, the one narrowing `Tasks.Prime.prime/1` takes.
  #     A parent axis is OUT even though prime's ready HEAD could take one:
  #     prime answers with FOUR slices (in_progress, ready, recent_events,
  #     counts) and only one of them could be narrowed. Applying a parent
  #     filter to a quarter of the response is a NEW false confirmation of
  #     exactly this shape, so the key is refused instead.
  #   * `:events` — nothing. The feed's rows are `mutation_events`, not tasks:
  #     none of the task filter keys exists on an event row, and reaching them
  #     needs the join to `documents` that `Tasks.Events` deliberately refuses
  #     (a row-local tenant boundary so delete tombstones survive). Its only
  #     narrowing axes are the keyset cursor `since` and the page size `limit`,
  #     and both are flat params. So every `filter[...]` key is named and
  #     refused rather than silently dropped.
  @ready_filter_keys ~w(parent parent_id phase_id)
  @prime_filter_keys ~w(worker)
  @events_filter_keys []

  # THE FLAT ALLOWLIST (task-233cb8a1d033c738). `flat:` used to be PROSE — a
  # sentence for an error message, listing six of the eleven keys `index`
  # actually honours. Now it is a LIST and the prose is derived from it, so the
  # thing the message promises and the thing the route enforces cannot drift.
  #
  # WHY THE TOP LEVEL NEEDED CLOSING AT ALL. PR #12780 closed the `filter[...]`
  # container: a key that route cannot honour is a 400 naming the key. The flat
  # namespace stayed fail-OPEN, and `parent_id` is the exact spelling a caller
  # reaches for after reading the task schema (`content.parent_id`) — the route
  # only ever read `parent`. Measured before this change: `?filter[parent_id]=X`
  # returned 18 rows under one parent, while `?parent_id=X` returned all 383
  # across 76 parents, 200 OK. That is not a missing feature, it is a FALSE
  # CONFIRMATION an automated re-parent driver will act on.
  #
  # `parent_id` is therefore listed as an ACCEPTED ALIAS of `parent` rather than
  # refused: refusing the spelling the schema itself teaches would trade a wrong
  # answer for a wrong lesson.
  @index_flat_keys ~w(view limit offset cursor type kind lifecycle_status parent parent_id phase_id label)
  @ready_flat_keys ~w(view limit offset phase_id order worker)
  @prime_flat_keys ~w(view limit offset worker order)
  @events_flat_keys ~w(since limit)

  @route_filters %{
    index: %{
      label: "GET /v1/tasks",
      keys: @index_filter_keys,
      flat_keys: @index_flat_keys,
      flat: Enum.join(@index_flat_keys, ", ")
    },
    ready: %{
      label: "GET /v1/tasks/ready",
      keys: @ready_filter_keys,
      flat_keys: @ready_flat_keys,
      flat: Enum.join(@ready_flat_keys, ", ")
    },
    prime: %{
      label: "GET /v1/tasks/prime",
      keys: @prime_filter_keys,
      flat_keys: @prime_flat_keys,
      flat: Enum.join(@prime_flat_keys, ", ")
    },
    events: %{
      label: "GET /v1/tasks/events",
      keys: @events_filter_keys,
      flat_keys: @events_flat_keys,
      flat: Enum.join(@events_flat_keys, ", ")
    }
  }

  @doc "The `filter[...]` keys `route` can honour (`:index` / `:ready` / `:prime` / `:events`)."
  def filter_keys(route), do: @route_filters |> Map.fetch!(route) |> Map.fetch!(:keys)

  @doc "The wire label for `route` — what an error message names."
  def filter_route_label(route), do: @route_filters |> Map.fetch!(route) |> Map.fetch!(:label)

  def index_filter_keys, do: @index_filter_keys

  @doc """
  Parse the optional `filter[...]` container on `GET /v1/tasks`.

  `{:ok, %{"parent_id" => "…"}}` for a map of whitelisted string→string pairs
  (absent container → `{:ok, %{}}`), or `{:error, reason}` — never a silently
  dropped filter. The `:index` seat of `parse_route_filters/2`.
  """
  def parse_index_filters(params) when is_map(params), do: parse_route_filters(params, :index)

  @doc """
  The claim-time criteria refusal, which has to TEACH rather than merely refuse.

  About thirty agents drive `bp task claim` daily. A refusal that names no
  remedy costs every one of them a round trip to find one, and that cost is
  what turns a good gate into a resented one — so this names the row, states
  what is missing, gives the exact command to fix it, and gives the override
  verbatim rather than alluding to it.
  """
  @spec criteria_unstated_message(String.t(), String.t()) :: String.t()
  def criteria_unstated_message(doc_id, worker_id) do
    ~s|#{doc_id} states NO acceptance criteria, so nothing was claimed. A row with none | <>
      ~s|can only ever be attested by artifact — the artifact says something landed, it cannot | <>
      ~s|say what the row was FOR. The close door already refuses this, and by then it is too | <>
      ~s|late: the criteria get written after the work, by whoever is trying to get the row | <>
      ~s|shut. Write them now, while they still shape the work:\n| <>
      ~s|  bp task create is not what you want here — patch the row you are about to claim:\n| <>
      ~s|  bp doc patch task #{doc_id} --set 'acceptance_criteria:=[{"criterion":"<measurable, checkable>","met":false,"evidence":""}]' --yes\n| <>
      ~s|  bp task claim #{doc_id} #{worker_id} --yes\n| <>
      ~s|Containers are exempt already (a decision/goal label, a non-task kind, or a row with | <>
      ~s|children), so if this IS a container, label it rather than overriding. To claim anyway, | <>
      ~s|on the record: --set criteria_unstated_override="<why this row needs none>".|
  end

  @doc """
  The FLAT (top-level) query params `route` honours.

  One list, used both to enforce and to name — `flat:` in `@route_filters` is
  derived from it, so an error message cannot promise a key the route drops.
  """
  @spec flat_keys(atom()) :: [String.t()]
  def flat_keys(route), do: @route_filters |> Map.fetch!(route) |> Map.fetch!(:flat_keys)

  @doc """
  Refuse an unknown TOP-LEVEL query param on `route`.

  `:ok`, or `{:error, {:unknown_flat_param, key, route}}` for the first
  unrecognised key in sorted order — deterministic, so the same request always
  names the same key.

  WHY FAIL-CLOSED. The sibling `filter[...]` container was closed by #12780; the
  flat namespace was still fail-OPEN, so `?parent_id=X` and `?bogus=1` both
  returned a 200 carrying the UNFILTERED page. A caller who asked to narrow and
  got everything back cannot tell that from a parent with many children, which
  is why this is a wrong ANSWER rather than a missing feature.

  Phoenix injects its own routing keys into `params`, so those are skipped by
  name rather than by guesswork: they are not caller input and refusing them
  would 400 every request.
  """
  @phoenix_injected ~w(format _format _method _csrf_token dataset workspace project)

  @spec reject_unknown_flat_params(map(), atom()) ::
          :ok | {:error, {:unknown_flat_param, String.t(), atom()}}
  def reject_unknown_flat_params(params, route) when is_map(params) and is_atom(route) do
    allowed = flat_keys(route) ++ @phoenix_injected ++ ["filter"]

    params
    |> Map.keys()
    |> Enum.filter(&is_binary/1)
    |> Enum.sort()
    |> Enum.find(&(&1 not in allowed))
    |> case do
      nil -> :ok
      key -> {:error, {:unknown_flat_param, key, route}}
    end
  end

  @doc """
  Parse the optional `filter[...]` container for `route`.

  `{:ok, map}` of whitelisted string→string pairs (absent container →
  `{:ok, %{}}`), or `{:error, reason}` — never a silently dropped filter:

    * `{:unknown_filter_key, key, route}` — `?filter[bogus]=1`, and every key
      on a route whose whitelist is empty.
    * `{:invalid_filter_value, key, route}` — a non-string value: the operator
      form `?filter[k][eq]=x` (Plug → a map) or the list form `?filter[k][]=x`
      (Plug → a list). Both would fall through the `maybe_filter_*` non-binary
      catch-alls as a no-op, i.e. the original defect wearing a different
      spelling.
    * `{:invalid_filter_container, raw, route}` — a bare `?filter=x` / `?filter[]=x`.

  Keys are checked in sorted order so a request with several bad keys names the
  same one on every run.
  """
  def parse_route_filters(params, route) when is_map(params) and is_atom(route) do
    allowed = filter_keys(route)

    case Map.get(params, "filter") do
      nil -> {:ok, %{}}
      %{} = filter -> validate_route_filters(filter, route, allowed)
      raw -> {:error, {:invalid_filter_container, raw, route}}
    end
  end

  defp validate_route_filters(filter, route, allowed) do
    filter
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      key = to_string(key)

      cond do
        key not in allowed -> {:halt, {:error, {:unknown_filter_key, key, route}}}
        not is_binary(value) -> {:halt, {:error, {:invalid_filter_value, key, route}}}
        true -> {:cont, {:ok, Map.put(acc, key, value)}}
      end
    end)
  end

  @doc """
  The single parent narrowing `GET /v1/tasks/ready` will apply, folded from the
  flat `?phase_id=` and the three bracket spellings that name the SAME edge.

  `index/2` can afford to compose several spellings as independent AND clauses
  (a caller who passes two different values gets the honest zero rows).
  `ready_query/1` has ONE `:phase_id` slot, so there is no conjunction to
  compose: two different values would mean one spelling quietly winning — the
  very failure this row exists to close. Distinct values are therefore a 400
  that names every spelling the request used.
  """
  def ready_phase_id(params, filters) do
    fold_single_narrowing(
      [
        {"phase_id", params["phase_id"]},
        {"filter[parent]", filters["parent"]},
        {"filter[parent_id]", filters["parent_id"]},
        {"filter[phase_id]", filters["phase_id"]}
      ],
      :ready
    )
  end

  @doc """
  The single `worker` narrowing `GET /v1/tasks/prime` will apply, folded from
  the flat `?worker=` and `filter[worker]`. Same one-slot rule as
  `ready_phase_id/2`.
  """
  def prime_worker(params, filters) do
    fold_single_narrowing(
      [{"worker", params["worker"]}, {"filter[worker]", filters["worker"]}],
      :prime
    )
  end

  defp fold_single_narrowing(spellings, route) do
    given = Enum.reject(spellings, fn {_spelling, value} -> is_nil(value) end)

    case given |> Enum.map(fn {_spelling, value} -> value end) |> Enum.uniq() do
      [] -> {:ok, nil}
      [one] -> {:ok, one}
      _ -> {:error, {:conflicting_filter, Enum.map(given, fn {s, _} -> s end), route}}
    end
  end

  @doc """
  Human-readable message for a `parse_route_filters/2` error — it must TEACH
  (name the offending key and list what this route accepts), because the caller
  it refuses is one who believed the request was already filtered.
  """
  # task-233cb8a1d033c738 — the FLAT namespace's refusal. It names the key AND
  # the accepted set, because a caller who reached for `parent_id` guessed a
  # PLAUSIBLE spelling (it is what content.parent_id is called) and needs to be
  # told which one this route reads, not merely that theirs was wrong.
  def filter_message({:unknown_flat_param, key, route}) do
    "#{filter_route_label(route)} does not read the query param #{inspect(key)}, and " <>
      "ignoring it would return an UNFILTERED page that looks like an answer; " <>
      "accepted flat params: #{flat_clause(route)}. " <>
      "Structured filters go in the filter[<key>]=<value> container."
  end

  def filter_message({:unknown_filter_key, key, route}) do
    "unknown filter key #{inspect(key)} on #{filter_route_label(route)}; " <>
      supported_clause(route)
  end

  def filter_message({:invalid_filter_value, key, route}) do
    "filter[#{key}] must be a single string value; the operator form " <>
      "(filter[#{key}][eq]=…) and the list form (filter[#{key}][]=…) are not " <>
      "supported on #{filter_route_label(route)}"
  end

  def filter_message({:invalid_filter_container, _raw, route}) do
    "filter must be given as filter[<key>]=<value>; " <> supported_clause(route)
  end

  def filter_message({:conflicting_filter, spellings, route}) do
    "#{Enum.join(spellings, " and ")} name the same narrowing on " <>
      "#{filter_route_label(route)} but carry different values; this route applies " <>
      "exactly one — pass a single spelling"
  end

  defp supported_clause(route) do
    case filter_keys(route) do
      [] ->
        "#{filter_route_label(route)} honours no filter[] key — it narrows only " <>
          "with its flat params (#{flat_clause(route)})"

      keys ->
        "supported: " <> (keys |> Enum.map(&"filter[#{&1}]") |> Enum.join(", "))
    end
  end

  defp flat_clause(route), do: @route_filters |> Map.fetch!(route) |> Map.fetch!(:flat)

  def filter_details({:unknown_flat_param, key, route}),
    do: %{
      key: key,
      route: filter_route_label(route),
      supported_flat: flat_keys(route),
      supported_filter: filter_keys(route)
    }

  def filter_details({:unknown_filter_key, key, route}),
    do: %{key: key, route: filter_route_label(route), supported: filter_keys(route)}

  def filter_details({:invalid_filter_value, key, route}),
    do: %{key: key, route: filter_route_label(route), supported: filter_keys(route)}

  def filter_details({:invalid_filter_container, _raw, route}),
    do: %{route: filter_route_label(route), supported: filter_keys(route)}

  def filter_details({:conflicting_filter, spellings, route}),
    do: %{conflicting: spellings, route: filter_route_label(route), supported: filter_keys(route)}

  def reason_to_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  def reason_to_string({:invalid_lifecycle, s}), do: "invalid_lifecycle:#{s}"
  # Stamp (and any future holder-gated verb) on a task with no live claim —
  # mirror the invalid_lifecycle wire shape instead of leaking inspect() output.
  def reason_to_string({:not_in_progress, s}), do: "not_in_progress:#{s}"
  # Close honesty gates (PDS-D288/D289/D290). Each gets a STABLE wire token —
  # `inspect/1` on the tuple would leak Elixir syntax (`{:not_holder, "w"}`) into
  # a JSON `reason` field that the bp CLI and the pr-task gate both string-match.
  def reason_to_string({:not_holder, held}), do: "not_holder:#{held || "?"}"

  def reason_to_string({:criteria_unmet, indices}) when is_list(indices),
    do: "criteria_unmet:#{Enum.join(indices, ",")}"

  def reason_to_string({:acknowledgement_unposted, issue}),
    do: "acknowledgement_unposted:#{issue || "?"}"

  def reason_to_string({:sentinel_worker_id, worker}), do: "sentinel_worker_id:#{worker}"
  def reason_to_string(other), do: inspect(other)

  # ─── Criteria-conflict hints (D56 — the guard must TEACH, not just refuse) ──
  #
  # A guard is only worth shipping if the caller it blocks knows exactly what to
  # type next. These strings ride the 409 as a top-level `message`, which the bp
  # CLI prints in place of the bare reason token (internal/cli/errors.go
  # `bodyMessage`). Surface-specific because the fix differs: `--criterion-text`
  # on a stamp, a `"criterion"` key per entry on a close's `--set criteria:=…`.
  # Any other reason returns nil → the response keeps its historical shape.
  def criteria_hint(reason, surface)

  def criteria_hint(:criterion_text_required, :stamp),
    do:
      ~s|--met requires --criterion-text "<the criterion's exact stored wording>". | <>
        ~s|--criterion N is a 0-BASED index — the FIRST criterion is 0 — and is unverifiable on its own: | <>
        ~s|an unguarded index silently flips whatever row it lands on. Read the wording from | <>
        ~s|`bp task get <id>` at acceptance_criteria[N].criterion and pass it verbatim. --miss needs no text.|

  def criteria_hint(:criterion_text_required, :close),
    do:
      ~s|every criteria entry with met=true must carry its "criterion" — the exact stored wording — e.g. | <>
        ~s|--set 'criteria:=[{"index":0,"met":true,"evidence":"…","criterion":"<acceptance_criteria[0].criterion, verbatim>"}]'. | <>
        ~s|The 0-BASED index alone is unverifiable and can flip a neighbouring criterion. An entry with met=false needs no text. | <>
        ~s|Or drop the index entirely and send the rubric row as `bp task get` prints it — | <>
        ~s|--set 'criteria:=[{"criterion":"<the exact stored wording>","met":true,"evidence":"…"}]' — | <>
        ~s|which resolves the row by that text (and then needs non-empty evidence).|

  # The MERGE-GATE refusal (cch-w49 / cch-w19). This message is load-bearing in
  # BOTH directions and each clause was asked for by a task row: it must name
  # who may use the override (cch-w19 c0), it must say OUT LOUD that the match
  # can be on the criterion's PROSE and may therefore be a mere mention, and it
  # must state that mention rate as a MEASURED number rather than a hedge
  # (cch-w19 c1) — 65 of 1853 marker-bearing criteria over the live corpus on
  # 2026-08-22. It must also name the STRUCTURAL exit (`merge_gate: false`), so
  # a caller who hits a false positive can retire it permanently for that row
  # instead of reaching for the override every time — reflexive overriding is
  # the failure mode the guard exists to prevent.
  def criteria_hint(:merge_gated_criterion, :stamp),
    do:
      ~s|this criterion is a MERGE GATE — the LEAD closes it when the PR merges, and a builder flipping it | <>
        ~s|fabricates a done before the PR exists. Nothing was written. If you ARE the lead closing the gate, | <>
        ~s|re-run with --merge-gated. | <>
        ~s|IF THIS ROW IS NOT A GATE, THE MATCH WAS ON ITS PROSE AND IS A FALSE POSITIVE: with no explicit | <>
        ~s|"merge_gate" key on the criterion the guard falls back to matching the MERGE-GATED / MERGE GATE | <>
        ~s|wording anywhere in the text, which over the live corpus (2026-08-22) is a mention rather than a | <>
        ~s|gate for 65 of 1853 marker-bearing criteria (3.5%). The fix for those is structural, not the | <>
        ~s|override: set "merge_gate": false on that criterion and the guard will never ask again. The prose | <>
        ~s|fallback stays deliberately WIDE because a false refusal is loud and recoverable while a false | <>
        ~s|permit is silent — see Barkpark.Tasks.Criteria.merge_gated?/1.|

  # THE WITHDRAWAL HINTS (D745). Both refusals are reachable by a lead doing
  # exactly the right thing on a sealed row, so each has to name the next
  # command rather than the rule it broke.
  def criteria_hint(:observed_rev_required, :stamp),
    do:
      ~s|this row carries no live claim (it is closed, cancelled or released), so there is no epoch to fence | <>
        ~s|a withdrawal or a post-close --miss against. Pin the rev you read instead: re-read with | <>
        ~s|`bp task get <id> -o json`, take .doc.rev, and re-run with --observed-rev <rev>. Nothing was | <>
        ~s|written. Neither verb touches the seal, the close_reason or the original evidence: a withdrawal | <>
        ~s|lowers the met flag and appends a signed record naming who withdrew it and why, and a --miss | <>
        ~s|appends an attempt while PINNING met to whatever it already was.|

  # THE POST-CLOSE REFUSAL (task-d68754135a6a9f66). This is the message that
  # decides whether a closer reaches for the sanctioned instrument or for a raw
  # /v1/data/mutate — the substitution that pasted one evidence blob across
  # every remaining criterion on ~43-57 rows. It therefore has to name the verb
  # that DOES work here and the exact flags it needs, not just the wall.
  def criteria_hint({:not_in_progress, status}, :stamp) when status in ["done", "cancelled"],
    do:
      ~s|this row is #{status} — its verdict is sealed by close, so --met is refused here permanently: a | <>
        ~s|met-flip after close rewrites the claim the close sealed AND overwrites the criterion's evidence. | <>
        ~s|Nothing was written. What DOES work on a sealed row is the append-only pair: --miss --note "..." | <>
        ~s|records an honest observation (it pins met to its stored value and touches neither evidence nor | <>
        ~s|the criterion text), and --withdraw --note "..." lowers a met flag review has refuted. Both need | <>
        ~s|the rev you read instead of an epoch: `bp task get <id> -o json`, take .doc.rev, pass | <>
        ~s|--observed-rev <rev>. Do NOT patch criteria through /v1/data/mutate — that leaves no attribution | <>
        ~s|and is what this instrument exists to replace.|

  def criteria_hint({:not_in_progress, status}, :stamp),
    do:
      ~s|this row is #{status}, not in_progress — a stamp writes under a LIVE claim. Nothing was written. | <>
        ~s|Claim it first (`bp task claim <id> <worker>`) and stamp with the epoch that returns. The | <>
        ~s|post-close --miss / --withdraw exemption applies only to a done or cancelled row.|

  # THE PULSE'S STATE REFUSAL (task-b6fcc8e2f57e1cd5). A keep-alive loop's ONLY
  # success signal is the pulse's exit code, so its FAILURE has to say which of
  # the two lost-lease situations it hit: the row moved (re-claim), or the claim
  # is someone else's (stand down). `not_holder` alone said neither. Name the
  # state the row actually carries and the one verb that fixes it.
  def criteria_hint({:not_in_progress, status}, :pulse),
    do:
      ~s|this row is #{status}, not in_progress — a pulse renews a LIVE claim, and this row no longer | <>
        ~s|has one. Nothing was written: no now-line, no epoch bump, so the epoch you hold is unchanged. | <>
        ~s|A stale `claim.worker` can OUTLIVE the lease (a `bp task stage <id> open` moves the row and | <>
        ~s|leaves the claim map behind), which is why presence of your worker id here proves nothing. | <>
        ~s|Re-claim it — `bp task claim <id> <worker>` — and use the epoch THAT returns for the next | <>
        ~s|stamp/close. If your loop treated the earlier pulses as proof the claim was held, they were not.|

  def criteria_hint(:criterion_not_met, :stamp),
    do:
      ~s|this criterion is already met=false, so there is no stamped proof to withdraw and nothing was | <>
        ~s|written — a withdrawal record on an already-honest row would only mislead the next reader. | <>
        ~s|If you meant to record a failed attempt on it, that is --miss --note "…". Check the index: | <>
        ~s|--criterion N is 0-BASED, so the first criterion is 0.|

  # ─── The landing mark's two PERMIT refusals (task-59fe7b40b719b379) ───────
  #
  # `landed` is the one criteria write with no holder behind it, so its guards
  # are the only thing standing between a CI token and a fabricated done. Both
  # messages therefore have to name the STRUCTURAL fix, not just the wall:
  # `merge_gate: true` on the row is what makes a landing mark able to seal it,
  # and a human stamp is what a non-merge row still needs.
  def criteria_hint(:criterion_not_merge_shaped, :landed),
    do:
      ~s|`landed` may only flip a merge-shaped criterion — one the lead seals when the PR merges. | <>
        ~s|That row is not: it carries no "merge_gate": true, and its wording says nothing about being merge-gated | <>
        ~s|or about a PR being merged to main. Nothing was written (the flip and the landing sentence ride one CAS). | <>
        ~s|A criterion proven by WORK is stamped by whoever did the work — `bp task stamp <id> <worker> <epoch> | <>
        ~s|--criterion N --criterion-text "…" --met --evidence "…"`. If this row really is the lead's merge gate, | <>
        ~s|mark it "merge_gate": true on the criterion and the landing mark will seal it. | <>
        ~s|Re-run without --criterion to record the landing sentence alone.|

  def criteria_hint(:criterion_already_met, :landed),
    do:
      ~s|that criterion is already met, and `landed` NEVER overwrites a met criterion — the stored evidence is | <>
        ~s|somebody's proof, and replacing it with a merge notice would erase the proof and leave the notice. | <>
        ~s|Nothing was written. The landing sentence itself still lands: re-run without --criterion.|

  def criteria_hint(:criteria_mismatch, _surface),
    do:
      ~s|the criterion text you passed is NOT the wording stored at that index. Either the index is off by one | <>
        ~s|— it is 0-BASED, the FIRST criterion is 0 — or the list changed since you read it. Nothing was written. | <>
        ~s|Re-read `bp task get <id>` and pass the index and the wording of the SAME row.|

  # The TEXT-KEYED resolution refusals (gh-2314). Both are the same law as the
  # D56 hints above — a text-keyed entry resolves to exactly one row or to
  # nothing at all, because guessing between candidates is the silent-neighbour
  # bug wearing a different hat.
  def criteria_hint(:criterion_not_found, _surface),
    do:
      ~s|no acceptance criterion has that exact wording, so there is no row to update. Nothing was written. | <>
        ~s|The match is EXACT — whitespace and punctuation included — so copy the text verbatim from | <>
        ~s|`bp task get <id>` at acceptance_criteria[].criterion rather than retyping it. If the wording | <>
        ~s|itself changed since you read the task, re-read it first.|

  def criteria_hint(:criterion_ambiguous, _surface),
    do:
      ~s|two or more acceptance criteria share that exact wording, so keying by text cannot say which row | <>
        ~s|you mean, and picking one would flip a criterion you did not name. Nothing was written. | <>
        ~s|Use the indexed shape for these rows instead: | <>
        ~s|--set 'criteria:=[{"index":<N>,"met":true,"evidence":"…","criterion":"<the same wording>"}]' | <>
        ~s|(the index is 0-BASED — the FIRST criterion is 0).|

  def criteria_hint(:criteria_index_out_of_range, _surface),
    do:
      ~s|that criterion index is past the end of acceptance_criteria. The index is 0-BASED: the FIRST criterion is 0. Nothing was written.|

  # Close honesty gates (PDS-D288/D289/D290). Same law as the D56 hints above:
  # a refusal that does not teach the escape hatch is just a wall. Each names the
  # exact body field to add — both overrides are plain close-body params, so on
  # the CLI they ride `--set <field>="<reason>"`.
  def criteria_hint({:not_holder, held}, :close),
    do:
      ~s|this task's claim is held by "#{held || "someone else"}", not by the worker you named, so closing it | <>
        ~s|would record THEM as having finished the work. If that is deliberate (a lead sealing a merge-gated | <>
        ~s|task is the normal case), say so and it lands, recorded: | <>
        ~s|--set holder_override="<why you are closing someone else's claim>". | <>
        ~s|This is an HONESTY gate, not authorization — it stops accidents and makes deliberate foreign closes auditable.|

  def criteria_hint({:criteria_unmet, indices}, :close) when is_list(indices),
    do:
      ~s|acceptance criteria #{Enum.join(indices, ", ")} (0-BASED) are not met on the task AS STORED, and criteria | <>
        ~s|flipped in this very close command do not count — that would be the closer grading its own homework. | <>
        ~s|Stamp them as you prove them (`bp task stamp <id> <worker> <epoch> --criterion N --criterion-text "…" | <>
        ~s|--met --evidence "…"`), or close over them on the record: --set criteria_override="<why it is done anyway>".|

  # The reporter loop (`Github.Acknowledgement`). This refusal must carry three
  # things the caller cannot get anywhere else: WHO is waiting (someone outside
  # this ledger, who can only see the issue), WHAT discharges it (a comment plus
  # the stamp — the stamp alone is a lie, the comment alone is invisible here),
  # and that `criteria_override` is NOT the escape hatch, because reaching for
  # the wrong override and finding it works is exactly how this gap would
  # reopen.
  def criteria_hint({:acknowledgement_unposted, issue}, :close),
    do:
      ~s|this task was BORN from an outsider's GitHub issue#{if issue, do: " (##{issue})", else: ""}, and nobody outside | <>
        ~s|this ledger can see the close you are about to write — the issue is the only surface they have, and | <>
        ~s|the bridge already promised them updates there. Post the outcome as a comment on the issue (the fix | <>
        ~s|with its PR or commit, or why it will not be done), then stamp the ack_gate criterion with the comment | <>
        ~s|URL as evidence. If the row has no ack_gate criterion it was born before this gate existed — add one. | <>
        ~s|To close anyway, on the record: --set ack_override="<why the reporter is not being told>". | <>
        ~s|criteria_override does NOT discharge this: they are different admissions.|

  # The CLOSE ARTIFACT refusal (PDS-D291). The hint QUOTES the ruling, because the
  # ruling is the whole content of the refusal: without it the caller reads
  # "needs an artifact" as a formatting nit rather than as "this is not done".
  # It must also name the honest exit the ruling itself names (add criteria, or
  # cancel) BEFORE the override, so the override is the third choice and not the
  # first — reflexive overriding is what emptied `criteria_override` of meaning.
  def criteria_hint(:close_reason_needs_artifact, :close),
    do:
      ~s|this row carries ZERO acceptance criteria, and main ruled (task-ce0c0ffff6edde23, 2026-09-02): | <>
        ~s|"a row with ZERO acceptance criteria may close done only when its close_reason names the merged PR | <>
        ~s|number + sha (or the run output) that discharged its title; if no such artifact exists it is NOT done | <>
        ~s|— add criteria or cancel with the reason. A merge condition written only in prose does not bind." | <>
        ~s|So: put the artifact IN the reason — a PR number AND its sha (e.g. "landed #14383 @ 63b89bef30") or a | <>
        ~s|pasted run (a ``` fence, or a line starting with "$ ") — or add the acceptance criteria this row should | <>
        ~s|have carried and stamp them, or close it `cancelled` with the reason. Goals, decisions and rows with | <>
        ~s|children are exempt. To close done anyway, on the record: --set close_reason_override="<why it is done | <>
        ~s|with no artifact>".|

  # THE CANCEL REASON REFUSAL (task-650d7844d8fe7199). Unlike every other hint
  # here this one names NO override, because there is none and inventing the
  # expectation of one would be the whole defect again: the fix is a sentence,
  # and a caller who has none has nothing to record. It must say WHY a cancel is
  # the one status this binds on, or it reads as an arbitrary new required field.
  def criteria_hint(:cancel_reason_required, :close),
    do:
      ~s|a `cancelled` close needs a reason and this one carried none (absent, empty, or whitespace-only). | <>
        ~s|A cancel is EXEMPT BY NAME from every other close gate — the criteria gate (D289) and the close | <>
        ~s|artifact gate (D291) both wave it through, because abandoning the acceptance criteria is what | <>
        ~s|cancelling MEANS — so the reason is not one record among several, it is the ENTIRE record of why | <>
        ~s|this work stopped. Pass it as the FIFTH positional: | <>
        ~s|`bp task close <id> <worker> <epoch> cancelled "<why this work is being abandoned>"`. | <>
        ~s|There is no override, on purpose: the escape hatch IS the sentence. `done` and `blocked` closes | <>
        ~s|are unaffected — a `done` close is governed by the criteria and artifact gates, and a `blocked` | <>
        ~s|close is an honest partial whose record is not yet due.|

  def criteria_hint({:sentinel_worker_id, worker}, _surface),
    do:
      ~s|"#{worker}" is not a worker id — it is a missing value wearing a worker's clothes (empty, "None", | <>
        ~s|"null", "nil" or "-"). A close attributed to it reads as a real close to every downstream gate. | <>
        ~s|Pass the worker that actually holds the claim.|

  # THE STATUS-POSITION REFUSAL (dr-w14 / lead-ledger). `bp task close <id>
  # <worker> <epoch> "<a whole sentence>"` parses that sentence as the LIFECYCLE
  # STATUS, so the server refuses `invalid_lifecycle:<the whole sentence>` — a
  # token that names the mistake without ever naming the fix. The gate does NOT
  # widen (only done/cancelled/blocked close a task); the SENTENCE does: when the
  # rejected value cannot be a status at all — it carries whitespace, or it is
  # far longer than any status — say plainly that the reason belongs in a LATER
  # positional, and print the corrected command.
  def criteria_hint({:invalid_lifecycle, status}, :close) do
    allowed = Enum.join(Close.closed_lifecycle_statuses(), ", ")

    if reason_shaped?(status) do
      ~s|that is a close REASON sitting in the STATUS position: `bp task close <id> <worker> <epoch>` | <>
        ~s|takes the lifecycle status 4th (#{allowed}) and the reason 5th. Nothing was written. | <>
        ~s|Re-run: bp task close <id> <worker> <epoch> done "<your reason>"|
    else
      ~s|#{inspect(to_string(status))} is not a close status — a close ends a task #{allowed}. | <>
        ~s|Nothing was written. Re-run: bp task close <id> <worker> <epoch> done "<why>"|
    end
  end

  def criteria_hint(_reason, _surface), do: nil

  # A value that could never be a lifecycle status: it carries whitespace, or it
  # is longer than any of them by a wide margin. Both shapes say "this is prose",
  # and prose in the status slot is a close reason that missed its positional.
  @reason_shaped_min_length 24
  defp reason_shaped?(status) when is_binary(status),
    do: String.match?(status, ~r/\s/) or String.length(status) > @reason_shaped_min_length

  defp reason_shaped?(_status), do: false

  @doc """
  The wrong-epoch 409's remedy sentence (dr-w14-bl-fenced-off-409-is-mute).

  `fenced_off` used to ship as a bare `{"ok":false,"reason":"fenced_off"}`: the
  caller was told its epoch was wrong and never told which epoch is right, so
  recovery took a re-read the refusal never asked for. `current_epoch` is read
  off the row on the refusal path and named here; `nil` (the row lost its claim
  between the refusal and the re-read) falls back to naming the re-read.
  """
  @spec fence_hint(atom() | tuple(), atom(), integer() | nil) :: String.t() | nil
  def fence_hint(:fenced_off, surface, current_epoch)
      when is_integer(current_epoch) and surface in [:close, :stamp] do
    ~s|this claim is at epoch #{current_epoch}, not the one you passed — every `bp task pulse` ADVANCES | <>
      ~s|the epoch, so a claim-time value is stale after the first heartbeat. Nothing was written. | <>
      ~s|Re-run on the current epoch: bp task #{surface} <id> <worker> #{current_epoch}|
  end

  def fence_hint(:fenced_off, surface, _current_epoch) when surface in [:close, :stamp] do
    ~s|the epoch you passed is not the one this claim carries, and every `bp task pulse` ADVANCES it. | <>
      ~s|Nothing was written. Re-read the current epoch and re-run on it: | <>
      ~s|bp task get <id> -o json -> .doc.claim.epoch, then bp task #{surface} <id> <worker> <that epoch>|
  end

  def fence_hint(_reason, _surface, _current_epoch), do: nil

  @doc """
  The edited-under-you 409's remedy sentence
  (pds-bl-close-409-hint-promises-absent-fields).

  The body has always carried `current_rev` + `changed_fields` at the top level
  — what it never carried is the command that consumes them, so the operator
  read two values and still had to go find the recovery. Name it here, with the
  rev already substituted, so the refusal body alone is enough.
  """
  @spec drift_hint(String.t(), [String.t()]) :: String.t()
  def drift_hint(current_rev, changed_fields) do
    ~s|the task's brief changed under your claim (#{Enum.join(changed_fields, ", ")}), so this close would | <>
      ~s|seal work described differently from what you read. Nothing was written. Re-read it, reconcile | <>
      ~s|those fields, then close pinning the rev in this body: | <>
      ~s|bp task close <id> <worker> <epoch> --set observed_rev=#{current_rev}|
  end

  # ─── Success help[] (axi-s4 R5 — a success TEACHES the next command) ──────
  #
  # Every mutation SUCCESS envelope carries a top-level `help` list: 1–3
  # concrete `bp` command templates with the REAL doc_id / worker / epoch the
  # server knows at mutation time. Placeholder convention (AXI): angle
  # brackets mark ONLY values the agent must fill, `"..."` marks free text;
  # fixed flags ride verbatim. The bp CLI prints these on stderr in every
  # output mode (internal/cli/run.go emitHelpHints); MCP surfaces them for
  # free via raw body passthrough. Vocabulary must stay consistent with the
  # static tool descriptions in internal/cli/mcp_tasks.go (same epoch rules,
  # same worker-must-match rule).
  #
  # CRITICAL: pulse BUMPS the claim epoch (Tasks.Pulse) — its templates carry
  # the FRESH epoch read from the RESPONSE doc, never the epoch the caller
  # sent. Stamp does NOT bump, so its templates reuse the same epoch. The
  # epoch is always read from the fresh post-write doc, which makes both
  # rules one code path.
  #
  # help[] is ADDITIVE — a sibling of the existing envelope fields (the
  # `warnings:` precedent on close_response/1), never a rename or removal.
  # The SAME default `Barkpark.Tasks.TtlSweeper` reaps on
  # (`@default_ttl_seconds` there, `:task_lease_ttl_seconds` in config). Kept in
  # sync by the conn test that asserts the claim receipt's `seconds` equals the
  # configured value — a drift between the number the sweeper enforces and the
  # number the receipt promises is the whole defect this closes.
  @default_lease_ttl_seconds 2700

  # ─── The lease a claim/pulse just granted (claim-lease, wave 27) ─────────
  #
  # A claim IS a lease, and every receipt described it EXCEPT its duration. The
  # epoch rode the envelope, help[] rode the envelope, the expiry rode nothing —
  # it lived only in `TtlSweeper`'s TTL constant and in `content.claim.ts_iso`,
  # two facts a caller would have to join by reading server source. So a lead
  # who claimed four rows and dispatched builders learned the lease length by
  # watching one lapse 29s before its PR opened: the pr-task-gate refused the
  # PR and `bp task next` handed the sibling row to a second lead mid-build.
  #
  # This computes that join ONCE, server-side, where both halves are already in
  # hand, and rides the 2xx envelope as an ADDITIVE top-level `lease` (the
  # `help:` precedent — a sibling field, never a rename). It is DERIVED, never
  # stored: `TtlSweeper.sweep/1` reaps on `now - ttl > ts_iso`, so the expiry a
  # caller is told is exactly the boundary the sweeper will apply, and a TTL
  # config change moves both at once. nil when the row carries no parseable
  # `claim.ts_iso` — a receipt that guessed an expiry would be this same defect
  # wearing a fix's clothes, and the bp CLI prints nothing when the field is
  # absent (internal/cli/tasks_lease.go).
  #
  # RENEWAL: claim (renewal path), re-claim and pulse all refresh `ts_iso`, so
  # the same function describes the lease after a heartbeat with no special case.
  def claim_lease(%Document{} = doc) do
    ttl = Application.get_env(:barkpark, :task_lease_ttl_seconds, @default_lease_ttl_seconds)

    with ts when is_binary(ts) <- get_in(doc.content || %{}, ["claim", "ts_iso"]),
         {:ok, granted, _} <- DateTime.from_iso8601(ts) do
      %{
        granted_at: DateTime.to_iso8601(granted),
        expires_at: granted |> DateTime.add(ttl, :second) |> DateTime.to_iso8601(),
        seconds: ttl,
        minutes: div(ttl, 60)
      }
    else
      _ -> nil
    end
  end

  def mutation_help(verb, %Document{} = doc, worker) do
    id = strip_draft_prefix(doc.doc_id)
    epoch = get_in(doc.content || %{}, ["claim", "epoch"])
    help_templates(verb, id, worker, epoch)
  end

  # After a claim the loop is: pulse (heartbeat), stamp-as-you-go, close.
  defp help_templates(verb, id, worker, epoch) when verb in [:claim, :claim_by_id] do
    [
      ~s|bp task pulse #{id} #{worker} --now "<one line: what you are doing right now>"|,
      stamp_template(id, worker, epoch, "0"),
      close_template(id, worker, epoch)
    ]
  end

  # After a stamp (epoch unchanged) or a pulse (epoch BUMPED — `epoch` here is
  # already the fresh one): stamp the next criterion, or seal with close.
  defp help_templates(verb, id, worker, epoch) when verb in [:stamp, :pulse] do
    [
      stamp_template(id, worker, epoch, "<N>"),
      close_template(id, worker, epoch)
    ]
  end

  # The claim is gone — the next command is the next task.
  defp help_templates(verb, _id, worker, _epoch) when verb in [:close, :release] do
    [~s|bp task next #{worker}|]
  end

  defp stamp_template(id, worker, epoch, index) do
    ~s|bp task stamp #{id} #{worker} #{epoch} --criterion #{index} --met --evidence "..." | <>
      ~s|--criterion-text "<acceptance_criteria[#{index}].criterion, verbatim>"|
  end

  defp close_template(id, worker, epoch) do
    ~s|bp task close #{id} #{worker} #{epoch} done "<summary of what shipped>"|
  end

  # ─── Acceptance-criteria close-out (living-values §8/§9) ─────────────────

  # Parses the optional close-body `criteria` list: each update targets ONE
  # acceptance_criteria row and flips met/evidence — SHAPE-only validation here
  # (pure); state conflicts (index out of range, criterion guard mismatch, a
  # text that resolves to zero or many rows) are the close transaction's to
  # detect under its lock. Returns {:ok, updates} or {:error, :invalid_criteria,
  # msg} (→ 400).
  #
  # ─── THE CLOSE INPUT CONTRACT (gh-2314) ─────────────────────────────────
  #
  # An entry names its row in one of two dialects, and ONE COMMAND SPEAKS ONE
  # DIALECT:
  #
  #   1. INDEXED (guarded)  `{"index": N, "met"?: bool, "evidence"?: str,
  #                           "criterion"?: str}`
  #      N is 0-based. `met: true` REQUIRES a non-empty `criterion` equal to the
  #      stored wording at N (D56 — an unguarded index flips a neighbour in
  #      silence). Unchanged, byte for byte: every existing caller keeps working.
  #
  #   2. TEXT-KEYED  `{"criterion": "<the exact stored wording>", "met"?: bool,
  #                    "evidence"?: str}` — NO index.
  #      This is the AUTHORING rubric shape: the row as `bp task get` prints it.
  #      The server resolves the index by exact match inside the close's own
  #      transaction (`Tasks.Internal.merge_criteria/2`).
  #
  # NORMALIZATION. A text-keyed entry becomes the indexed+guarded entry it
  # resolves to, then follows the identical path — same CAS, same rev, same
  # atomicity. There is no second write path and no second set of semantics.
  #
  # DUPLICATES. Resolution refuses rather than guesses: no stored row with that
  # exact wording → 409 `criterion_not_found`; two or more → 409
  # `criterion_ambiguous` (pass `"index"` to disambiguate). Nothing is written.
  #
  # ABSENT EVIDENCE. A text-keyed `met: true` REQUIRES a non-empty `evidence`
  # string (400 here, before any transaction). Rationale: the indexed dialect
  # pays for its met-flip with the text guard, and for the text-keyed dialect
  # that guard is free (the text IS the key) — so without this the NEW door
  # would be the cheapest way in the system to flip a lock. It also costs an
  # honest caller nothing: a rubric row read back from the document already
  # carries its evidence. (The indexed dialect's evidence stays presence-
  # sensitive — omitted preserves, `""` clears — so no existing close changes
  # behaviour.)
  #
  # MIXED SHAPES ARE REJECTED. A list mixing indexed and text-keyed entries is a
  # 400: the two dialects resolve rows by different keys, and interleaving them
  # makes "which row did entry 3 hit?" unanswerable from the request alone. An
  # entry carrying BOTH `index` and `criterion` is NOT mixed — that is dialect 1
  # with its mandatory guard.
  def parse_criteria(nil), do: {:ok, []}

  def parse_criteria(list) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case parse_criteria_entry(entry) do
        {:ok, update} -> {:cont, {:ok, [update | acc]}}
        {:error, msg} -> {:halt, {:error, :invalid_criteria, msg}}
      end
    end)
    |> case do
      {:ok, updates} -> updates |> Enum.reverse() |> check_criteria_dialect()
      other -> other
    end
  end

  def parse_criteria(_other),
    do:
      {:error, :invalid_criteria,
       "criteria must be a list of {index, met, evidence, criterion} objects, " <>
         "or of text-keyed {criterion, met, evidence} rubric rows"}

  # One dialect per command — see MIXED SHAPES above.
  defp check_criteria_dialect(updates) do
    {indexed, text_keyed} = Enum.split_with(updates, &Map.has_key?(&1, "index"))

    if indexed != [] and text_keyed != [] do
      {:error, :invalid_criteria,
       "criteria mixes two shapes in one command: #{length(indexed)} indexed " <>
         "{index,…} entr#{if length(indexed) == 1, do: "y", else: "ies"} and " <>
         "#{length(text_keyed)} text-keyed {criterion,…} entr#{if length(text_keyed) == 1, do: "y", else: "ies"}. " <>
         "Pick one: give EVERY entry an \"index\" (0-based, with \"criterion\" as the text guard on any " <>
         "met=true), or give NO entry an index and key every row by its exact stored \"criterion\" wording. " <>
         "Nothing was written."}
    else
      {:ok, updates}
    end
  end

  defp parse_criteria_entry(%{"index" => index} = entry) when is_integer(index) and index >= 0 do
    met = Map.get(entry, "met", true)
    evidence = Map.get(entry, "evidence")
    criterion = Map.get(entry, "criterion")

    cond do
      not is_boolean(met) ->
        {:error, "criteria[].met must be a boolean when set"}

      not (is_nil(evidence) or is_binary(evidence)) ->
        {:error, "criteria[].evidence must be a string when set"}

      not (is_nil(criterion) or is_binary(criterion)) ->
        {:error, "criteria[].criterion must be a string when set (stored-text guard)"}

      true ->
        update = %{"index" => index, "met" => met}
        update = if is_binary(evidence), do: Map.put(update, "evidence", evidence), else: update

        update =
          if is_binary(criterion), do: Map.put(update, "criterion", criterion), else: update

        {:ok, update}
    end
  end

  # Dialect 2 — the AUTHORING rubric row, keyed by its exact stored wording.
  # Shape-only here; the text→index resolution (and its not-found / ambiguous
  # refusals) belongs to the close transaction, which is the only place that can
  # read the stored list under the lock.
  defp parse_criteria_entry(%{"criterion" => criterion} = entry)
       when is_binary(criterion) and criterion != "" and not is_map_key(entry, "index") do
    met = Map.get(entry, "met", true)
    evidence = Map.get(entry, "evidence")

    cond do
      not is_boolean(met) ->
        {:error, "criteria[].met must be a boolean when set"}

      not (is_nil(evidence) or is_binary(evidence)) ->
        {:error, "criteria[].evidence must be a string when set"}

      met == true and not (is_binary(evidence) and String.trim(evidence) != "") ->
        {:error,
         "a text-keyed criteria entry with met=true must carry non-empty \"evidence\" — " <>
           "evidence or nothing. (The {index,…} shape guards a met-flip with its \"criterion\" " <>
           "text; the text-keyed shape gets that guard for free, so it pays with proof instead. " <>
           "A rubric row read back from `bp task get` already has its evidence.) Nothing was written."}

      true ->
        update = %{"criterion" => criterion, "met" => met}
        {:ok, if(is_binary(evidence), do: Map.put(update, "evidence", evidence), else: update)}
    end
  end

  defp parse_criteria_entry(_other),
    do:
      {:error,
       "each criteria entry needs EITHER an integer \"index\" >= 0 (0-based, with \"criterion\" as " <>
         "the text guard on any met=true) OR a non-empty \"criterion\" naming its row by the exact " <>
         "stored wording — the rubric shape `bp task get` prints. One shape per command."}

  # ─── Mid-claim criterion stamp (expressive-agent-loops D8) ───────────────

  # Parses the stamp body/query into `{:ok, index, {:met, evidence} | {:miss,
  # note} | {:withdraw, note}, criterion_text}`. `--withdraw` (D745) is the
  # verb that LOWERS a met flag: it needs a non-empty --note and, like --met, a
  # --criterion-text (enforced server-side, so lowering the wrong neighbour
  # fails closed exactly as raising it does). The bp CLI sends flags as query strings ("true",
  # "0"); curl sends typed JSON — both shapes are accepted. Exactly one of
  # met/miss; --met REQUIRES non-empty evidence (evidence or nothing, D3);
  # --miss REQUIRES a non-empty note (an honest attempt has words). --miss is
  # ALSO the one verb accepted on a DONE / CANCELLED row (with --observed-rev),
  # because it pins met and writes no evidence; --met never is.
  # `criterion_text` is the OPTIONAL 0-based/off-by-one guard: the criterion's
  # expected stored text, threaded into the stamp's criteria-grain CAS so a
  # wrong (in-range) index is rejected (`:criteria_mismatch`) instead of
  # flipping a neighbour. Read from BOTH `criterion_text` (JSON body) and
  # `criterion-text` (the kebab manifest flag → query key). SHAPE-only
  # validation (→ 400); state conflicts are the stamp transaction's to detect
  # under its lock.
  def parse_stamp(params) do
    met = stamp_flag?(Map.get(params, "met"))
    miss = stamp_flag?(Map.get(params, "miss"))
    withdraw = stamp_flag?(Map.get(params, "withdraw"))
    criterion_text = stamp_criterion_text(params)

    with {:ok, index} <- parse_stamp_index(Map.get(params, "criterion")) do
      cond do
        Enum.count([met, miss, withdraw], & &1) > 1 ->
          {:error, :invalid_stamp, "pass exactly one of --met / --miss / --withdraw, not two"}

        met ->
          case Map.get(params, "evidence") do
            e when is_binary(e) and e != "" -> {:ok, index, {:met, e}, criterion_text}
            _ -> {:error, :invalid_stamp, "--met requires non-empty --evidence"}
          end

        miss ->
          case Map.get(params, "note") do
            n when is_binary(n) and n != "" -> {:ok, index, {:miss, n}, criterion_text}
            _ -> {:error, :invalid_stamp, "--miss requires non-empty --note"}
          end

        withdraw ->
          case Map.get(params, "note") do
            n when is_binary(n) and n != "" ->
              {:ok, index, {:withdraw, n}, criterion_text}

            _ ->
              {:error, :invalid_stamp,
               "--withdraw requires non-empty --note (why it was withdrawn)"}
          end

        # A body that carries `met=false` and nothing else names no verb at
        # all. Say so with the withdrawal in the sentence, because "met: false"
        # is precisely what a caller reaches for when they mean to withdraw.
        true ->
          {:error, :invalid_stamp,
           "pass one of --met (with --evidence), --miss (with --note) or --withdraw (with --note). " <>
             "A met:true -> met:false patch is NOT accepted here: --withdraw is the verb that lowers " <>
             "a met flag, and it signs the correction instead of erasing the proof."}
      end
    end
  end

  @landed_criterion_msg "criterion must be a non-negative integer index into acceptance_criteria " <>
                          "(0-BASED — the FIRST criterion is 0). Omit it to record the landing " <>
                          "sentence without flipping anything."

  @doc """
  Parses the OPTIONAL `criterion` index off a landing mark. Absent / `nil` /
  blank means "record the sentence, flip nothing" — the default shape — so it
  is `{:ok, nil}`, not an error. Anything present must be a non-negative
  integer (JSON body int, or the manifest flag's query-string spelling).

  SHAPE only (→ 400). Whether the index RESOLVES, whether that row is
  merge-shaped and whether it is already met are state questions, answered
  under `Tasks.Landed`'s lock as 409s.
  """
  @spec parse_landed_criterion(term()) ::
          {:ok, non_neg_integer() | nil} | {:error, :invalid_landed, String.t()}
  def parse_landed_criterion(nil), do: {:ok, nil}
  def parse_landed_criterion(""), do: {:ok, nil}
  def parse_landed_criterion(n) when is_integer(n) and n >= 0, do: {:ok, n}

  def parse_landed_criterion(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, :invalid_landed, @landed_criterion_msg}
    end
  end

  def parse_landed_criterion(_), do: {:error, :invalid_landed, @landed_criterion_msg}

  @doc """
  The two SHAPE rules a landing mark must satisfy before any DB work:

    * at least one of `commit` / `pr` / `note` carries something — a landing
      mark with nothing to say would burn a rev and emit an event that says
      nothing;
    * a `criterion` flip carries a `note`, because the note IS the evidence
      written onto the criterion. A met with empty evidence is the exact shape
      `Tasks.Stamp` refuses as `:evidence_required`.

  Blank / whitespace-only strings count as ABSENT under both rules, matching
  `Tasks.Landed`'s own trim, so `commit=" "` is a 400 here rather than an
  `:empty_landing` 409 one layer down.
  """
  @spec check_landed_payload(map(), non_neg_integer() | nil) ::
          :ok | {:error, :invalid_landed, String.t()}
  def check_landed_payload(params, criterion) do
    note = landed_present(Map.get(params, "note"))

    cond do
      is_nil(landed_present(Map.get(params, "commit"))) and
        is_nil(landed_present(Map.get(params, "pr"))) and is_nil(note) ->
        {:error, :invalid_landed,
         "a landing mark must carry at least one of commit, pr, note — there is nothing to record"}

      not is_nil(criterion) and is_nil(note) ->
        {:error, :invalid_landed,
         "note is required with criterion: the note IS the evidence written onto that criterion, " <>
           "and a met flip with empty evidence is not a sealed row"}

      true ->
        :ok
    end
  end

  # A landing field counts as present only when it has content. Integers (a JSON
  # `pr`) are present by definition; blank/whitespace strings are not.
  defp landed_present(v) when is_integer(v), do: v

  defp landed_present(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      s -> s
    end
  end

  defp landed_present(_), do: nil

  @doc """
  Reads the LEAD-ONLY `--merge-gated` override off a stamp request, from the
  kebab manifest flag (query key `merge-gated`) or the snake JSON body key.
  Absent / anything but a truthy scalar → `false`: the override must be ASKED
  FOR, never inferred, because it is the one flag that lets a caller flip a
  row the lead owns.
  """
  @spec stamp_merge_gated(map()) :: boolean()
  def stamp_merge_gated(params) do
    stamp_flag?(Map.get(params, "merge_gated") || Map.get(params, "merge-gated"))
  end

  @doc """
  Reads the `--supersede` override off a stage request, from the manifest flag
  (query key `supersede`) or the JSON body key. Absent / anything but a truthy
  scalar → `nil`, which `put_opt` drops and `Tasks.Stage` reads as `false`.

  Opt-in per call, never inferred: the flag IS the caller stating they read the
  note they are about to displace, and a default-on or sticky spelling would
  give back exactly the silent overwrite the refusal exists to stop.
  """
  @spec stage_supersede(map()) :: true | nil
  def stage_supersede(params) do
    if stamp_flag?(Map.get(params, "supersede")), do: true, else: nil
  end

  @doc """
  Bounds a disposition_reason for an error envelope. Returns
  `{excerpt, truncated?}`: the note verbatim when it fits, otherwise its first
  #{@note_excerpt_limit} graphemes with an ellipsis and `true`.

  Notes of 1228 characters are on the live ledger, so a refusal that inlines
  one whole could dwarf its own remedy; the caller is told the TRUE length
  beside the excerpt and `bp task events --payload` keeps the full text either
  way. Cut on graphemes, not bytes — a multibyte reason must not come back
  mangled by the very message telling the caller to read it.
  """
  @spec note_excerpt(String.t()) :: {String.t(), boolean()}
  def note_excerpt(note) when is_binary(note) do
    if String.length(note) <= @note_excerpt_limit do
      {note, false}
    else
      {String.slice(note, 0, @note_excerpt_limit) <> "…", true}
    end
  end

  @doc """
  Reads the withdrawal's read-before-write fence (D745) off a stamp request,
  from the kebab manifest flag (query key `observed-rev`) or the snake JSON
  body key. `nil` when absent or blank — `Tasks.Stamp` then answers
  `:observed_rev_required` for a withdrawal on a row with no claim, rather than
  guessing a rev on the caller's behalf.
  """
  @spec stamp_observed_rev(map()) :: String.t() | nil
  def stamp_observed_rev(params) do
    case Map.get(params, "observed_rev") || Map.get(params, "observed-rev") do
      s when is_binary(s) and s != "" -> s
      _ -> nil
    end
  end

  defp stamp_flag?(v), do: v in [true, "true", "1"]

  # The optional criterion-text guard, from either wire shape. A non-string /
  # blank value is treated as absent (nil) — the permissive index-only path.
  defp stamp_criterion_text(params) do
    case Map.get(params, "criterion_text") || Map.get(params, "criterion-text") do
      s when is_binary(s) and s != "" -> s
      _ -> nil
    end
  end

  defp parse_stamp_index(n) when is_integer(n) and n >= 0, do: {:ok, n}

  defp parse_stamp_index(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, :invalid_stamp, "criterion must be an integer index >= 0"}
    end
  end

  defp parse_stamp_index(_),
    do: {:error, :invalid_stamp, "criterion (the index) is required — --criterion N"}

  def changeset_errors(%Ecto.Changeset{} = cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
