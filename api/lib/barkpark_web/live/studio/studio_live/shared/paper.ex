defmodule BarkparkWeb.Studio.StudioLive.Shared.Paper do
  @moduledoc """
  Paper-editing helpers extracted from `StudioLive.Shared` (Modularity gate).

  These are the cohesive `paper_*` block-op / stream / view-setup helpers that
  drive the paper editor surface: applying block ops, reordering, descriptor
  expectations, backlink loading, the `:paper_blocks` stream, and live-delta
  application. They thread `socket` explicitly and are behaviour-preserving —
  moved verbatim from `Shared`. All are `@doc false`: an internal seam, not a
  public API. `Shared` re-exports each via `defdelegate` so existing
  `Shared.<fn>(...)` call sites keep working unchanged.

  The one call back into the staying module is `Shared.hook_opts/1` (used by
  `document_op/2`); `Shared` in turn calls `Paper.setup_paper_view/2` and
  `Paper.clear_paper_view/1` from `rebuild_panes/1`.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView

  alias Barkpark.Access
  alias Barkpark.Content
  alias Barkpark.Content.Labels
  alias Barkpark.PortableDoc.{HtmlSanitizer, Projection, Render, TaskResolver}
  alias BarkparkWeb.ScopeHelpers
  alias BarkparkWeb.Studio.Caps
  alias BarkparkWeb.Studio.StudioLive.Blocks
  alias BarkparkWeb.Studio.StudioLive.PaperCanvas
  alias BarkparkWeb.Studio.StudioLive.Shared

  @doc false
  def paper_op(socket, op) do
    cond do
      socket.assigns[:editor_view] == :form and socket.assigns[:editor_mode] == :beta and
          socket.assigns[:editor_doc] != nil ->
        document_op(socket, op)

      true ->
        paper_pane_op(socket, op)
    end
  end

  # Session-handoff (final review, F4): the paper PANE is now opened by every
  # blocks-doc type, not just "paper" (`PaneBuilder` keys on
  # `Content.blocks_type?/1`), but every write below is hardcoded to the
  # PAPER-only op path (`Content.apply_paper_block_op/4` /
  # `apply_paper_block_ops/4`, and `sync_paper_edit_doc/1`'s
  # `Content.get_paper/2`). Pointing those at a session either fails opaquely
  # ("Edit failed") or — worse — resolves a SAME-SLUG paper and edits the wrong
  # document.
  #
  # v1 ruling: a session pane is READ-ONLY in Studio. Guard at the two pane op
  # entry points (the only writers), refuse with an honest notice, and leave
  # the paper path byte-identical below. Sessions are edited through
  # `bp session publish` (the ingest API), which is the only writer that
  # understands a session's events trail + metadata contract.
  @read_only_pane_notice "Sessions are read-only in Studio (v1) — edit via bp session publish"

  # True when the open pane is a blocks-doc that is NOT a paper (today: a
  # session). `editor_type` is assigned by `Shared.rebuild_panes/1` from the
  # PaneBuilder editor map's `:type`, so it is the pane's real doc type.
  defp read_only_pane?(socket) do
    type = socket.assigns[:editor_type]
    Content.blocks_type?(type) and type != Content.paper_type()
  end

  defp refuse_read_only_pane(socket) do
    socket
    |> put_flash(:error, @read_only_pane_notice)
    |> assign(save_status: "Read-only")
    |> assign(last_paper_save_ok?: false)
  end

  # pds-w42 — THE PRINCIPAL GATE, AT THE CHOKEPOINT.
  #
  # The paper editor's composite field blocks (`composite` / `arrayOf` /
  # `codelist` / `localizedText`) render as a nested `PaperFieldBlock`
  # LiveComponent, and that component does NOT write: it does
  # `send(self(), {:paper_op, op})`, which lands in `StudioLive`'s
  # `handle_info({:paper_op, …})` and arrives HERE. `Caps.attach/1`'s
  # `:studio_caps_gate` is an `attach_hook(_, :handle_event, _)`, and no
  # `handle_event` hook — parent socket or component socket — can see a
  # `handle_info`. So a write-denied principal reached persisted state through
  # this door while the SAME intent sent as the `paper-op` EVENT was halted by
  # the socket gate. A capability PROP on the component (the wave-41 SheetGrid
  # remedy) would be inert here for the same reason: the component is not the
  # writer.
  #
  # ONE RULE, NOT A FORK: the predicate is `Caps.write_capable?/2` — the same
  # single copy the socket-level gate uses — fed FRESH caps (`Caps.derive/1`
  # reloads grants, so mid-session expiry denies immediately). The flash is the
  # gate's own wording so both seams speak one vocabulary.
  #
  # SCOPE, HONESTLY: this denies any principal `Caps` denies write — a
  # read-only api_token or read-only member. It is silent on a principal-LESS
  # socket, because `write_capable?/2` returns TRUE there BY DESIGN (the
  # intentionally-open public-demo posture). Nobody may read this as
  # "anonymous is now denied".
  # pds-w42-bl-handle-info-write-seam-audit — PUBLIC, because the paper ops are
  # not the only hook-invisible write door. The `handle_info` sweep found a
  # second one: `{:autosave_form, form}` → `Shared.do_autosave/2` →
  # `Content.upsert_draft`, which reached persisted state with no principal
  # check of its own. That seam calls THESE two functions rather than
  # re-deriving the rule, so the two doors cannot drift into two answers to
  # "may this principal write" — the acceptance criterion is explicitly "no
  # forked predicate".
  @write_denied_notice "You don't have access to do that."

  @doc """
  Is this socket's principal denied `:write`? The negation of
  `Caps.write_capable?/2` — THE single copy of the `:write` tier — fed FRESH
  caps, so a mid-session grant expiry denies immediately.

  Shared by every hook-invisible write seam (`paper_pane_op/2`, `paper_ops/2`,
  the block-op branch, and `Shared.do_autosave/2`). Do not re-derive it.
  """
  def write_denied?(socket) do
    not Caps.write_capable?(socket.assigns, Caps.derive(socket))
  end

  @doc """
  The refusal a write-denied seam returns: the deny-gate's own flash wording,
  plus a `save_status` that says "Read-only" instead of lying about a save.
  """
  def refuse_write_denied(socket) do
    socket
    |> put_flash(:error, @write_denied_notice)
    |> assign(save_status: "Read-only")
    |> assign(last_paper_save_ok?: false)
  end

  # pds-w44 (PDS-D644) — THE GRANT'S OWN NARROWING, TRAVELLED INTO THE DOOR.
  #
  # `write_denied?/1` above answers "may this PRINCIPAL write at all". It has no
  # TARGET, and it cannot get one: `Caps.write_capable?/2` takes an assigns map
  # plus a caps map, and it is the SheetGrid component prop's predicate too
  # (components.ex `read_only=`) — widening it would move a second surface and
  # still have no doc to reason about.
  #
  # But a GRANT is scoped down to a single `type`/`doc_id`, and for a
  # grant-graded socket that per-TARGET containment is the whole authorization.
  # `LiveScope.attach_write_gate/2` arms it as `attach_hook(_, :handle_event, _)`
  # (live_scope.ex) — and this door is a `handle_INFO`: `PaperFieldBlock.persist/2`
  # does `send(self(), {:paper_op, op})`, so no `handle_event` hook, parent or
  # component, ever observes it. Reproduced by run on origin/main: a signed-in
  # non-member holding a write grant naming ONE doc, mounting a DIFFERENT doc on
  # the same desk (read reach from a second, read-only grant), wrote it —
  # `%{"amount" => "ESCALATED"}` landed in the store. `Caps.derive/1` reports
  # `write: true` there quite correctly, because `Access.admits_desk?/3`
  # auto-satisfies the grant's OWN type/doc_id at desk granularity.
  #
  # So the door asks the SECOND question the socket gate would have asked: does
  # some ACTIVE grant admit `:write` at the scope of the doc ACTUALLY BEING
  # WRITTEN? The predicate is `Access.validate/3` — the same containment ladder
  # `attach_write_gate/2`'s `write_target_permitted?/4` uses, no parallel copy.
  #
  # NOT `Access.admits_desk?/3`: that helper OVERWRITES the requested scope's
  # `:type`/`:doc_id` with the grant's own before validating (its documented job
  # — a desk cannot name a type or a doc), which is exactly the mechanism that
  # lets a doc-scoped grant self-satisfy against any desk. Here the target's
  # real type + doc_id must survive into the check.
  #
  # ARMED ONLY FOR GRANT-DERIVED WRITE. A membership-derived socket carries no
  # `caller_context` and no `write_gate?`, so `grant_graded?/1` is false and this
  # arm returns `false` without loading anything — the member path is
  # byte-identical (no extra query, no new denial). Grants are loaded FRESH per
  # op, mirroring `Caps.derive/1`'s own unconditional reload, so a grant that
  # expired mid-session stops admitting immediately.
  #
  # FAIL-CLOSED on an unresolvable target (no workspace / project / dataset / no
  # loaded doc), matching `LiveScope.write_target/3`'s `:error -> halt`.
  @outside_grant_notice "That action is outside your access grant's scope"

  @doc """
  Is this socket's write of `type`/`doc_id` outside every ACTIVE grant it holds?

  The TARGET-aware companion to `write_denied?/1`, and the second question every
  hook-invisible write seam must ask. PUBLIC for the same reason `write_denied?/1`
  is: `Shared.do_autosave/2` — the `{:autosave_form, …}` `handle_info`, a third
  hook-invisible door — must ask it too, and must ask THIS copy. Do not
  re-derive it; a fork here is a fork in the authorization answer.

  Inert (`false`, no query) unless `grant_graded?/1`; fail-closed on an
  unresolvable target for a socket that IS grant-graded.
  """
  def grant_target_denied?(socket, type, doc_id) do
    grant_graded?(socket.assigns) and not grant_admits_target?(socket, type, doc_id)
  end

  # The doc's `type` / `doc_id`, read TOTALLY: a pane doc is a `%Content.Document{}`
  # in the live path but a bare map in the unit fixtures, so `doc.type` would
  # raise a KeyError on a shape that has always been legal here. A missing key
  # yields nil, which `write_target_scope/3` treats as an unresolvable target
  # (fail-closed for a grant-graded socket, inert for every other one).
  defp doc_field(doc, key) when is_map(doc), do: Map.get(doc, key)
  defp doc_field(_doc, _key), do: nil

  # The two assigns that mean "this socket's write descends from a GRANT":
  # `LiveScope.assign_grant_scope/2` sets `caller_context`, and
  # `attach_write_gate/2` sets `write_gate?`.
  defp grant_graded?(assigns) do
    not is_nil(Map.get(assigns, :caller_context)) or Map.get(assigns, :write_gate?) == true
  end

  defp grant_admits_target?(socket, type, doc_id) do
    case write_target_scope(socket, type, doc_id) do
      %{} = target ->
        socket
        |> active_grants()
        |> Enum.any?(&(Access.validate(&1, :write, target) == :ok))

      nil ->
        false
    end
  end

  # The desk levels come from the MOUNT and the leaf levels from the DOC being
  # written — the same broad→narrow ladder `LiveScope.write_target/3` feeds
  # `Access.validate/3`, including its `Content.published_id/1` normalisation so
  # a draft id is matched against the grant by its published identity.
  defp write_target_scope(socket, type, doc_id) do
    ws = socket.assigns[:current_workspace]
    proj = socket.assigns[:current_project]
    dataset = socket.assigns[:dataset]

    if is_map(ws) and is_binary(Map.get(ws, :id)) and is_map(proj) and
         is_binary(Map.get(proj, :id)) and is_binary(dataset) and is_binary(type) and
         is_binary(doc_id) do
      %{
        workspace_id: ws.id,
        project_id: proj.id,
        dataset: dataset,
        type: type,
        doc_id: Content.published_id(doc_id)
      }
    end
  end

  # Grants bind to a grantee USER; only a `current_user` can hold any. Fresh,
  # active-filtered load — the same call `Caps.derive/1` makes for expiry truth.
  defp active_grants(socket) do
    case socket.assigns[:current_user] do
      %{id: uid} when is_binary(uid) -> Access.list_active_grants_for_grantee(uid)
      _ -> []
    end
  end

  @doc """
  The refusal a grant-graded seam returns when the TARGET is outside its grant:
  the containment flash plus the same honest `save_status` the write-denied
  refusal uses. Shared, so every door speaks one vocabulary.
  """
  def refuse_outside_grant(socket) do
    socket
    |> put_flash(:error, @outside_grant_notice)
    |> assign(save_status: "Read-only")
    |> assign(last_paper_save_ok?: false)
  end

  @doc false
  def paper_pane_op(socket, op) do
    paper = socket.assigns[:paper_doc]
    slug = paper && paper.doc_id
    dataset = socket.assigns.dataset

    cond do
      # pds-w42 — FIRST, because a denied principal must not learn anything
      # from the pane's own vetoes. See write_denied?/1.
      write_denied?(socket) ->
        refuse_write_denied(socket)

      # pds-w44 — SECOND: capable, but is THIS doc inside the grant? See
      # grant_target_denied?/3. Silent for membership-derived write.
      grant_target_denied?(socket, doc_field(paper, :type), slug) ->
        refuse_outside_grant(socket)

      read_only_pane?(socket) ->
        refuse_read_only_pane(socket)

      is_nil(slug) ->
        assign(socket, last_paper_save_ok?: false)

      true ->
        case Content.apply_paper_block_op(
               slug,
               op,
               dataset,
               BarkparkWeb.ScopeHelpers.scope_opts(socket)
             ) do
          {:ok, _result} ->
            socket
            |> resync_pane_after_op()
            |> assign(save_status: "Auto-saved")
            |> assign(last_paper_save_ok?: true)
            # A prior halt cleared: the next accepted edit dismisses the banner.
            |> assign(paper_halt: nil)

          # A constraint veto (pdd-t20) carries a human-readable reason —
          # surface it so a calmly-rejected edit explains itself.
          {:error, {:constraint, message, _op}} ->
            socket
            |> put_flash(:error, constraint_flash(message))
            |> assign(save_status: "Save failed")
            |> assign(last_paper_save_ok?: false)

          # A lifecycle-hook HALT (server-owned quality gate — the hollow-doc
          # gate from sibling p-hollow-gate-server lands here) carries a
          # human-readable reason. MIRROR the server truth: raise the banner
          # with the reason verbatim, never invent copy here (D5/D6).
          {:error, {:halted, reason}} ->
            put_paper_halt(socket, reason)

          {:error, _reason} ->
            socket
            |> put_flash(:error, "Edit failed")
            |> assign(save_status: "Save failed")
            |> assign(last_paper_save_ok?: false)
        end
    end
  end

  @doc false
  # Phase-4 S2: fold an ORDERED ARRAY of ops (one bp-canvas-ops batch from a
  # <bp-paper-canvas> run) through the PAPER-PANE persist + sync path —
  # specifically paper_pane_op/2's (NOT the full paper_op/2, which also has a
  # document_op branch for the Beta per-document editor). That is safe because
  # the canvas is gated to the paper pane only (paper_block_editor canvas_eligible
  # — see components/paper_editor.ex), so a batch never originates in the
  # document editor. Only the batch primitive differs from the per-block path:
  # apply_paper_block_ops/4 vs apply_paper_block_op/3 (both atomic, both folding
  # via Patch.apply_patch). No new model / schema / storage. Guards a non-list or
  # empty batch — and a nil paper_doc — as a no-op so a stray event never writes.
  # Mirrors paper_pane_op/2's load (current paper_doc slug), apply (atomic fold),
  # persist (one Repo.update), and re-sync (sync_paper_edit_doc → View re-streams).
  def paper_ops(socket, ops) when is_list(ops) and ops != [] do
    paper = socket.assigns[:paper_doc]
    slug = paper && paper.doc_id
    dataset = socket.assigns.dataset

    cond do
      # pds-w42 — same principal gate as paper_pane_op/2, for the same reason
      # the read-only-pane guard is duplicated here: a batch reaches this seam
      # WITHOUT passing through paper_pane_op/2. See write_denied?/1.
      write_denied?(socket) ->
        refuse_write_denied(socket)

      # pds-w44 — the batch path needs the target narrowing for the same reason
      # it needs the principal gate: a canvas run reaches this seam WITHOUT
      # passing through paper_pane_op/2. Same doc, same predicate.
      grant_target_denied?(socket, doc_field(paper, :type), slug) ->
        refuse_outside_grant(socket)

      # Same v1 read-only guard as paper_pane_op/2 — see its comment. The batch
      # path needs its own: a canvas run reaches here without passing through
      # paper_pane_op/2.
      read_only_pane?(socket) ->
        refuse_read_only_pane(socket)

      is_nil(slug) ->
        assign(socket, last_paper_save_ok?: false)

      true ->
        case Content.apply_paper_block_ops(
               slug,
               ops,
               dataset,
               BarkparkWeb.ScopeHelpers.scope_opts(socket)
             ) do
          {:ok, _result} ->
            # Re-read the paper (apply_paper_block_ops returns only the batch
            # receipt %{slug, op_count, rev, block_ids} — NOT the post-apply
            # blocks), assigning the fresh paper_doc. The View pane re-streams off
            # that, AND it carries the CONFIRMED blocks we echo back to the canvas.
            socket
            |> sync_paper_edit_doc()
            |> push_canvas_echo()
            |> push_task_previews()
            |> push_block_renders()
            # A LANDED batch must SAY it landed. The batch path used to assign
            # save_status only on its three error branches, so the footer save
            # region ([data-test-id="bp-paper-footer-save"], the page's only
            # role="status" aria-live region) could say "Save failed" or nothing
            # — never success. Measured on the deployed build: after a save the
            # API proved persisted, that region was the EMPTY STRING for 25s
            # while the footer counts moved. Same "Auto-saved" token the
            # single-op path (paper_pane_op/2) already assigns — ONE vocabulary
            # across both write seams, no third state and NO in-flight
            # "Saving…" transient (charter D242 defers pending feedback).
            |> assign(save_status: "Auto-saved")
            |> assign(last_paper_save_ok?: true)
            # A prior halt cleared: the next accepted batch dismisses the banner.
            |> assign(paper_halt: nil)

          # A constraint veto (pdd-t20) carries a human-readable reason —
          # surface it so a calmly-rejected batch explains itself. Mark the
          # save failed too, matching the single-op path — a rejected batch
          # must never leave a stale "Auto-saved" on screen.
          {:error, {:constraint, message, _op}} ->
            socket
            |> put_flash(:error, constraint_flash(message))
            |> assign(save_status: "Save failed")
            |> assign(last_paper_save_ok?: false)

          # A lifecycle-hook HALT on the batch path. The batch branch never set
          # save_status on error before — put_paper_halt/2 fixes that so a
          # rejected canvas run reads "Save failed" just like the single-op
          # path, and raises the server reason verbatim in the mirror banner.
          {:error, {:halted, reason}} ->
            put_paper_halt(socket, reason)

          {:error, _reason} ->
            socket
            |> put_flash(:error, "Edit failed")
            |> assign(save_status: "Save failed")
            |> assign(last_paper_save_ok?: false)
        end
    end
  end

  def paper_ops(socket, _ops), do: assign(socket, last_paper_save_ok?: false)

  @doc false
  def paper_ops(socket, ops, request_id) do
    {socket, revoked_token?} = refresh_replay_token(socket)
    paper = socket.assigns[:paper_doc]
    slug = paper && paper.doc_id
    dataset = socket.assigns.dataset

    invalid_credential? =
      socket.assigns[:api_token_credential_present?] == true and
        is_nil(socket.assigns[:api_token]) and is_nil(socket.assigns[:current_user])

    cond do
      invalid_credential? ->
        {:error, refuse_write_denied(socket)}

      revoked_token? and is_nil(socket.assigns[:current_user]) ->
        {:error, refuse_write_denied(socket)}

      write_denied?(socket) ->
        {:error, refuse_write_denied(socket)}

      grant_target_denied?(socket, doc_field(paper, :type), slug) ->
        {:error, refuse_outside_grant(socket)}

      read_only_pane?(socket) ->
        {:error, refuse_read_only_pane(socket)}

      not (is_binary(slug) and is_list(ops) and ops != []) ->
        {:error, assign(socket, save_status: "Save failed", last_paper_save_ok?: false)}

      true ->
        case Content.apply_paper_block_ops_once(
               slug,
               ops,
               dataset,
               request_id,
               replay_principal_key(socket),
               BarkparkWeb.ScopeHelpers.scope_opts(socket)
             ) do
          {:ok, receipt, outcome} ->
            socket =
              socket
              |> sync_paper_edit_doc()
              |> push_canvas_echo()
              |> push_task_previews()
              |> push_block_renders()
              |> assign(save_status: "Auto-saved")
              |> assign(last_paper_save_ok?: true)
              |> assign(paper_halt: nil)

            {:ok, socket, receipt, outcome}

          {:error, {:constraint, message, _op}} ->
            {:error,
             socket
             |> put_flash(:error, constraint_flash(message))
             |> assign(save_status: "Save failed", last_paper_save_ok?: false)}

          {:error, {:halted, reason}} ->
            {:error, put_paper_halt(socket, reason)}

          {:error, _reason} ->
            {:error,
             socket
             |> put_flash(:error, "Edit failed")
             |> assign(save_status: "Save failed", last_paper_save_ok?: false)}
        end
    end
  end

  defp refresh_replay_token(socket) do
    current_user = socket.assigns[:current_user]

    case socket.assigns[:api_token] do
      %{id: _} ->
        case socket.assigns[:api_token_raw] do
          raw when is_binary(raw) and raw != "" ->
            case Barkpark.Auth.verify_token(raw) do
              {:ok, token} ->
                {assign(socket, api_token: token), false}

              _ when is_nil(current_user) ->
                # Preserve the stale struct as identity-only evidence that this
                # was an authenticated token socket. The revoked flag prevents
                # Caps from treating it as public-demo, including on every
                # subsequent retry returned from this handler.
                {socket, true}

              _ ->
                {assign(socket, api_token: nil), false}
            end

          _ when is_nil(current_user) ->
            {socket, true}

          _ ->
            {assign(socket, api_token: nil), false}
        end

      nil ->
        {socket, false}

      _ when is_nil(current_user) ->
        {socket, true}

      _ ->
        {assign(socket, api_token: nil), false}
    end
  end

  defp replay_principal_key(%{assigns: %{current_user: %{id: id}}}) when is_binary(id),
    do: "user:" <> id

  defp replay_principal_key(%{assigns: %{api_token: %{id: id}}}) when is_binary(id),
    do: "token:" <> id

  defp replay_principal_key(%{assigns: %{api_token_credential_present?: true}}), do: nil
  defp replay_principal_key(_socket), do: "public-demo"

  # ── spd-bl-publish-affordance-triple — the hand path's missing affordances ──
  #
  # Three writers, one guard ladder. The sidebar's description input, its
  # label-add form and the pane header's Publish control all funnel through
  # `paper_meta_write/2` below, which mounts the SAME three refusals — in the
  # SAME order — as `paper_pane_op/2` and `paper_ops/2`: principal first
  # (write_denied?), then grant containment, then the read-only pane. A sidebar
  # affordance must never write where a canvas op could not.
  #
  # DRAFT-ONLY BY CONSTRUCTION. Every one of these affordances exists to move a
  # hand-created draft toward (and through) the publish wall, and only a
  # genuine `drafts.<slug>` row can take these writes: `Writer.upsert_document`
  # forces `doc_id = DraftId.draft_id(raw_id)`, so pointing it at an in-place-
  # published paper would silently mint a drafts twin beside the published row
  # instead of editing it. The components render the controls only for
  # `status == "draft"`; the guard here is the server-side floor for a forged
  # event.

  @doc false
  def paper_meta_write(socket, fun) do
    paper = socket.assigns[:paper_doc]
    slug = paper && paper.doc_id

    cond do
      write_denied?(socket) ->
        refuse_write_denied(socket)

      grant_target_denied?(socket, doc_field(paper, :type), slug) ->
        refuse_outside_grant(socket)

      read_only_pane?(socket) ->
        refuse_read_only_pane(socket)

      is_nil(slug) ->
        socket

      doc_field(paper, :status) != "draft" ->
        socket

      true ->
        fun.(socket, paper)
    end
  end

  @doc false
  # Persist the sidebar's description field into `content["description"]` — the
  # first metadata the publish wall demands (LabelSpine fires on it before
  # anything else, and NO amount of body authoring moves it). Rev-fenced so a
  # concurrent canvas save is surfaced, never silently clobbered.
  def sidebar_description_change(socket, value) when is_binary(value) do
    paper_meta_write(socket, fn socket, paper ->
      content = Map.put(doc_field(paper, :content) || %{}, "description", value)
      persist_paper_meta(socket, paper, content)
    end)
  end

  @doc false
  # Append ONE complete weighted-tag entry — tag, strength 1..100, rationale —
  # to `content["tags"]`. The three field floors mirror the publish wall's own
  # entry rules (LabelSpine.check_entry) so a refused add says NOW, in the same
  # plain words, what publish would have said later; the wall itself stays the
  # sole authority (count, distinct strengths, duplicates, registry) and is
  # untouched per charter D229/D230.
  def sidebar_label_add(socket, params) when is_map(params) do
    paper_meta_write(socket, fn socket, paper ->
      tag = String.trim(to_string(params["tag"] || ""))
      rationale = String.trim(to_string(params["rationale"] || ""))

      strength =
        case Integer.parse(to_string(params["strength"] || "")) do
          {n, ""} -> n
          _ -> nil
        end

      cond do
        tag == "" ->
          put_flash(socket, :error, "A label needs a tag name.")

        not (is_integer(strength) and strength in 1..100) ->
          put_flash(socket, :error, "A label's strength must be a whole number from 1 to 100.")

        String.length(rationale) < 20 ->
          put_flash(
            socket,
            :error,
            "A label needs a rationale of at least 20 characters — say why this tag fits."
          )

        true ->
          content = doc_field(paper, :content) || %{}
          existing = if is_list(content["tags"]), do: content["tags"], else: []
          entry = %{"tag" => tag, "strength" => strength, "rationale" => rationale}
          persist_paper_meta(socket, paper, Map.put(content, "tags", existing ++ [entry]))
      end
    end)
  end

  @doc false
  # The paper pane's Publish action — the control the hand path never had. The
  # wall (`AuthoringWall.enforce` inside `Content.publish_document/4`) stays
  # UNCHANGED; this seam only gives a human the door and translates each
  # refusal into the same plain language `Shared.do_action/3` already speaks
  # for the form editor. A `{:halted, reason}` carries the Bulldocs hollow-body
  # copy verbatim ("…has a title but no content yet — add at least one body
  # block"), which is the block-0-heading skeleton trap surfaced honestly.
  def paper_publish(socket) do
    paper_meta_write(socket, fn socket, paper ->
      type = doc_field(paper, :type) || Content.paper_type()
      pid = Content.published_id(paper.doc_id)

      Barkpark.Content.Warnings.reset()

      case Content.publish_document(pid, type, socket.assigns.dataset, Shared.hook_opts(socket)) do
        {:ok, _published} ->
          # The draft row is gone; re-open the pane on the PUBLISHED identity
          # via the reserved ["open", type, id] path (the open_backlink route —
          # no structure lookup, no remount).
          socket
          |> put_flash(
            :info,
            Shared.with_advisories("Published", Barkpark.Content.Warnings.drain())
          )
          |> push_patch(
            to: Shared.studio_path(socket, ["open", type, pid], socket.assigns.dataset)
          )

        {:error, {:halted, reason}} ->
          put_flash(socket, :error, "Publish blocked: #{reason}")

        {:error, {:label_spine, details}} ->
          put_flash(socket, :error, "Publish blocked: #{Shared.format_wall_details(details)}")

        {:error, {:unknown_tag, payload}} ->
          put_flash(socket, :error, "Publish blocked: #{Shared.format_wall_details(payload)}")

        {:error, {:duplicate_of, payload}} ->
          put_flash(socket, :error, "Publish blocked: #{Shared.format_wall_details(payload)}")

        {:error, {:dedup_unavailable, _}} ->
          put_flash(
            socket,
            :error,
            "Publish blocked: the duplicate check is unavailable right now — try again in a moment."
          )

        {:error, {:invalid_epic_paper_quality, payload}} ->
          put_flash(socket, :error, "Publish blocked: #{Shared.format_wall_details(payload)}")

        {:error, _} ->
          put_flash(socket, :error, "Publish failed")
      end
    end)
  end

  # One writer for both sidebar metadata fields: whole-content upsert on the
  # draft row, rev-fenced against a concurrent canvas save (the fence surfaces
  # the race as a flash instead of silently reverting the newer blocks), then
  # the standard re-sync so chips/inputs re-render off the persisted truth.
  defp persist_paper_meta(socket, paper, content) do
    attrs = %{
      "doc_id" => doc_field(paper, :doc_id),
      "title" => doc_field(paper, :title),
      "content" => content
    }

    opts = Shared.hook_opts(socket) ++ [if_rev: doc_field(paper, :rev)]
    type = doc_field(paper, :type) || Content.paper_type()

    case Content.upsert_document(type, attrs, socket.assigns.dataset, opts) do
      {:ok, _doc} ->
        sync_paper_edit_doc(socket)

      {:error, {:rev_mismatch, _}} ->
        socket
        |> sync_paper_edit_doc()
        |> put_flash(
          :error,
          "The paper changed while you were editing — that metadata change was not saved; try again."
        )

      {:error, {:halted, reason}} ->
        put_flash(socket, :error, "Save cancelled: #{reason}")

      {:error, _} ->
        put_flash(socket, :error, "Save failed")
    end
  end

  # spd-w19 / D258 — THE WAY OUT HAS TO GET YOU OUT.
  #
  # After an accepted single op the pane used to re-assign `paper_doc` and
  # NOTHING else (`sync_paper_edit_doc/1`). That is correct while the pane is
  # ALREADY in block mode — the canvas re-renders off `paper_doc.content`, and
  # the read-only stream is kept live by the per-block delta path — but it is
  # exactly wrong on the ONE transition the never-blank notice exists to serve:
  # a resolved-but-unrenderable document whose repair button (`paper-add-block`)
  # MINTS the missing block list. The write landed, `paper_block_mode` stayed
  # false, and the notice re-rendered over a document that now had a real body.
  # The writer's own broadcast cannot rescue it either —
  # `Handlers.Lifecycle.paper_block/2` is a deliberate no-op for `sender ==
  # self()`.
  #
  # `refetch_paper/1` is the whole repair, and BOTH halves of it are load-bearing:
  # it re-derives `paper_block_mode` / `paper_rev` from the fresh document AND
  # fills the `:paper_blocks` stream. The assign half alone would flip
  # `paper_block_mode` true while the stream is still `setup_paper_view/2`'s
  # empty reset — under `BARKPARK_PAPER_CANVAS=0` (`show_editor` false) that
  # renders an `<article phx-update="stream">` with ZERO children: a NEW blank
  # of precisely the class this wave outlaws.
  #
  # It runs ONLY on the mode transition, keyed on the assign the render actually
  # branches on. In block mode the cheap path stays cheap — `refetch_paper/1`
  # re-renders every top-level block server-side, and paying that on every
  # keystroke-sized op would be a perf regression for zero rendered difference.
  defp resync_pane_after_op(socket) do
    if socket.assigns[:paper_block_mode] do
      sync_paper_edit_doc(socket)
    else
      refetch_paper(socket)
    end
  end

  # "constraint: at most 1 block of \"featured\" allowed, found 2" →
  # "Edit rejected — at most 1 block of \"featured\" allowed, found 2".
  defp constraint_flash(message) when is_binary(message),
    do: "Edit rejected — " <> String.replace_prefix(message, "constraint: ", "")

  defp constraint_flash(_), do: "Edit failed"

  @doc false
  # MIRROR a server-owned write halt in the paper canvas. Shared by
  # paper_pane_op/2 (single op) and paper_ops/2 (batch) so BOTH write seams
  # surface an identical halt: stash the verbatim server reason for the mirror
  # banner (editor.ex `paper_halt_banner`), flash the same copy, and mark the
  # save failed (the batch path never set save_status on error before). The
  # editor authors NO copy of its own (charter D5/D6) — the message is always
  # the server's reason string.
  def put_paper_halt(socket, reason) do
    message = halt_reason(reason)

    socket
    |> assign(paper_halt: message)
    |> put_flash(:error, message)
    |> assign(save_status: "Save failed")
    |> assign(last_paper_save_ok?: false)
  end

  # Normalise a lifecycle-hook halt reason into a display string. The paper
  # gate emits a binary (content/papers/block_ops.ex), which passes through
  # verbatim — the editor NEVER authors its own copy (D5/D6). A non-binary
  # reason falls back to the same inspect form the API envelope uses
  # (content/errors.ex halt_message/1) so the mirror can't diverge from the
  # server's own message.
  defp halt_reason(reason) when is_binary(reason) and reason != "", do: reason

  defp halt_reason(reason),
    do: "mutation vetoed by a plugin lifecycle hook: #{inspect(reason)}"

  @doc false
  # t9 — LIVE TASK-BLOCK PREVIEW push. Resolve every query-carrying task block in
  # the CURRENT editor blocks into id-keyed rows and push them to the task-block
  # node views on the `bp:task-preview` channel — SEPARATE from the :paper_blocks
  # stream and the canvas `data-canvas-blocks` seed. D5: DISPLAY ONLY. The blocks
  # the canvas saves against (paper_top_level_blocks) are NEVER touched, so a save
  # right after a preview emits ZERO ops (byte-stability, D3). No-op when the
  # canvas flag is OFF — nothing is mounted to receive it, so the OFF path pushes
  # nothing and stays byte-identical.
  def push_task_previews(socket) do
    if PaperCanvas.paper_canvas_enabled?() do
      previews = task_previews(paper_top_level_blocks(socket), socket)

      socket
      # The SERVER-RENDERED consumer: the id-keyed assign `task_block_preview/1`
      # (paper_editor.ex) paints live rows from, via the reader's own Render
      # producer (rule 3). t12a: after the partition flip a top-level fleet block
      # rides a canvas RUN (its display paint arrives via push_block_renders'
      # bp:block-html), so this boundary-widget path is DORMANT in the flag-ON
      # paper pane — retained infra, retirement is wave-4/human. Phoenix skips the
      # assign when the map is unchanged, so a no-op refresh re-renders nothing.
      |> assign(:paper_task_previews, Map.new(previews, &{&1["block_id"], &1}))
      # The CLIENT channel twin: the same rows for the canvas hook → the WC's
      # applyTaskPreviews (still a progressive no-op — the WC paints fleet HTML
      # from bp:block-html instead). Both carriers are display-only (D5).
      |> push_event("bp:task-preview", %{previews: previews})
    else
      socket
    end
  end

  # pdd-t8 (fleet-in-canvas) — the reader's non-prose COMPONENT emitters, the
  # canonical enumeration of blocks that render through `Render.render_block/2`'s
  # component fleet (render/components.ex + render/figures.ex asciicast +
  # render/forms.ex form). `diagram` is DELIBERATELY absent: it rides its own
  # editable `bpDiagram` attr-atom in the canvas, not the read-only server paint.
  # Keep aligned with run-convert.js:CANVAS_FLEET_TYPES.
  #
  # live-data task-list (bpTaskList) REUSES THIS CHANNEL unchanged: a query-carrying
  # `task-list` is already resolved here (fleet_block_html → task_previews →
  # apply_preview → render_block) and pushed on `bp:block-html` keyed by the block id.
  # The bpTaskList node-view paints the SAME id-keyed HTML into its `[data-bp-fleet-body]`
  # hole (identical selector to bpFleet) — so editing the query → patch-block{query} →
  # save → this push re-resolves the NEW query → repaints the rows. ZERO change needed
  # here: the widget only ADDS an editable query surface on top of the existing paint.
  @fleet_render_types ~w(tasks task-list task-detail task-board roadmap notes cards pipeline status-legend asciicast form questionnaire)

  # editable-figure — the CHILD-paint channel. A `figure` is NOT a component-fleet
  # block (keep it OUT of @fleet_render_types so it never drags through
  # task_previews/apply_preview OR renders the WHOLE figure). Instead the canvas
  # bpFigure atom paints ONLY the figure's CHILD, via the SAME `bp:block-html` hook,
  # keyed by the FIGURE id — so `push_block_renders` emits a child-only render for
  # every top-level figure.
  #
  # Keep aligned with run-convert.js:CANVAS_FIGURE_TYPES and
  # paper_canvas.ex:@canvas_figure_types.
  @figure_render_types ~w(figure)

  # pd-ee-dataviz-editors (charter D3) — the 5 DATA-VIZ kinds (Render.DataViz:
  # stat / stats / stat-grid / heatmap / chart; `stat-grid` is the accepted alias
  # of `stats`). They paint through the SAME `bp:block-html` channel + bpFleet atom
  # the component fleet uses — `Render.render_block(block, %{style: :article})`
  # routes them to the ONE DataViz emitter (compose.ex), byte-parity by
  # construction. A PARALLEL set, deliberately NOT folded into @fleet_render_types:
  # that set rides the 4-way lockstep with paper_editor.ex @fleet_preview_types
  # (the classic-mode boundary widget), and DataViz stays OUT of the classic paint
  # (charter D2 — classic keeps the read-only catch-all for these kinds). Literal
  # blocks render their carried data directly; query-bearing chart/heatmap/stat
  # blocks receive display-only aggregate attrs through task_previews.
  #
  # Keep aligned with run-convert.js CANVAS_DATAVIZ_TYPES and
  # paper_canvas.ex @canvas_dataviz_types.
  @dataviz_render_types ~w(stat stats stat-grid heatmap chart duel lineage)

  @doc false
  # pdd-t8 — FLEET-IN-CANVAS server paint. For EVERY top-level non-prose fleet
  # block, render the reader's OWN HTML (`Render.render_block(block, %{style:
  # :article})` — the SAME producer /papers and the t9 boundary widget use, rule 3
  # / D8) and push it id-keyed on `bp:block-html`. The canvas `bpFleet` node-view
  # paints it into its hole; until it arrives the node shows a loading chip.
  #
  # D5 (display only): task/query blocks are resolved through TaskResolver.preview
  # onto a COPY (apply_preview) — the source `blocks` (the save baseline the canvas
  # diffs / the ops the buttons emit) are NEVER touched, so a save right after a
  # paint emits ZERO ops (D3). Session-tenant-scoped + fail-closed via task_previews.
  # No-op when the canvas flag is OFF (nothing is mounted to receive it).
  def push_block_renders(socket) do
    if PaperCanvas.paper_canvas_enabled?() do
      blocks = paper_top_level_blocks(socket)
      previews = Map.new(task_previews(blocks, socket), &{&1["block_id"], &1})

      fleet_renders =
        blocks
        |> Enum.filter(&fleet_block?/1)
        |> Enum.map(fn block ->
          %{"block_id" => Map.get(block, "id"), "html" => fleet_block_html(block, previews)}
        end)

      # editable-figure: the CHILD-only render for every top-level figure, on the SAME
      # bp:block-html channel, keyed by the FIGURE id (so the bpFigure atom's paint
      # hole finds it with ZERO hook change). Concatenated with the fleet renders.
      figure_renders =
        blocks
        |> Enum.filter(&figure_block?/1)
        |> Enum.map(&figure_render/1)

      renders =
        (fleet_renders ++ figure_renders)
        |> Enum.reject(&(&1["block_id"] in [nil, ""]))

      push_event(socket, "bp:block-html", %{renders: renders})
    else
      socket
    end
  end

  # A block that paints through the fleet channel: a component-fleet kind OR a
  # data-viz kind (pd-ee-dataviz-editors — same bpFleet atom, same bp:block-html
  # push, same render_block(:article) producer).
  defp fleet_block?(block) when is_map(block),
    do:
      Map.get(block, "type") in @fleet_render_types or
        Map.get(block, "type") in @dataviz_render_types

  defp fleet_block?(_), do: false

  defp figure_block?(block) when is_map(block),
    do: Map.get(block, "type") in @figure_render_types

  defp figure_block?(_), do: false

  @doc false
  # editable-figure — the CHILD-only reader render for one figure block, keyed by the
  # FIGURE id. `Render.render_block(child, %{style: :article})` is BYTE-IDENTICAL to
  # figure_html's `child_html` (both compose_block(child,:article) |> Walk.render_body
  # at the article palette width; render_block additionally resolves
  # ref-title/code-label/redacts — no-ops on the common image/code children). A
  # non-map child (or a figure carrying no child) paints "" (an honest chip), matching
  # figure_html's `_ -> ""` branch — never the WHOLE figure (no <figcaption> leaks in,
  # which would double the editable caption).
  def figure_render(block) do
    html =
      case Map.get(block, "child") do
        child when is_map(child) ->
          case Render.render_block(child, %{style: :article}) do
            html when is_binary(html) -> html
            _ -> ""
          end

        _ ->
          ""
      end

    %{"block_id" => Map.get(block, "id"), "html" => html}
  end

  # Render one fleet block's reader HTML. A query-carrying task or data-viz block
  # is resolved against its session-scoped preview (attrs merged onto a COPY);
  # every other fleet block renders directly from its carried snapshot/data. An
  # error preview falls back to the unresolved block so the emitter degrades
  # gracefully rather than crashing the push.
  defp fleet_block_html(block, previews) do
    resolved =
      case Map.get(previews, Map.get(block, "id")) do
        %{"error" => true} -> block
        %{} = preview -> TaskResolver.apply_preview(block, preview)
        _ -> block
      end

    case Render.render_block(resolved, %{style: :article}) do
      html when is_binary(html) -> html
      _ -> ""
    end
  end

  @doc false
  # Build the id-keyed live-task previews for `blocks` under the SESSION's tenant
  # scope. Fail-closed: `scope_opts` carries the session's workspace/project — a
  # nil workspace resolves to ZERO rows/aggregate values in Tasks.Query, never a
  # cross-tenant leak. The row fetch may RAISE with the Tasks plugin off;
  # `TaskResolver.preview/3` rescues each row fetch into an `{ error: true }` stub.
  # Aggregate failure produces no preview entry, leaving the query block's dim
  # placeholder unchanged. Returns ONLY previews — `blocks` stays unresolved.
  def task_previews(blocks, socket) do
    scope = ScopeHelpers.scope_opts(socket)

    TaskResolver.preview(
      blocks,
      # The preview path NEVER stamps `dataset` into the block query, so the
      # visibility gate MUST be threaded the session dataset explicitly (the same
      # `socket.assigns.dataset` the agg fetcher below already carries) — deriving
      # it from the raw query map would seal against the wrong (production
      # default) schema on a cross-dataset preview. Charter W-one decision 10.
      fn query ->
        Barkpark.Tasks.Query.rows_for_query(query, scope, dataset: socket.assigns.dataset)
      end,
      fn query ->
        Barkpark.Tasks.Query.agg_for_query(query, scope, dataset: socket.assigns.dataset)
      end
    )
  end

  @doc false
  # Phase-4 S4a: ECHO the server-CONFIRMED blocks back to the <bp-paper-canvas>.
  #
  # Reads the post-apply blocks off the FRESH paper_doc (sync_paper_edit_doc just
  # assigned it), partitions them into the SAME maximal prose runs the editor
  # mounts (PaperCanvas.partition_runs — the identical keying components.ex uses),
  # and pushes `bp:canvas-update` carrying ONE entry per prose RUN: %{run_id:
  # <slug<>"-run-"<>ordinal>, blocks: <run blocks>}.
  #
  # Bug #1a: each run is keyed by the paper's SLUG + its ORDINAL in the partition
  # (via the SAME PaperCanvas.run_id/2 + with_run_ordinals/1 helpers components.ex
  # uses for the wrapper id), NOT its mutable first-block id. So the echo for run
  # `i` always matches the wrapper "paper-canvas-<slug>-run-<i>" that components.ex
  # rendered for run `i` — even when the run's LEADING block was just deleted/merged
  # (the run stays at the same ordinal). The slug half is Bug #1c: it keeps the id
  # unique ACROSS papers so a patch-navigation can never transplant a stale canvas
  # (see PaperCanvas.run_id/2). The inbound hook routes each run to its element by
  # that id.
  # Only `{:run, _}` segments are echoed — the non-prose `{:block, _}` boundaries
  # have no canvas to update. The canvas treats its OWN echo as a pure baseline
  # reset (no caret move); an external edit lands as a confirmed re-render. This
  # advances the canvas diff baseline so the NEXT batch is INCREMENTAL, not
  # cumulative-from-mount. No-op when the canvas flag is OFF (no canvas is mounted
  # to receive the event, but we also gate so the OFF path pushes nothing).
  def push_canvas_echo(socket) do
    if PaperCanvas.paper_canvas_enabled?() do
      {slug, blocks} =
        case socket.assigns[:paper_doc] do
          %{doc_id: doc_id, content: %{"blocks" => blocks}} when is_list(blocks) ->
            {doc_id, blocks}

          _ ->
            {nil, []}
        end

      runs =
        blocks
        |> PaperCanvas.partition_runs()
        |> PaperCanvas.with_run_ordinals()
        |> Enum.flat_map(fn
          {:run, run_blocks, ordinal} ->
            [%{run_id: PaperCanvas.run_id(slug, ordinal), blocks: run_blocks}]

          {:block, _block} ->
            []
        end)

      push_event(socket, "bp:canvas-update", %{runs: runs})
    else
      socket
    end
  end

  @doc false
  def document_op(socket, op) do
    doc = socket.assigns[:editor_doc]
    type = socket.assigns[:editor_type]
    dataset = socket.assigns.dataset

    cond do
      # pds-w42 — paper_op/2's OTHER branch. The `{:paper_op, …}` message is
      # routed by the same handle_info regardless of which branch it lands in,
      # so the Beta document block editor is reachable from the same
      # hook-invisible hop. Gate it with the one predicate. See write_denied?/1.
      write_denied?(socket) ->
        refuse_write_denied(socket)

      # pds-w44 — the BETA per-document editor writes `editor_doc`, not
      # `paper_doc`, so the target the grant must admit is THAT doc. Same arm,
      # fed the seam's own doc. See grant_target_denied?/3.
      grant_target_denied?(socket, type, doc_field(doc, :doc_id)) ->
        refuse_outside_grant(socket)

      true ->
        case Content.apply_document_block_op(
               doc.doc_id,
               type,
               op,
               dataset,
               Shared.hook_opts(socket)
             ) do
          {:ok, _result} ->
            socket
            |> sync_editor_blocks()
            |> assign(last_paper_save_ok?: true)

          {:error, _reason} ->
            socket
            |> put_flash(:error, "Edit failed")
            |> assign(last_paper_save_ok?: false)
        end
    end
  end

  @doc false
  def sync_editor_blocks(socket) do
    doc = socket.assigns[:editor_doc]
    type = socket.assigns[:editor_type]
    dataset = socket.assigns.dataset

    with %{doc_id: doc_id} <- doc,
         {:ok, fresh} <-
           Content.get_document(doc_id, type, dataset, ScopeHelpers.scope_opts(socket)) do
      {blocks, synth?} = Content.resolve_blocks_for_edit(fresh, type, dataset)

      assign(socket,
        editor_doc: fresh,
        editor_blocks: blocks,
        editor_blocks_synth?: synth?,
        editor_form: Content.doc_to_form(fresh, socket.assigns[:editor_schema])
      )
    else
      _ -> socket
    end
  end

  @doc false
  def paper_reorder(socket, _blocks, nil, _dir), do: socket

  def paper_reorder(socket, blocks, idx, "up") when idx > 0 do
    moved = Enum.at(blocks, idx)
    displaced = Enum.at(blocks, idx - 1)

    # pdd-t2: a template-locked block holds its position — both when it is the
    # MOVED block and when it is the block the swap would DISPLACE. The UI
    # already hides/disables these controls; this guard keeps a stale click (or
    # a context-menu race) a calm no-op instead of a rejected op + error flash.
    if locked_block?(moved) or locked_block?(displaced) do
      socket
    else
      after_id = if idx >= 2, do: Map.get(Enum.at(blocks, idx - 2), "id"), else: nil

      paper_op(socket, %{"op" => "move-block", "id" => Map.get(moved, "id"), "after" => after_id})
    end
  end

  def paper_reorder(socket, blocks, idx, "down") when idx < length(blocks) - 1 do
    moved = Enum.at(blocks, idx)
    displaced = Enum.at(blocks, idx + 1)

    if locked_block?(moved) or locked_block?(displaced) do
      socket
    else
      anchor_id = Map.get(displaced, "id")

      paper_op(socket, %{
        "op" => "move-block",
        "id" => Map.get(moved, "id"),
        "after" => anchor_id
      })
    end
  end

  def paper_reorder(socket, _blocks, _idx, _dir), do: socket

  # pdd-t2: whether a block is template-locked (nil-safe for Enum.at misses).
  defp locked_block?(block), do: is_map(block) and Map.get(block, "locked") == true

  @doc false
  def sync_paper_edit_doc(socket) do
    paper = socket.assigns[:paper_doc]
    slug = paper && paper.doc_id

    case slug && Content.get_paper(slug, socket.assigns.dataset) do
      %{} = fresh -> assign(socket, paper_doc: fresh)
      _ -> socket
    end
  end

  @doc false
  def paper_top_level_blocks(socket) do
    cond do
      socket.assigns[:editor_view] == :form and socket.assigns[:editor_mode] == :beta and
          is_list(socket.assigns[:editor_blocks]) ->
        socket.assigns[:editor_blocks]

      true ->
        case socket.assigns[:paper_doc] do
          %{content: %{"blocks" => blocks}} when is_list(blocks) -> blocks
          _ -> []
        end
    end
  end

  @doc false
  def paper_top_level_free(socket) do
    socket |> paper_top_level_blocks() |> Projection.partition() |> elem(1)
  end

  @doc false
  # Every expected `field` descriptor for the live editor block list (incl.
  # bound-and-at-cap). [] when there is no schema/Expectation.
  def paper_all_descriptors(socket) do
    case slash_expectation(socket) do
      %{layout: _} = expectation ->
        Content.all_expected_fields(
          paper_top_level_blocks(socket),
          expectation,
          socket.assigns[:editor_schema]
        )

      _ ->
        []
    end
  end

  @doc false
  def slash_insert_op(after_id, block) when is_binary(after_id) and after_id != "",
    do: %{"op" => "insert-after", "afterId" => after_id, "block" => block}

  def slash_insert_op(_after_id, block),
    do: %{"op" => "append-block", "block" => block}

  @doc false
  def expected_field_blocked?(socket, field_name) do
    case slash_expectation(socket) do
      %{layout: _} = expectation ->
        Content.expected_field_blocked?(
          paper_top_level_blocks(socket),
          expectation,
          field_name
        )

      _ ->
        false
    end
  end

  @doc false
  def slash_expectation(socket) do
    case socket.assigns[:editor_schema] do
      %Barkpark.Content.SchemaDefinition{} = schema -> Content.resolve_expectation(schema)
      _ -> nil
    end
  end

  @doc false
  def paper_block_by_id(socket, id) do
    Blocks.find_paper_block(paper_top_level_blocks(socket), id)
  end

  # ── THE READER CLAMP (task-fa27740cb3162dbd) ────────────────────────────────
  #
  # `:paper_html` is rendered by an explicit READ-ONLY arm in `components.ex`
  # (`raw(@paper_html)` inside an `<article>`, taken when `@show_editor` and
  # `@paper_block_mode` are both false — an HTML-only legacy paper, whose
  # editing lives on the paper-ingest ops endpoint). So it is a VIEW, not an
  # editor buffer, and "the editor sees the raw doc" does not cover it:
  # `LiveScope.authorize_read/4` grades an ANONYMOUS mount of a `:docs`-shared
  # desk `:share_read` — the full Studio UI, no flag — and that viewer was
  # served `content["body_html"]` byte for byte: no `Envelope.render`, no
  # visibility redaction, no `HtmlSanitizer`. The share-link static fallback
  # closed exactly this class in #14596 by routing through
  # `Content.Papers.reader_source/3`; this is the same reader, same verdicts.
  #
  # THE PREDICATE IS `write_denied?/1`, NOT A NEW ONE. A socket the write tier
  # denies is a non-editing viewer, and that is already THE single copy of the
  # rule (`Caps.write_capable?/2`, where a `share_access: :read` posture loses
  # before `caps.write` gets a vote). A write-capable socket keeps the raw read
  # — an authenticated author looking at their own document, the same stance
  # `share_link_controller.ex` writes down where it refuses to copy it. Note
  # what that leaves ALONE, honestly: a principal-LESS socket on the open
  # public-demo desk is write-capable BY DESIGN, so nothing here narrows it.
  @doc """
  The `body_html` this SOCKET may be shown for `paper`.

  A write-denied (non-editing) viewer gets `Content.Papers.reader_source/3`'s
  verdict — redacted-safe, sanitized, and `""` where the reader refuses to name
  a source at all (the never-blank arm then renders the honest notice).
  Do not re-derive this: the three `:paper_html` feeds must not drift.
  """
  def reader_paper_html(socket, %{content: _} = paper) do
    if write_denied?(socket) do
      reader_source_html(socket, paper)
    else
      editor_body_html(Map.get(paper.content || %{}, "body_html"))
    end
  end

  def reader_paper_html(_socket, _paper), do: ""

  # ── THE WRITE-CAPABLE ARM IS STILL A VIEW (arpss-studio-legacy-body-html) ───
  #
  # The clamp above answers "what may a NON-EDITING viewer see"; it does NOT
  # answer "are these bytes safe to `raw/1` at all". Those are different
  # questions, and the write-capable arm only ever had an answer to the first.
  # `Content.Papers.reader_source/3` runs `HtmlSanitizer.sanitize/1` on EVERY
  # `body_html` it serves — no principal test — so one stored field had two
  # readers and only one of them scrubbed. That ASYMMETRY, not either path
  # alone, is the defect: whichever reader a poisoned row reaches first decides
  # whether script executes.
  #
  # SANITIZING HERE COSTS THE AUTHOR NOTHING, because `:paper_html` is never an
  # editor buffer. It feeds exactly one READ-ONLY `raw(@paper_html)` arm in
  # `components.ex` (taken when `@show_editor` and `@paper_block_mode` are both
  # false); editing a legacy HTML-only paper lives on the paper-ingest ops
  # endpoint, which re-scrubs on store. No round-trip can be truncated by this
  # — there is no round-trip.
  #
  # WHY THE STORE-TIME CHOKEPOINT IS NOT ALREADY ENOUGH. `Content.Writer`
  # scrubs `content["body_html"]` on create AND upsert, so writes made TODAY
  # are clean — but that chokepoint landed in #2340 (2026-07-10) and does not
  # reach backwards. `Plugs.PaperReaderCsp` exists precisely to catch "a
  # pre-sanitizer poisoned row" (its words) and is path-gated to the
  # `…/papers/:slug` readers — Studio is not one of them. So on THIS arm the
  # store-time pass was the only layer: no read-time scrub, no CSP. This
  # restores layer 1 on the read side and makes one field's two readers agree.
  #
  # The SAME function as the reader, deliberately — not a second sanitizer and
  # not a hand-rolled escape. The two paths differ on REDACTION (an author sees
  # their own unredacted document; a non-editing viewer gets the Envelope's
  # verdict), which is a separate axis and stays exactly as it was.
  @doc """
  Scrub a legacy `body_html` bound for the read-only `raw(@paper_html)` arm.

  `HtmlSanitizer.sanitize/1` — the same scrubber `Content.Papers.reader_source/3`
  runs — so the Studio reader and the bulldocs reader cannot drift on which
  markup is executable. Non-binary input (an absent cache) becomes `""`.
  """
  def editor_body_html(html) when is_binary(html), do: HtmlSanitizer.sanitize(html)
  def editor_body_html(_), do: ""

  @doc """
  The BLOCK body this socket may be shown for `paper` (task-e175d91d93291b10).

  The twin of `reader_paper_html/2`, same predicate and same reader. A
  write-denied (non-editing) viewer gets the `{:blocks, …}` verdict —
  Envelope-rendered and visibility-redacted — and `nil` for every other verdict,
  which drops `paper_block_mode` so the refusal is answered by the never-blank
  notice instead of the stored blocks. A write-capable socket keeps the raw
  editor source.

  `nil` and not `[]` on purpose: `is_list/1` is what `paper_block_mode` keys on,
  and `[]` would claim "a block paper with no blocks" — a blank canvas, not a
  refusal.
  """
  def reader_paper_blocks(socket, %{content: content} = paper) do
    if write_denied?(socket) do
      case Content.Papers.reader_source(
             paper,
             socket.assigns.dataset,
             ScopeHelpers.scope_opts(socket)
           ) do
        {:blocks, blocks} -> blocks
        _ -> nil
      end
    else
      Projection.read_blocks(content || %{})
    end
  end

  def reader_paper_blocks(_socket, _paper), do: nil

  defp reader_source_html(socket, paper) do
    dataset = socket.assigns.dataset
    scope = ScopeHelpers.scope_opts(socket)

    case Content.Papers.reader_source(paper, dataset, scope) do
      {:html, sanitized} ->
        sanitized

      # Envelope promoted a structured source this pane's `Projection.read_blocks/1`
      # did not see. Render THOSE blocks (the reader's own canonical source,
      # already visibility-redacted) rather than blanking a readable paper.
      {:blocks, blocks} ->
        style = Map.get(paper.content || %{}, "style")
        Render.render_blocks(blocks, Labels.paper_render_opts(dataset, style, scope))

      # `:redacted_source`, `:semantic_empty`, `:ambiguous_source`, … — the
      # reader refuses to name a source, so there is nothing this viewer may be
      # shown. Falling back to the cache is precisely the disclosure.
      {:error, _reason} ->
        ""
    end
  end

  @doc false
  def setup_paper_view(socket, %{content: content} = paper) when is_map(content) do
    blocks = reader_paper_blocks(socket, paper)
    rev = Map.get(content, "rev") || 0
    html = reader_paper_html(socket, paper)
    {used_by, linked, unlinked} = load_backlinks(socket, paper)

    if is_list(blocks) do
      socket
      |> assign(
        editor_view: :paper,
        paper_doc: paper,
        paper_rev: rev,
        paper_html: html,
        paper_block_mode: true,
        paper_edit_mode: false,
        backlinks_used_by: used_by,
        backlinks_linked: linked,
        backlinks_unlinked: unlinked
      )
      |> assign(sidebar_assigns(paper))
      # pdd-t12b: with the canvas ON (the mainline default) a block paper opens
      # straight into the always-editable editor — the read-only streamed View
      # branch is unreachable, so resolving + rendering every block into the
      # stream here is pure wasted work (paper_stream_items task-resolves under
      # the session scope since pdd-t11). Keep the stream initialized (reset to
      # empty) so the assign shape is identical; the OFF opt-out path fills it
      # exactly as before, and refetch_paper/paper-toggle-edit still refill it
      # on the paths that render it.
      |> stream(
        :paper_blocks,
        if(PaperCanvas.paper_canvas_enabled?(),
          do: [],
          else:
            paper_stream_items(blocks, socket.assigns.dataset, ScopeHelpers.scope_opts(socket))
        ),
        reset: true
      )
      # t9: seed the LIVE task-block preview the moment the editor opens, on the
      # parallel `bp:task-preview` channel — the source `blocks` above stay
      # unresolved (D5). No-op when the canvas flag is OFF.
      |> push_task_previews()
      # pdd-t8: seed the fleet-in-canvas server paint (bp:block-html) too, so every
      # non-prose fleet block's reader HTML lands the moment the editor opens.
      |> push_block_renders()
    else
      socket
      |> assign(
        editor_view: :paper,
        paper_doc: paper,
        paper_rev: rev,
        paper_html: html,
        paper_block_mode: false,
        paper_edit_mode: false,
        backlinks_used_by: used_by,
        backlinks_linked: linked,
        backlinks_unlinked: unlinked
      )
      |> assign(sidebar_assigns(paper))
      |> stream(:paper_blocks, [], reset: true)
    end
  end

  def setup_paper_view(socket, _paper), do: clear_paper_view(socket)

  # Default t6 sidebar assigns when a paper opens: panel + every section open,
  # slug draft seeded from the paper's own id with its live format verdict.
  #
  # `sidebar_user_opened` is the server half of the bucket-aware inspector
  # default (charter D91). It answers ONE question the server can answer without
  # ever knowing the viewport: "has the user, on THIS paper, explicitly asked
  # for the inspector?" It seeds false on every paper open, and
  # `Handlers.Paper.sidebar_toggle_panel/1` is the only thing that raises it.
  # Components renders it as `data-user-opened` on the <aside>, and the
  # first-paint rule in root.html.heex paints the inspector closed below the
  # `wide` bucket exactly while that marker is absent. `sidebar_open` stays
  # unconditionally true and is NOT bucket-seeded on purpose: the true bucket
  # only reaches the server ~400ms after first paint, so a server-seeded close
  # would BE the flash D12 refused (measured: first paint t=20.1ms,
  # phx-connected t=419.5ms). The cascade closes it at first paint instead.
  defp sidebar_assigns(paper) do
    # NORMALISED through `published_id/1`, and that is not cosmetic. Since the
    # blocks branch resolves draft-first (spd-w17), a never-published paper
    # arrives here as `drafts.paper-…` — and `drafts.` is a STORAGE prefix, not
    # part of any slug. Unnormalised, the very first thing a human sees after
    # creating a document is its own Slug field painted red with "Only
    # lowercase letters, numbers, and hyphens": the product accusing the user
    # of a value the product itself wrote. The slug of a document is its
    # published id in both states.
    slug =
      case paper && Map.get(paper, :doc_id) do
        id when is_binary(id) -> Content.published_id(id)
        _ -> ""
      end

    [
      sidebar_open: true,
      sidebar_user_opened: false,
      sidebar_collapsed: MapSet.new(),
      sidebar_slug_draft: slug,
      sidebar_slug_feedback: PaperCanvas.slug_feedback(slug)
    ]
  end

  @doc """
  Read-only inbound-reference load for the backlinks panel. Resolves the paper's
  published id and runs the arrayOf-aware `Content.Graph.reverse_referencers/2`
  ONCE (scope + dataset bound), then partitions the single result into three
  mutually-exclusive lists via `partition_backlinks/1` (see its doc for the
  buckets).

  Returns `{[], [], []}` for a draft / unresolvable / never-referenced paper —
  the panel renders an empty state, never crashes.
  """
  def load_backlinks(socket, %{doc_id: doc_id}) when is_binary(doc_id) do
    published_id = Content.published_id(doc_id)
    opts = [dataset: socket.assigns.dataset] ++ ScopeHelpers.scope_opts(socket)

    published_id
    |> Content.Graph.reverse_referencers(opts)
    |> partition_backlinks()
  end

  def load_backlinks(_socket, _paper), do: {[], [], []}

  @doc """
  Partition one `Content.Graph.reverse_referencers/2` result into the three
  backlinks-panel sections (mutually exclusive, order-preserving):

    * `used_by` — `valueref`-kind edges (lvw-t3): the docs whose BODY
                  inline-references this doc as a canonical value — the
                  used-by / impact list. Kind wins over origin: a valueref
                  edge always carries `plugin_source: "bulldocs"` (the
                  body-walk extractor, #714) but is NOT a generic derived
                  mention.
    * `linked`  — direct schema-field reference edges (`plugin_source == nil`),
                  i.e. real "Linked mentions".
    * `derived` — the remaining plugin/derived inbound edges
                  (`plugin_source` set).

  Scoping/publish posture is inherited wholesale from `reverse_referencers/2`:
  out-of-scope referencers were already dropped fail-closed upstream (MEDIUM-5
  — no stub, no aggregate count), and the materialised edge corpus is
  published-perspective only (D1) — a draft-only referencing paper is absent
  by design, not by bug (the drafts fold is lvw-t12).
  """
  def partition_backlinks(referencers) when is_list(referencers) do
    {used_by, rest} = Enum.split_with(referencers, fn ref -> ref[:kind] == "valueref" end)
    {linked, derived} = Enum.split_with(rest, fn ref -> is_nil(ref[:plugin_source]) end)
    {used_by, linked, derived}
  end

  @doc false
  def clear_paper_view(socket) do
    if socket.assigns[:editor_view] == :paper do
      socket
      |> assign(
        editor_view: :form,
        paper_doc: nil,
        paper_rev: 0,
        paper_html: "",
        paper_block_mode: false,
        paper_edit_mode: false,
        paper_task_previews: %{},
        backlinks_used_by: [],
        backlinks_linked: [],
        backlinks_unlinked: []
      )
      |> assign(sidebar_assigns(nil))
    else
      assign(socket,
        editor_view: :form,
        backlinks_used_by: [],
        backlinks_linked: [],
        backlinks_unlinked: []
      )
    end
  end

  @doc false
  def paper_stream_items(blocks, dataset, scope) do
    # pdd-t11 debt fix (2): resolve LIVE task/query blocks the SAME way the
    # /papers reader does — `Content.Papers.resolve_tasks_in_blocks/2`, the ONE
    # producer (doctrine rule 3). Without this, the Studio read-only VIEW render
    # left a paper's embedded board/list/roadmap as an empty query block while
    # the public reader showed real `bp` rows. Session-tenant scoped + fail-closed
    # (a nil workspace resolves ZERO rows via Tasks.Query → Scope.scope_to_workspace,
    # never a cross-tenant leak). DISPLAY-ONLY (D5): this feeds the render stream
    # only — the paper_doc's stored `blocks` (the save baseline the canvas diffs
    # against) stay UNresolved, so a save right after a view never freezes a stale
    # snapshot into the doc (D3 byte-stability). An author-pinned literal snapshot
    # (no `query`) is left untouched, so plugin-off papers still render.
    blocks = Content.Papers.resolve_tasks_in_blocks(blocks, scope, dataset)

    resolver = fn value, ref_type -> Content.reference_title(value, ref_type, dataset, scope) end

    codelist_resolver = fn plugin, codelist_id, code ->
      Content.codelist_label(plugin, codelist_id, code)
    end

    # Pre-resolve every wikilink target ONCE so the view-mode render emits
    # navigable <a> links for resolved targets (unresolved → the dotted span).
    wikilinks = Content.resolve_wikilinks_in_blocks(blocks, dataset, scope)

    # Pre-resolve every note-embed (`![[note]]`) target ONCE so the view-mode
    # render transcludes the target paper's HTML (unresolved → broken-embed
    # fallback). Mirrors the wikilinks wiring; one-level + cycle-safe (each
    # target renders with an empty embed map — see resolve_embeds_in_blocks/3).
    embeds = Content.resolve_embeds_in_blocks(blocks, dataset, scope)

    # Pre-resolve every inline valueref (target, field) pair ONCE so the
    # view-mode render shows the CURRENT canonical value (unresolved → the
    # node's pinned fallback literal). Studio's own per-request live view;
    # this palette never feeds a shared cache (wire §5). With no
    # `:caller_context` in `scope` the resolution runs as the anonymous
    # principal — fail closed.
    values = Content.resolve_values_in_blocks(blocks, dataset, scope)

    opts = %{
      ref_resolver: resolver,
      codelist_resolver: codelist_resolver,
      style: :article,
      wikilinks: wikilinks,
      embeds: embeds,
      values: values,
      # lvw-t2 (D4): Studio's OWN per-request view is the one surface carrying
      # the accept-baseline control on DRIFTED valuerefs (the walker gates the
      # button on this flag AND state == "drift"). The body_html cache, delta
      # frames, and the public reader never set it, so the control cannot
      # leak into shared caches or anonymous HTML.
      valueref_accept: true
    }

    blocks
    |> Enum.with_index()
    |> Enum.map(fn {block, index} ->
      %{id: paper_stream_block_id(block, index), html: Render.render_block(block, opts)}
    end)
  end

  @doc false
  def paper_stream_block_id(block, index) do
    case Map.get(block, "id") do
      id when is_binary(id) and id != "" -> id
      _ -> "block-#{index}"
    end
  end

  @doc false
  def paper_block_dom_id(id), do: "paper_blocks-#{id}"

  @doc false
  def paper_gap?(last_rev, incoming_rev)
      when is_integer(last_rev) and is_integer(incoming_rev) do
    incoming_rev != last_rev + 1
  end

  def paper_gap?(_last, _incoming), do: true

  @doc false
  def apply_paper_delta(socket, %{op_kind: "remove-block", block_id: id} = frame) do
    socket
    |> stream_delete_by_dom_id(:paper_blocks, paper_block_dom_id(id))
    |> assign(:paper_rev, frame.rev)
    |> assign(:paper_block_mode, true)
  end

  def apply_paper_delta(
        socket,
        %{op_kind: kind, block_id: id, fragment_html: html, position: pos} = frame
      )
      when kind in ["append-block", "insert-after"] and is_integer(pos) do
    socket
    |> stream_insert(:paper_blocks, %{id: id, html: html}, at: pos)
    |> assign(:paper_rev, frame.rev)
    |> assign(:paper_block_mode, true)
  end

  def apply_paper_delta(
        socket,
        %{op_kind: "move-block", block_id: id, fragment_html: html, position: pos} = frame
      )
      when is_integer(pos) do
    socket
    |> stream_delete_by_dom_id(:paper_blocks, paper_block_dom_id(id))
    |> stream_insert(:paper_blocks, %{id: id, html: html}, at: pos)
    |> assign(:paper_rev, frame.rev)
    |> assign(:paper_block_mode, true)
  end

  # A canvas batch (apply_paper_block_ops) broadcasts ONE frame with op_kind: :batch
  # and fragment_html: nil — it carries NO per-block fragment (the batch re-syncs the
  # whole paper_doc via sync_paper_edit_doc, and the editing LV is itself subscribed to
  # the doc topic so it receives its own batch frame). The catch-all below would treat
  # it as a per-block delta and stream_insert a {id, html: nil} :paper_blocks row — a
  # null-html item + a redundant re-render, latent corruption if that stream is ever
  # rendered (mode toggle / refetch). It is a NO-OP for the per-block stream; only track
  # the rev so paper_gap?/2 stays accurate. (op_kind: :batch is an ATOM; the per-block
  # kinds matched above are strings, so this clause never shadows them.)
  def apply_paper_delta(socket, %{op_kind: :batch} = frame) do
    assign(socket, :paper_rev, frame.rev)
  end

  def apply_paper_delta(socket, %{block_id: id, fragment_html: html} = frame) do
    socket
    |> stream_insert(:paper_blocks, %{id: id, html: html})
    |> assign(:paper_rev, frame.rev)
    |> assign(:paper_block_mode, true)
  end

  @doc false
  def refetch_paper(socket) do
    paper = socket.assigns[:paper_doc]
    slug = paper && paper.doc_id
    dataset = socket.assigns.dataset

    # SCOPED, not global. `Content.get_paper/2` with no opts is an EXPLICIT
    # GLOBAL read (see its @doc) — on a tenant desk it answers `nil` for the
    # very paper the pane is showing, so this refetch was a silent no-op there
    # (measured: the read-only re-feed below kept a stale body). Threading the
    # socket's own scope is both the fix for that and the tenancy boundary this
    # read should always have had.
    case slug && Content.get_paper(slug, dataset, ScopeHelpers.scope_opts(socket)) do
      nil ->
        socket

      paper ->
        content = paper.content || %{}

        case reader_paper_blocks(socket, paper) do
          blocks when is_list(blocks) ->
            socket
            |> stream(
              :paper_blocks,
              paper_stream_items(blocks, dataset, ScopeHelpers.scope_opts(socket)),
              reset: true
            )
            |> assign(:paper_doc, paper)
            |> assign(:paper_rev, Map.get(content, "rev") || 0)
            |> assign(:paper_block_mode, true)

          _ ->
            socket
            |> assign(:paper_doc, paper)
            |> assign(:paper_html, reader_paper_html(socket, paper))
            |> assign(:paper_rev, Map.get(content, "rev") || 0)
            |> assign(:paper_block_mode, false)
        end
    end
  end
end
