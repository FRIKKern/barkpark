defmodule Barkpark.Tasks.Fleet do
  @moduledoc """
  Personal Dev Fleet presence — the zero-row heartbeat (`bp fleet beat`) and
  the fail-closed roster (`bp fleet roster`) over `type:"listener"` documents.

  A listener (a dev-server/agent session running the fleet-listener protocol)
  is a citizen of the ledger: one document of type `"listener"`, keyed on its
  `worker` string (`_id` = `listener-<worker>`). A heartbeat is ONE atomic
  in-place write; the roster is ONE server-side read that computes
  online/offline at read time. Four verbs total in the fleet vocabulary, no
  order protocol — orders stay `type:task` documents.

  ## Naming disambiguation (the repo's FOURTH "fleet", FOURTH heartbeat)

  Three other "fleets" live in this codebase — this module is NONE of them:

    * `bp cloud instance` fleet — Hetzner instance lifecycle (cloud/).
    * the chat TUI's `fleetWatch` — a Go chat-session watcher.
    * the herd layer's `FleetHub` — herd-run process supervision.

  And three other heartbeats/"pulses" — also NONE of them:

    * bare `Barkpark.Pulse` — Shared Storm's presence substrate.
    * `Barkpark.Tasks.Pulse` — the task-LEASE heartbeat (`bp task pulse`),
      which renews a claim on a task row. A listener holds no claim, so a
      beat NEVER routes through `Tasks.Pulse` (its `check_holder` would
      always refuse a row with no claim).
    * the Go taskboard's `pulseMsg` — an SSE-keepalive tick.

  THIS module is fleet PRESENCE: who is listening, doing what, since when.

  ## The zero-row beat (PDF-D17)

  Registration (first beat for a worker) goes through the plain
  `Content.create_document/4` path — one revision row for a rare event is
  fine. Every subsequent beat is ONE atomic `Repo.update_all` under the
  advisory lock family `"listener:<logical_id>"` (its OWN family — never
  `"task:"`, which serializes claim/close/sweep): ZERO `mutation_events`
  insert, ZERO revision row, ZERO audit row, NO PubSub broadcast. The roster
  is a poll-read; no consumer needs beats as events (live-measured, PDF-D17).

  `last_seen` is stamped from `DateTime.utc_now/0` INSIDE the write — clients
  send `ttl_s` as data, never "now".

  ## The workspace-scoped roster (supersedes PDF-D19's global read)

  OWNER RULING, 2026-09-01 (task-4e2986e8609670d7, criterion 0), verbatim:

  > orchestrator, delegated; owner informed 2026-09-01 — RULED A: scope the
  > roster read with scope_opts(conn); the global view is for the OPERATOR
  > tier only, NOT any `admin` bit.

  PDF-D19 made this read GLOBAL-per-dataset with NO workspace clause, copying
  `Barkpark.Tasks.Board.snapshot/1`'s shape. Its stated argument was
  AVAILABILITY — "a workspace-filtered read fail-closes to EMPTY on a nil
  workspace; the global shape makes that bug impossible" — never isolation,
  and it cost tenancy: `beat/3` stamps a listener with the caller's
  `workspace_id`, while the roster listed EVERY workspace's listeners, plus
  the doc_id of each worker's in-progress task, to any bearer holding `read`.
  The read now matches the write:

    * a resolved `opts[:workspace_id]` (what `ScopeHelpers.scope_opts/1` hands
      every HTTP request) → that workspace's listeners only;
    * the `:shared_only` sentinel (a REQUEST that resolved no workspace) → the
      shared `workspace_id IS NULL` layer only, never every tenant;
    * `nil`, or no `:workspace_id` at all → NO rows. FAIL CLOSED: an empty
      roster, never everything. That is precisely the case PDF-D19 defended
      against, and the ruling settles it the other way.

  There is NO global arm an HTTP request can reach. The ruling reserves the
  cross-tenant view for an OPERATOR tier, and `api/` has no operator predicate
  today (it lives in `cloud/` as `require_platform_operator`), so none is
  built here — `GET /v1/fleet/roster` is workspace-scoped, full stop. When the
  operator tier lands (task-c7e2b87f1bbca815) a global roster belongs behind
  it, and NOT behind an `admin` bit, which the ruling explicitly refuses.

  The one internal opt-in is `roster/2`'s `global: true`, and the Studio
  `/admin/fleet` tile (`Barkpark.Plugins.Tasks.Web.FleetLive`, `:ops`-gated)
  is its only caller — it has no request scope to thread and would otherwise
  render permanently empty. It is named, greppable, reachable from no route,
  and the first thing the operator tier should absorb.

  Staleness is unchanged: computed at read time, never stored. A row whose
  `last_seen` is missing, unparsable, or older than its OWN `ttl_s` reads
  `"offline"` (fail closed); a fresh row reads its stored self-declared
  status.
  """

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Tasks.LockKey
  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Content.Scope
  alias Barkpark.Repo

  @type_name "listener"
  @default_ttl_s 120
  # PDF-D23: a beat may self-declare ONLY these. `provisioning` is written by
  # the cloud provisioner (Wave C), never by a beat; `offline` is derived at
  # read time, never stored.
  @self_declared_statuses ~w(idle working blocked)
  @stored_statuses @self_declared_statuses ++ ["provisioning"]
  # PDF-D6/D7: capacity size classes drive best-fit routing (light -> lean,
  # heavy -> big). A beat that declares a size_class MUST use this vocab —
  # the observed off-vocab `"big"` is refused, not silently stored.
  @size_classes ~w(light standard heavy xl)

  @doc "The default self-declared staleness budget, in seconds."
  def default_ttl_s, do: @default_ttl_s

  @doc """
  The BEAT-declarable listener statuses (PDF-D23). `provisioning` is stored
  vocab too, but provisioner-written (Wave C) — a beat cannot declare it;
  `offline` is derived at read time, never stored.
  """
  def statuses, do: @self_declared_statuses

  @doc """
  Heartbeat: upsert the caller's listener row, keyed on `params["worker"]`.

  First beat for a worker REGISTERS it (plain `Content` create — one revision
  row, rare). Every later beat is the zero-row write (see moduledoc): one
  atomic CAS-on-rev `Repo.update_all` under `pg_advisory_xact_lock` on
  `"listener:<logical_id>"`, merging into content:

    * `last_seen` — ALWAYS, ISO8601, computed server-side inside the write.
    * `status` / `agent` / `scope` / `capacity` / `ttl_s` — only when the
      beat provides them (`ttl` is accepted as an alias for `ttl_s`).

  `opts` carry the caller's tenant scope (`ScopeHelpers.scope_opts(conn)`), and
  BOTH halves of the beat run under it: the RESOLVE that decides
  register-vs-touch is workspace-scoped through the same `scope_to/2` the
  roster uses (binary → equality, `:shared_only` → `workspace_id IS NULL`,
  `nil`/absent → NO rows, fail closed), and the registration create stamps it.
  Before task-8d083ef87c7d0022 only the create was scoped: the resolve keyed on
  `(type, dataset, doc_id)` alone, so a beat from workspace A for a worker NAME
  workspace B had registered landed on B's row and CAS-merged A's state into
  it. Project is deliberately NOT narrowed — same reasoning as `roster_scope/1`.

  Returns `{:ok, receipt}` with
  `%{registered: boolean, doc: %{...}}`, or `{:error, :missing_worker |
  :invalid_status | :invalid_ttl | :invalid_capacity | :stale_beat |
  :worker_name_taken | :unscoped_beat}`
  (`:invalid_capacity` = a structured capacity that violates the contract, see
  `put_capacity/2`; `:stale_beat` = a non-beat writer raced the CAS; safe to
  retry — the next beat lands; `:worker_name_taken` = the scoped resolve found
  nothing but ANOTHER tenant already owns that row's identity leaf
  `(doc_id, type, dataset_id)` — an honest refusal, never a silent touch;
  `:unscoped_beat` = `opts` carried no resolvable workspace, see
  `beat_workspace/1`, unreachable from any HTTP request).
  """
  def beat(params, dataset, opts \\ []) when is_map(params) and is_binary(dataset) do
    with {:ok, workspace_id} <- beat_workspace(opts),
         {:ok, worker} <- fetch_worker(params),
         {:ok, fields} <- beat_fields(params) do
      logical_id = @type_name <> "-" <> slug(worker)

      case canonical_row(logical_id, dataset, workspace_id) do
        nil -> register(logical_id, worker, fields, dataset, opts)
        %Document{} = doc -> touch(doc, logical_id, fields)
      end
    end
  end

  # FAIL CLOSED on an unresolved tenant, the same posture `roster/2` documents —
  # and here it is a WRITE, so it matters more. Scoping only the RESOLVE would
  # leave one door open: with `workspace_id: nil` the resolve correctly finds
  # nothing, but `register/5` then hands those same nil-scope opts to
  # `Content.create_document/4`, whose prev-doc lookup runs through
  # `Scope.scope_to_workspace_or_global/3` — and THAT helper reads a nil
  # workspace as "every tenant" (the sign-flip documented in `Content.Scope`).
  # The create would find another workspace's row as `prev_doc` and UPDATE it,
  # re-stamping its scope to NULL — the very cross-tenant write this function
  # just closed, one call deeper. No HTTP request can reach this arm
  # (`ScopeHelpers.scope_opts/1` always emits a real id or `:shared_only`); it
  # guards the internal caller.
  defp beat_workspace(opts) do
    case Keyword.get(opts, :workspace_id) do
      workspace_id when is_binary(workspace_id) -> {:ok, workspace_id}
      :shared_only -> {:ok, :shared_only}
      _ -> {:error, :unscoped_beat}
    end
  end

  # ─── Roster ────────────────────────────────────────────────────────────────

  @doc """
  The fleet roster: every listener in `dataset` THE CALLER'S WORKSPACE OWNS,
  with ONLINE/OFFLINE computed at read time (fail closed) and the worker's
  current task joined in.

  Rows are string-keyed maps (`worker`, `agent`, `scope`, `status`,
  `capacity`, `last_seen`, `ttl_s`, `task`) sorted by `worker`, ready for the
  `{"ok": true, "documents": [...]}` envelope every installed `bp` binary
  renders as a real table (PDF-D21). `opts[:now]` injects the clock (tests).

  Tenancy opts (the 2026-09-01 ruling — see the moduledoc):

    * `:workspace_id` — a binary scopes to that workspace; `:shared_only`
      reads the shared `workspace_id IS NULL` layer; `nil` or absent returns
      NO rows (fail closed). Pass `ScopeHelpers.scope_opts(conn)` straight in.
    * `:global` — `true` is the ONE explicit cross-tenant opt-in, held by the
      `:ops`-gated Studio tile alone. No HTTP request can set it.
  """
  # @canonical capability:fleet-presence-staleness aka:online,offline,roster,ttl
  def roster(dataset, opts \\ []) when is_binary(dataset) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    scope = roster_scope(opts)
    tasks_by_worker = current_tasks_by_worker(dataset, scope)

    dataset
    |> load_listeners(scope)
    |> Enum.map(&to_row(&1, tasks_by_worker, now))
    |> Enum.sort_by(& &1["worker"])
  end

  # The tenant scope BOTH roster queries run under — resolved once so the
  # listener read and the task join can never disagree about who is asking.
  #
  # Project is deliberately NOT narrowed. The ruling scopes the roster to the
  # TENANT boundary, and that boundary is the workspace; a beat does stamp
  # `project_id` (registration goes through `Content.create_document/4` with
  # the caller's write opts), so adding it would split one workspace's fleet
  # across its projects and drop the task join for a listener whose task lives
  # in a sibling project — an availability loss no criterion asks for. The
  # `:project_id` in `scope_opts(conn)` is therefore read and ignored, here.
  defp roster_scope(opts) do
    if Keyword.get(opts, :global) == true,
      do: :global,
      else: {:workspace, Keyword.get(opts, :workspace_id)}
  end

  # `Content.Scope` owns every arm: binary → equality, `:shared_only` →
  # `workspace_id IS NULL`, nil → `where: false` (fail closed, barkpark-s6t1).
  # The global arm is `scope_to_workspace_global/1`, the codebase's named
  # "I want all tenants' rows" opt-in — deliberate and greppable, not a default.
  # Reached ONLY when `opts[:global] == true` (`roster_scope/1`): a nil
  # `workspace_id` never lands here — it takes the fail-closed
  # `scope_to_workspace/3` arm below (`where: false`), and no HTTP route can
  # pass `:global` (tripwire: no-route-passes-global test). Tenant-scope gate:
  # global-read: the :ops-gated Studio fleet tile's explicit cross-tenant opt-in
  defp scope_to(query, :global), do: Scope.scope_to_workspace_global(query)

  defp scope_to(query, {:workspace, workspace_id}),
    do: Scope.scope_to_workspace(query, workspace_id, nil)

  # Workspace-scoped read (the 2026-09-01 ruling — see moduledoc): the same
  # clause `beat/3` stamps on the way in. Draft/published twins collapse to one
  # canonical row (published wins), Board-style.
  defp load_listeners(dataset, scope) do
    from(d in Document, where: d.type == @type_name and d.dataset == ^dataset)
    |> scope_to(scope)
    |> Repo.all()
    |> Enum.group_by(fn d -> Content.published_id(d.doc_id) end)
    |> Enum.map(fn {_lid, twins} -> canonical_twin(twins) end)
  end

  defp canonical_twin(twins) do
    Enum.find(twins, hd(twins), fn d -> d.status == "published" end)
  end

  # Read-time join: worker -> the doc_id of its current in_progress task.
  # Identity follows the board_live.ex precedent: claim.worker || assignee.
  # Most-recently-updated wins when a worker somehow holds several.
  #
  # Carries the SAME scope as load_listeners/2 — this half leaked too: the
  # `task` column is a published doc_id, so an unscoped join handed a caller
  # in workspace A the id of a task being worked in workspace B.
  defp current_tasks_by_worker(dataset, scope) do
    from(d in Document,
      where: d.type == "task" and d.dataset == ^dataset,
      where: fragment("?->>'lifecycle_status' = 'in_progress'", d.content)
    )
    |> scope_to(scope)
    |> Repo.all()
    |> Enum.group_by(fn d -> Content.published_id(d.doc_id) end)
    |> Enum.map(fn {_lid, twins} -> canonical_twin(twins) end)
    |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
    |> Enum.reduce(%{}, fn doc, acc ->
      case task_worker(doc.content || %{}) do
        nil -> acc
        worker -> Map.put_new(acc, worker, Content.published_id(doc.doc_id))
      end
    end)
  end

  defp task_worker(content) do
    claim_worker = get_in(content, ["claim", "worker"])

    case {claim_worker, Map.get(content, "assignee")} do
      {w, _} when is_binary(w) and w != "" -> w
      {_, a} when is_binary(a) and a != "" -> a
      _ -> nil
    end
  end

  defp to_row(%Document{content: content}, tasks_by_worker, now) do
    content = content || %{}
    worker = Map.get(content, "worker")

    %{
      "worker" => worker,
      "agent" => Map.get(content, "agent"),
      "scope" => Map.get(content, "scope"),
      "status" => presence_status(content, now),
      "capacity" => Map.get(content, "capacity"),
      "last_seen" => Map.get(content, "last_seen"),
      "ttl_s" => effective_ttl(content),
      "task" => worker && Map.get(tasks_by_worker, worker)
    }
  end

  # Fail-closed staleness: missing or unparsable last_seen = offline; older
  # than the row's OWN ttl_s = offline; fresh = the stored self-declared
  # status. Derived — never written back to the row.
  defp presence_status(content, now) do
    case parse_last_seen(content) do
      nil ->
        "offline"

      %DateTime{} = seen ->
        if DateTime.diff(now, seen, :second) > effective_ttl(content) do
          "offline"
        else
          stored_status(content)
        end
    end
  end

  defp parse_last_seen(content) do
    with iso when is_binary(iso) <- Map.get(content, "last_seen"),
         {:ok, dt, _offset} <- DateTime.from_iso8601(iso) do
      dt
    else
      _ -> nil
    end
  end

  defp effective_ttl(content) do
    case Map.get(content, "ttl_s") do
      ttl when is_integer(ttl) and ttl > 0 -> ttl
      _ -> @default_ttl_s
    end
  end

  defp stored_status(content) do
    case Map.get(content, "status") do
      s when s in @stored_statuses -> s
      _ -> "idle"
    end
  end

  # ─── Beat internals ────────────────────────────────────────────────────────

  defp fetch_worker(params) do
    case Map.get(params, "worker") do
      w when is_binary(w) ->
        case String.trim(w) do
          "" -> {:error, :missing_worker}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_worker}
    end
  end

  # The optional self-declared fields a beat may carry. Only PROVIDED keys are
  # merged (an omitted key preserves the stored value). `ttl` aliases `ttl_s`.
  defp beat_fields(params) do
    with {:ok, fields} <- put_status(%{}, Map.get(params, "status")),
         {:ok, fields} <- put_ttl(fields, Map.get(params, "ttl_s") || Map.get(params, "ttl")),
         {:ok, fields} <- put_capacity(fields, Map.get(params, "capacity")) do
      fields =
        Enum.reduce(["agent", "scope"], fields, fn key, acc ->
          case Map.get(params, key) do
            v when is_binary(v) and v != "" -> Map.put(acc, key, v)
            _ -> acc
          end
        end)

      {:ok, fields}
    end
  end

  defp put_status(fields, nil), do: {:ok, fields}

  defp put_status(fields, s) when s in @self_declared_statuses,
    do: {:ok, Map.put(fields, "status", s)}

  defp put_status(_fields, _), do: {:error, :invalid_status}

  defp put_ttl(fields, nil), do: {:ok, fields}

  defp put_ttl(fields, ttl) when is_integer(ttl) and ttl > 0,
    do: {:ok, Map.put(fields, "ttl_s", ttl)}

  defp put_ttl(fields, ttl) when is_binary(ttl) do
    case Integer.parse(ttl) do
      {n, ""} when n > 0 -> {:ok, Map.put(fields, "ttl_s", n)}
      _ -> {:error, :invalid_ttl}
    end
  end

  defp put_ttl(_fields, _), do: {:error, :invalid_ttl}

  # Capacity: the routing-relevant self-declaration (size_class + slots +
  # budget) that lets the orchestrator route heavy->big / light->lean off real
  # heartbeats (PDF-D6/D7). Three accepted shapes, mirroring put_status/put_ttl:
  #
  #   (a) a native map (an in-process/JSON-body object) — VALIDATED, stored.
  #   (b) a Jason-decodable JSON OBJECT string — decoded, VALIDATED, stored as
  #       the map. Load-bearing for the CLI whose `--capacity` rides the query
  #       string as `type:"string"` (zero Go): the JSON travels as a string.
  #   (c) any other plain string — a LEGACY free-form hint ("1 task"), stored
  #       verbatim, unvalidated (backward compatibility).
  #
  # A validated map that violates the contract (off-vocab size_class, negative
  # or inverted slots, negative budget) is REFUSED with {:error,
  # :invalid_capacity} — the silent-drop trap sealed: bad structured capacity
  # never lands as a stored-but-ignored blob.
  defp put_capacity(fields, nil), do: {:ok, fields}
  defp put_capacity(fields, ""), do: {:ok, fields}
  defp put_capacity(fields, cap) when is_map(cap), do: validate_capacity(fields, cap)

  defp put_capacity(fields, cap) when is_binary(cap) do
    case Jason.decode(cap) do
      # (b) a JSON object string -> validate the decoded map.
      {:ok, decoded} when is_map(decoded) -> validate_capacity(fields, decoded)
      # (c) a JSON scalar or non-JSON string -> legacy free-form hint, as-is.
      _ -> {:ok, Map.put(fields, "capacity", cap)}
    end
  end

  defp put_capacity(_fields, _), do: {:error, :invalid_capacity}

  # Strict structured-capacity validation. size_class is REQUIRED and on-vocab;
  # slots (when present) are non-negative ints with slots_free <= slots_total;
  # budget (when present) is a non-negative number. Passing → store the
  # validated MAP; any violation → {:error, :invalid_capacity}.
  defp validate_capacity(fields, cap) do
    with :ok <- check_size_class(Map.get(cap, "size_class")),
         :ok <- check_slots(Map.get(cap, "slots_total"), Map.get(cap, "slots_free")),
         :ok <- check_budget(Map.get(cap, "budget")) do
      {:ok, Map.put(fields, "capacity", cap)}
    else
      :invalid -> {:error, :invalid_capacity}
    end
  end

  defp check_size_class(sc) when sc in @size_classes, do: :ok
  defp check_size_class(_), do: :invalid

  defp check_slots(total, free) do
    cond do
      not valid_slot?(total) -> :invalid
      not valid_slot?(free) -> :invalid
      is_integer(total) and is_integer(free) and free > total -> :invalid
      true -> :ok
    end
  end

  defp valid_slot?(nil), do: true
  defp valid_slot?(n) when is_integer(n) and n >= 0, do: true
  defp valid_slot?(_), do: false

  defp check_budget(nil), do: :ok
  defp check_budget(n) when is_number(n) and n >= 0, do: :ok
  defp check_budget(_), do: :invalid

  # `_id` slug: worker strings are agent-supplied — normalize to the doc-id
  # alphabet so `listener-<worker>` is always a valid, stable doc_id.
  defp slug(worker) do
    worker
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9._-]+/, "-")
    |> String.trim("-")
  end

  # The canonical row for a logical id, UNDER THE CALLER'S WORKSPACE:
  # draft/published twins collapse, published wins (Board idiom).
  # `Content.create_document` prefixes new rows with `drafts.`, so the beat must
  # look at BOTH shapes.
  #
  # The workspace clause is load-bearing (task-8d083ef87c7d0022). `logical_id`
  # is `"listener-" <> slug(params["worker"])` — a RAW request string on a
  # `:token_root` route — and this resolve decides register-vs-touch. Unscoped,
  # it handed `touch/3` whatever tenant's row shared the name, and `touch/3`
  # CAS-merged the caller's state into it. It runs through the SAME `scope_to/2`
  # arms `roster/2` does, so read and write can never disagree about who is
  # asking; project stays un-narrowed for the reason `roster_scope/1` states.
  defp canonical_row(logical_id, dataset, workspace_id) do
    ids = [logical_id, "drafts." <> logical_id]

    from(d in Document,
      where: d.type == @type_name and d.dataset == ^dataset and d.doc_id in ^ids
    )
    |> scope_to({:workspace, workspace_id})
    |> Repo.all()
    |> case do
      [] -> nil
      twins -> canonical_twin(twins)
    end
  end

  # Registration: the plain Content path (revision row + mutation_event are
  # FINE here — registration is rare, and the mutation_event it emits carries
  # type "listener", which the type=="task" filters structurally exclude).
  defp register(logical_id, worker, fields, dataset, opts) do
    content =
      %{
        "worker" => worker,
        "status" => "idle",
        "ttl_s" => @default_ttl_s,
        "last_seen" => now_iso()
      }
      |> Map.merge(fields)

    attrs = %{"doc_id" => logical_id, "title" => worker, "content" => content}

    case Content.create_document(@type_name, attrs, dataset, opts) do
      {:ok, %Document{} = doc} -> {:ok, receipt(doc, true)}
      {:error, %Ecto.Changeset{} = cs} -> {:error, register_changeset_reason(cs)}
      {:error, reason} -> {:error, reason}
    end
  end

  # The scoped resolve found nothing, so this beat is a REGISTRATION — and the
  # insert lost to the `(doc_id, type, dataset_id)` unique index, which means
  # some OTHER tenant already owns this worker name's row. `Document.changeset`
  # maps that index to a `constraint: :unique` error, so the changeset is the
  # only honest signal available here. Answer with a NAMED refusal
  # (`:worker_name_taken` → HTTP 409) instead of leaking a changeset: before the
  # scope clause this collision could not happen, because the resolve simply
  # returned the other tenant's row and the beat quietly wrote to it.
  defp register_changeset_reason(%Ecto.Changeset{errors: errors} = cs) do
    if Enum.any?(errors, fn {_field, {_msg, meta}} ->
         Keyword.get(meta, :constraint) == :unique
       end) do
      :worker_name_taken
    else
      # Every other changeset failure keeps its historical shape — the caller
      # still gets the changeset, and the controller still renders it as
      # `beat_failed`. Only the unique collision is reclassified.
      cs
    end
  end

  # The zero-row beat: ONE atomic CAS-on-rev update under the listener
  # advisory-lock family. No mutation_event, no revision, no audit row, no
  # broadcast (PDF-D17). Lock keys on the LOGICAL id so draft/published twins
  # of the same worker serialize on one lock.
  defp touch(%Document{} = doc, logical_id, fields) do
    result =
      Repo.transaction(fn ->
        _ =
          Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
            LockKey.listener(logical_id)
          ])

        # In-lock re-read: beats serialize on the advisory lock, so the CAS
        # below only loses to a NON-beat writer (e.g. a Studio edit) racing
        # between this read and the write — that surfaces as :stale_beat.
        # global-read: by-PK re-read inside the listener-beat advisory lock — same posture as pulse.ex/stamp.ex/ttl_sweeper; `canonical_row/3` resolved this PK under the caller's own workspace scope, so re-reading it by id adds no reach.
        case Repo.get(Document, doc.id) do
          nil -> {:error, :stale_beat}
          %Document{} = fresh -> apply_beat(fresh, fields)
        end
      end)

    case result do
      {:ok, {:ok, updated}} -> {:ok, receipt(updated, false)}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_beat(%Document{content: content} = doc, fields) do
    observed_rev = doc.rev
    new_rev = Barkpark.Tasks.Internal.generate_rev()

    new_content =
      (content || %{})
      |> Map.merge(fields)
      # Server-stamped INSIDE the write — clients never send "now".
      |> Map.put("last_seen", now_iso())
      |> Map.put_new("ttl_s", @default_ttl_s)

    # PDS-D451, PAID FOR FENCE-CONSISTENCY, NOT BECAUSE IT LIED. `receipt/2`
    # below projects only content-derived keys, so the beat receipt is
    # WIRE-CONVERGENT today and was measured convergent before this change.
    # That honesty is incidental — it holds only as long as nobody adds `rev`
    # or `updated_at` to the projection — so the arm returns the stored row
    # like its six siblings, and the projection is pinned by a test.
    case Barkpark.Tasks.Internal.fenced_content_write(doc, observed_rev, new_content, new_rev) do
      {:ok, updated} -> {:ok, updated}
      :stale -> {:error, :stale_beat}
    end
  end

  defp receipt(%Document{content: content} = doc, registered?) do
    content = content || %{}

    %{
      registered: registered?,
      doc: %{
        "id" => Content.published_id(doc.doc_id),
        "worker" => Map.get(content, "worker"),
        "status" => Map.get(content, "status"),
        "last_seen" => Map.get(content, "last_seen"),
        "ttl_s" => effective_ttl(content)
      }
    }
  end

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
