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
  alias Barkpark.Tasks.{Criteria, QueueGate}
  alias Barkpark.Tasks.Edge
  alias Barkpark.Tasks.Query, as: TaskQuery

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
    |> put_brief_engagement(content)
    |> put_brief_disposition(content)
    |> Map.put(:claim, brief_claim(Map.get(content, "claim")))
    |> prune_nils()
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

  # Augment the base render_doc map with the three count fields the
  # `bp task` list/ready shapes carry (dependency_count + dependent_count
  # from batch_edge_counts; comment_count fixed at 0 until the comment
  # substrate ships — TODO: wire when comment substrate exists).
  def render_doc_with_counts(%Document{} = doc, counts) do
    {dep_count, dependent_count} = Map.get(counts, doc.id, {0, 0})

    doc
    |> render_doc()
    |> Map.put(:dependency_count, dep_count)
    |> Map.put(:dependent_count, dependent_count)
    |> Map.put(:comment_count, 0)
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

  @route_filters %{
    index: %{
      label: "GET /v1/tasks",
      keys: @index_filter_keys,
      flat: "kind, lifecycle_status, parent, phase_id, label, type"
    },
    ready: %{
      label: "GET /v1/tasks/ready",
      keys: @ready_filter_keys,
      flat: "phase_id, order, limit, offset"
    },
    prime: %{label: "GET /v1/tasks/prime", keys: @prime_filter_keys, flat: "worker, order, limit"},
    events: %{label: "GET /v1/tasks/events", keys: @events_filter_keys, flat: "since, limit"}
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
        ~s|The 0-BASED index alone is unverifiable and can flip a neighbouring criterion. An entry with met=false needs no text.|

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
        ~s|a withdrawal against. Pin the rev you read instead: re-read with `bp task get <id> -o json`, take | <>
        ~s|.doc.rev, and re-run the withdrawal with --observed-rev <rev>. Nothing was written. A withdrawal | <>
        ~s|never touches the seal, the close_reason or the original evidence — it lowers the met flag and | <>
        ~s|appends a signed record naming who withdrew it and why.|

  def criteria_hint(:criterion_not_met, :stamp),
    do:
      ~s|this criterion is already met=false, so there is no stamped proof to withdraw and nothing was | <>
        ~s|written — a withdrawal record on an already-honest row would only mislead the next reader. | <>
        ~s|If you meant to record a failed attempt on it, that is --miss --note "…". Check the index: | <>
        ~s|--criterion N is 0-BASED, so the first criterion is 0.|

  def criteria_hint(:criteria_mismatch, _surface),
    do:
      ~s|the criterion text you passed is NOT the wording stored at that index. Either the index is off by one | <>
        ~s|— it is 0-BASED, the FIRST criterion is 0 — or the list changed since you read it. Nothing was written. | <>
        ~s|Re-read `bp task get <id>` and pass the index and the wording of the SAME row.|

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

  def criteria_hint({:sentinel_worker_id, worker}, _surface),
    do:
      ~s|"#{worker}" is not a worker id — it is a missing value wearing a worker's clothes (empty, "None", | <>
        ~s|"null", "nil" or "-"). A close attributed to it reads as a real close to every downstream gate. | <>
        ~s|Pass the worker that actually holds the claim.|

  def criteria_hint(_reason, _surface), do: nil

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

  # Parses the optional close-body `criteria` list: each update targets one
  # acceptance_criteria row by index and flips met/evidence — SHAPE-only
  # validation here (pure); state conflicts (index out of range, criterion
  # guard mismatch) are the close transaction's to detect under its lock.
  # Returns {:ok, updates} or {:error, :invalid_criteria, msg} (→ 400).
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
      {:ok, updates} -> {:ok, Enum.reverse(updates)}
      other -> other
    end
  end

  def parse_criteria(_other),
    do:
      {:error, :invalid_criteria,
       "criteria must be a list of {index, met, evidence, criterion} objects"}

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

  defp parse_criteria_entry(_other),
    do: {:error, "each criteria entry needs an integer index >= 0"}

  # ─── Mid-claim criterion stamp (expressive-agent-loops D8) ───────────────

  # Parses the stamp body/query into `{:ok, index, {:met, evidence} | {:miss,
  # note} | {:withdraw, note}, criterion_text}`. `--withdraw` (D745) is the
  # verb that LOWERS a met flag: it needs a non-empty --note and, like --met, a
  # --criterion-text (enforced server-side, so lowering the wrong neighbour
  # fails closed exactly as raising it does). The bp CLI sends flags as query strings ("true",
  # "0"); curl sends typed JSON — both shapes are accepted. Exactly one of
  # met/miss; --met REQUIRES non-empty evidence (evidence or nothing, D3);
  # --miss REQUIRES a non-empty note (an honest attempt has words).
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
