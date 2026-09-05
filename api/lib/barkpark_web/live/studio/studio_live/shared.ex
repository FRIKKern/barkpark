defmodule BarkparkWeb.Studio.StudioLive.Shared do
  @moduledoc """
  State-coupled helpers shared by `StudioLive` and its `Handlers.*` modules.

  Every function here was a `defp` on the StudioLive god-module before the
  handler-body extraction (Modularity gate). They thread `socket` explicitly and
  are behaviour-preserving — the subscription/pane/presence semantics are
  identical to the originals. All are `@doc false`: they are an internal seam,
  not a public API. The pure path/parse helpers stay on `StudioLive` itself
  (test-facing), and so does `default_dataset/0`.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView

  alias Barkpark.{Content, Tenancy}
  alias Barkpark.Content.Warnings
  alias BarkparkWeb.Presence
  alias BarkparkWeb.ScopeHelpers
  alias BarkparkWeb.Studio.{PaneBuilder, PresenceState}
  alias BarkparkWeb.Studio.StudioLive.Handlers.Shares, as: SharesHandler
  alias BarkparkWeb.Studio.StudioLive.{Mount, Path, Paths}
  alias BarkparkWeb.Studio.StudioLive.Shared.Paper

  @doc false
  def maybe_open_shares(socket, %{"shares" => "open"}) do
    if Mount.shares_admin?(socket) do
      assign(socket,
        show_shares: true,
        shares_error: nil,
        shares_rows: load_share_rows(socket),
        shares_scope_prefill: shares_scope_prefill(socket),
        shares_prefill_surfaces: []
      )
    else
      socket
    end
  end

  def maybe_open_shares(socket, _params), do: socket

  @doc false
  def push_block_to_wc(socket, block_id) when is_binary(block_id) do
    paper = socket.assigns[:paper_doc]

    blocks =
      case paper && Map.get(paper, :content) do
        %{"blocks" => blocks} when is_list(blocks) -> blocks
        _ -> []
      end

    case Enum.find(blocks, fn b -> Map.get(b, "id") == block_id end) do
      nil ->
        socket

      block ->
        push_event(socket, "bp:block-update", %{block_id: block_id, block: block})
    end
  end

  def push_block_to_wc(socket, _), do: socket

  @doc false
  def ensure_list_subscription(socket, dataset) do
    if connected?(socket) do
      ws_id = socket.assigns[:current_workspace] && socket.assigns.current_workspace.id
      new_topic = list_topic(dataset, ws_id)
      old_topic = socket.assigns[:list_topic]

      if new_topic == old_topic do
        socket
      else
        if old_topic, do: Phoenix.PubSub.unsubscribe(Barkpark.PubSub, old_topic)
        Phoenix.PubSub.subscribe(Barkpark.PubSub, new_topic)
        assign(socket, list_topic: new_topic)
      end
    else
      socket
    end
  end

  @doc false
  def list_topic(dataset, ws_id) when is_binary(ws_id),
    do: "documents:ws:#{ws_id}:#{dataset}"

  def list_topic(dataset, _ws_id), do: "documents:#{dataset}"

  @doc false
  def ensure_presence_subscription(socket) do
    if connected?(socket) do
      ws_id = socket.assigns[:current_workspace] && socket.assigns.current_workspace.id
      new_topic = PresenceState.topic(ws_id)
      old_topic = socket.assigns[:presence_topic]

      if new_topic == old_topic do
        socket
      else
        if old_topic do
          Presence.untrack(self(), old_topic, socket.assigns.user_id)
          Phoenix.PubSub.unsubscribe(Barkpark.PubSub, old_topic)
        end

        Phoenix.PubSub.subscribe(Barkpark.PubSub, new_topic)
        assign(socket, presence_topic: new_topic)
      end
    else
      socket
    end
  end

  @doc false
  def subscribe_to_doc(socket) do
    old_sub = socket.assigns[:subscribed_doc]

    if old_sub do
      Phoenix.PubSub.unsubscribe(Barkpark.PubSub, old_sub)
    end

    case socket.assigns do
      %{editor_type: type, editor_doc: %{doc_id: doc_id}} when not is_nil(type) ->
        ws_id = socket.assigns[:current_workspace] && socket.assigns.current_workspace.id

        topic =
          Content.doc_topic(
            Content.published_id(doc_id),
            type,
            ws_id,
            socket.assigns.dataset
          )

        Phoenix.PubSub.subscribe(Barkpark.PubSub, topic)
        assign(socket, subscribed_doc: topic)

      _ ->
        assign(socket, subscribed_doc: nil)
    end
  end

  @doc false
  def track_presence(socket) do
    if connected?(socket) do
      doc_id =
        case socket.assigns do
          %{editor_doc: %{doc_id: did}, editor_type: type} when not is_nil(type) ->
            Content.published_id(did)

          _ ->
            nil
        end

      meta = %{
        doc_id: doc_id,
        type: socket.assigns[:editor_type],
        dataset: socket.assigns[:dataset],
        project_id: socket.assigns[:current_project] && socket.assigns.current_project.id,
        name: socket.assigns.user_name,
        color: socket.assigns.user_color,
        joined_at: System.system_time(:second)
      }

      ws_id = socket.assigns[:current_workspace] && socket.assigns.current_workspace.id
      topic = socket.assigns[:presence_topic] || PresenceState.topic(ws_id)

      case Presence.get_by_key(topic, socket.assigns.user_id) do
        [] -> Presence.track(self(), topic, socket.assigns.user_id, meta)
        _ -> Presence.update(self(), topic, socket.assigns.user_id, meta)
      end

      assign(socket, presences: PresenceState.list(topic))
    else
      socket
    end
  end

  @doc false
  def seed_new_doc_content("task"), do: %{"kind" => "task", "lifecycle_status" => "open"}

  # A blocks-doc is born with an EXPLICIT EMPTY block list — not `%{}`, and not a
  # hand-rolled paragraph. The empty list is the signal
  # `Papers.Template.maybe_seed/3` reads as "a new blank document" (via
  # `Writer.maybe_apply_paper_template/2`), which is what produces the locked
  # `tpl-title` heading, the empty `tpl-body` paragraph to type into, and
  # `style: "article"`. `%{}` leaves `blocks` nil — the HTML-ingest path — so the
  # human got a document with nothing to click and nowhere to type (spd-w17).
  # Hand-rolling a paragraph here would bypass the template and lose all of it.
  # A SESSION is a blocks-doc with NO birth template: the writer's
  # `maybe_apply_paper_template` matches "paper" only, so the explicit empty
  # list below persists as an untemplated EMPTY LIST — `read_blocks` returns
  # it as-is, `setup_paper_view` takes the block branch (`paper_block_mode:
  # true`) and the human gets a canvas with ZERO runs: a second, different
  # blank from the one wave 17 fixed (spd-bl-session-birth-template, named
  # out of scope there by charter D221). Seed ONE empty paragraph at this
  # Studio seam instead — the same "somewhere to type" the paper template's
  # `tpl-body` provides, without inventing a session template in core. The
  # stable id keeps DocPatchOp addressing deterministic across the birth.
  def seed_new_doc_content("session") do
    %{"blocks" => [%{"id" => "session-body", "type" => "paragraph", "content" => []}]}
  end

  def seed_new_doc_content(type) do
    if Content.blocks_type?(type), do: %{"blocks" => []}, else: %{}
  end

  @doc false
  defdelegate paper_op(socket, op), to: Paper

  @doc false
  defdelegate paper_ops(socket, ops), to: Paper

  @doc false
  defdelegate push_task_previews(socket), to: Paper

  @doc false
  defdelegate push_block_renders(socket), to: Paper

  @doc false
  defdelegate task_previews(blocks, socket), to: Paper

  @doc false
  defdelegate paper_pane_op(socket, op), to: Paper

  @doc false
  defdelegate paper_publish(socket), to: Paper

  @doc false
  defdelegate sidebar_description_change(socket, value), to: Paper

  @doc false
  defdelegate sidebar_label_add(socket, params), to: Paper

  @doc false
  defdelegate document_op(socket, op), to: Paper

  @doc false
  defdelegate sync_editor_blocks(socket), to: Paper

  @doc false
  defdelegate paper_reorder(socket, blocks, idx, dir), to: Paper

  @doc false
  defdelegate sync_paper_edit_doc(socket), to: Paper

  @doc false
  defdelegate paper_top_level_blocks(socket), to: Paper

  @doc false
  defdelegate paper_top_level_free(socket), to: Paper

  @doc false
  defdelegate paper_all_descriptors(socket), to: Paper

  @doc false
  defdelegate slash_insert_op(after_id, block), to: Paper

  @doc false
  defdelegate expected_field_blocked?(socket, field_name), to: Paper

  @doc false
  defdelegate slash_expectation(socket), to: Paper

  @doc false
  defdelegate paper_block_by_id(socket, id), to: Paper

  # pds-w42-bl-handle-info-write-seam-audit — THE PRINCIPAL GATE, AT THE
  # SECOND HOOK-INVISIBLE CHOKEPOINT.
  #
  # `Caps.attach/1` arms the Studio deny-gate as
  # `attach_hook(_, :handle_event, _)`, and no `handle_event` hook — parent
  # socket or component socket — can see a `handle_info`. This function is the
  # body of one: `handle_info({:autosave_form, form})` → `autosave_form/2` →
  # here → `Content.upsert_draft`. Before this gate the ONLY thing standing in
  # a write-denied principal's way was the socket gate on the five parent
  # events that send to this seam today (select-media / clear-image /
  # upload-image / select-ref / clear-ref, all in `Caps` `@write_events`) —
  # a property of today's CALLERS, not of the seam. That is precisely the
  # argument that held for `paper_op` right up until `PaperFieldBlock` started
  # sending to it and turned it into a live bypass.
  #
  # Reproduced by run before the gate: a read-only api-token member opened a
  # document and a bare `{:autosave_form, …}` message wrote the draft row.
  #
  # ONE RULE, NOT A FORK: `Paper.write_denied?/1` is the shared negation of
  # `Caps.write_capable?/2` — the single copy the socket gate itself uses — and
  # `Paper.refuse_write_denied/1` is the shared refusal, so this door and the
  # paper doors speak one vocabulary. Gating HERE rather than in the
  # `handle_info` body also covers the four `handle_event` callers, which is
  # belt-and-braces: they are already gated at the socket.
  #
  # SCOPE, HONESTLY: this denies any principal `Caps` denies write — a
  # read-only api_token or read-only member. It is silent on a principal-LESS
  # socket, because `write_capable?/2` returns TRUE there BY DESIGN (the
  # intentionally-open public-demo posture).
  # studio-w21 (from the pds-w43 run) — THE SECOND QUESTION, ASKED HERE TOO.
  #
  # The gate above answers "may this PRINCIPAL write at all". It has no TARGET,
  # and for a GRANT-graded socket the target IS the authorization: a grant
  # naming ONE doc auto-satisfies `Access.admits_desk?/3` at desk granularity,
  # so `Caps.write_capable?/2` — and therefore `write_denied?/1` — answers
  # "capable" while editing a DIFFERENT doc on the same desk. `paper_pane_op/2`,
  # `paper_ops/2` and `document_op/2` each ask the target question after the
  # principal one; this seam did not, and it is the same hook-invisible shape
  # (`handle_info`, which no `handle_event` hook observes).
  #
  # Reproduced by run before this arm: on a socket holding a project-scoped READ
  # grant plus a doc-scoped WRITE grant, `do_autosave/2` with `editor_doc` set to
  # the doc the write grant does NOT name returned `save_status: "Saved"` and
  # `title == "ESCALATED-BY-AUTOSAVE"` read back from the store.
  #
  # ONE RULE, NOT A FORK: `Paper.grant_target_denied?/3` and
  # `Paper.refuse_outside_grant/1` are the SAME copies the paper doors call —
  # `Access.validate/3` on the target's real type + doc_id — so the four doors
  # cannot drift into four answers. `editor_doc` is the doc this seam actually
  # writes (`autosave_write/2` → `Content.upsert_draft`), so it is the doc the
  # grant must admit; a missing/!map doc yields a nil target, which the shared
  # predicate treats as unresolvable and refuses FOR A GRANT-GRADED SOCKET ONLY.
  # A membership-derived socket is untouched: `grant_target_denied?/3` returns
  # false without loading anything.
  @doc false
  def do_autosave(socket, params) do
    doc = socket.assigns[:editor_doc]
    doc_id = if is_map(doc), do: Map.get(doc, :doc_id)

    cond do
      Paper.write_denied?(socket) ->
        Paper.refuse_write_denied(socket)

      Paper.grant_target_denied?(socket, socket.assigns[:editor_type], doc_id) ->
        Paper.refuse_outside_grant(socket)

      true ->
        autosave_write(socket, params)
    end
  end

  defp autosave_write(socket, params) do
    doc = socket.assigns[:editor_doc]
    schema = socket.assigns[:editor_schema]
    type = socket.assigns[:editor_type]

    if doc && type do
      case Content.upsert_draft(
             doc,
             type,
             schema,
             params,
             socket.assigns.dataset,
             hook_opts(socket)
           ) do
        {:ok, saved_doc, errs} ->
          new_title = Map.get(params, "title", doc.title)

          panes =
            PaneBuilder.update_title(
              socket.assigns.panes,
              Content.published_id(saved_doc.doc_id),
              new_title
            )

          assign(socket,
            panes: panes,
            editor_doc: saved_doc,
            editor_is_draft: Content.draft?(saved_doc.doc_id),
            editor_form: Map.merge(socket.assigns[:editor_form] || %{}, params),
            save_status: "Saved",
            validation_errors: errs,
            cross_violations: compute_cross_violations(schema, params)
          )
          |> maybe_refresh_content_preview()

        {:error, {:halted, reason}} ->
          socket
          |> assign(save_status: "Save cancelled")
          |> put_flash(:error, "Save cancelled: #{reason}")

        {:error, _} ->
          assign(socket, save_status: "Save failed")
      end
    else
      socket
    end
  end

  @doc false
  def hook_opts(socket) do
    [source: :studio, user_id: socket.assigns[:user_id]] ++ ScopeHelpers.scope_opts(socket)
  end

  @doc false
  def maybe_refresh_content_preview(socket) do
    doc_type = socket.assigns[:editor_type]

    case doc_type do
      type when is_binary(type) and type != "" ->
        content = socket.assigns[:editor_form] || %{}

        ctx = %{
          current_user: socket.assigns[:current_user],
          user_id: socket.assigns[:user_id],
          dataset: socket.assigns[:dataset],
          perspective: socket.assigns[:perspective]
        }

        case Barkpark.Plugins.Registry.collect_content_renderer(type, content, ctx) do
          {:ok, rendered} ->
            assign(socket, content_preview_rendered: rendered)

          :none ->
            assign(socket, content_preview_rendered: nil)
        end

      _ ->
        assign(socket, content_preview_rendered: nil)
    end
  end

  @doc false
  def do_unpublish(socket) do
    opts = hook_opts(socket)

    do_action(
      socket,
      fn doc, type ->
        Content.unpublish_document(
          Content.published_id(doc.doc_id),
          type,
          socket.assigns.dataset,
          opts
        )
      end,
      "Unpublished"
    )
  end

  @doc false
  def do_action(socket, action, msg) do
    doc = socket.assigns[:editor_doc]
    type = socket.assigns[:editor_type]

    if doc && type do
      # The advisory channel (authoring-excellence D5): the publish wall queues
      # non-blocking warnings ([{code, severity, message}]) while the write
      # applies. A Studio publish is an agent-facing surface too, so drain them
      # into the SUCCESS flash instead of dropping them on the floor (mirrors
      # MutateController). Reset first — the accumulator is
      # collect-only-when-listening, so without an open queue the 2–4 tag-count
      # norm advisory would never be captured.
      Warnings.reset()

      case action.(doc, type) do
        {:ok, _} ->
          {:noreply,
           socket |> put_flash(:info, with_advisories(msg, Warnings.drain())) |> rebuild_panes()}

        {:error, {:halted, reason}} ->
          {:noreply, put_flash(socket, :error, "#{msg} cancelled: #{reason}")}

        # The publish wall (authoring-excellence D14): a label-spine rejection
        # must render its field/rule/fix detail, never degrade to the
        # content-free "Action failed" flash — the rejection is the UI here,
        # and it has to read like documentation.
        {:error, {:label_spine, details}} ->
          {:noreply,
           put_flash(socket, :error, "Publish blocked: #{format_wall_details(details)}")}

        # The E3 tag-registry wall (authoring-excellence D80): an unknown-tag
        # rejection names each unregistered tag with its nearest suggestion, so
        # the fix is one flash away — never the content-free "Action failed".
        {:error, {:unknown_tag, payload}} ->
          {:noreply,
           put_flash(socket, :error, "Publish blocked: #{format_wall_details(payload)}")}

        # The E4 dedup wall (authoring-excellence D80/D81): a near-duplicate
        # rejection surfaces the incumbent's published id plus the fix, so the
        # author can extend that document instead of re-publishing a twin.
        {:error, {:duplicate_of, payload}} ->
          {:noreply,
           put_flash(socket, :error, "Publish blocked: #{format_wall_details(payload)}")}

        # ── the four NON-WALL rejection shapes (ae-nonwall-rejection-render) ──
        #
        # Wave-11's census (charter D83a) proved these are the only real
        # `{:error, reason}` shapes beyond the wall tuples that reach here. Each
        # one degraded to the content-free "Action failed", which tells an author
        # nothing about a situation every one of them can be recovered from.
        # A REFUTED fifth: plugin exceptions cannot reach `do_action` — `Hooks.fire`
        # coerces a raising `before_*` hook to `:ok`.

        # 1. TOCTOU. `Content.get_document` found no draft
        # (`lifecycle.ex:96-97`) — another tab discarded it, or published it out
        # from under this one.
        {:error, :not_found} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "That document is no longer there — it may have been discarded, or " <>
               "already #{String.downcase(msg)} in another tab."
           )}

        # 2. The rev fence (`mutations.ex:151`, `lifecycle.ex:149`). The most
        # plausible of the four and the most actionable: an autosave or a second
        # tab bumped the rev between this pane's read and its write. The revs
        # themselves are opaque to a person, so the flash spends its words on the
        # remedy instead.
        {:error, {:rev_mismatch, _revs}} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "The document changed since you loaded it — reload and retry."
           )}

        # 3. The task lifecycle gate (`lifecycle.ex:349/352/365`,
        # `mutations.ex:451/565/723/784`). The payload is `%{field => [msg]}` and
        # every `msg` is PRE-BUILT human prose naming the illegal transition or
        # the stale-claim race — so it is rendered directly, not re-derived. NOTE
        # the field is NOT always "lifecycle_status": "claim" and
        # "acceptance_criteria" emit the same family.
        {:error, {:invalid_task_content, errors}} when is_map(errors) ->
          {:noreply, put_flash(socket, :error, format_field_errors(errors))}

        # 4. A RAW changeset, from `Repo.rollback(cs)` on the published-row
        # upsert (`lifecycle.ex:184-185`) — a concurrent tenant-scope delete
        # (FK) or a double-publish unique race. It MUST NOT fall through to
        # `format_wall_details/1`: a changeset IS a map, so `%{} = detail` would
        # match it, find no field/rule/fix, and `inspect/1` the whole struct —
        # dumping `:data` (the entire %Document{}, content included) into a
        # flash. That is strictly worse than "Action failed". Hand-rolled via
        # `traverse_errors/2` per charter D27; never `to_envelope`.
        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "#{msg} failed: " <>
               (changeset
                |> Ecto.Changeset.traverse_errors(&changeset_message/1)
                |> format_field_errors())
           )}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Action failed")}
      end
    else
      {:noreply, socket}
    end
  end

  # `%{field => [message]}` → one flash line. Shared by the
  # `invalid_task_content` family and the traversed changeset, because both
  # arrive in exactly that shape. Field-prefixed so a multi-field rejection says
  # WHICH field, and bounded so a changeset with many errors cannot fill the
  # screen.
  @max_error_fields 4

  defp format_field_errors(errors) when is_map(errors) do
    fields = errors |> Map.to_list() |> Enum.sort_by(&to_string(elem(&1, 0)))
    shown = Enum.take(fields, @max_error_fields)

    line =
      Enum.map_join(shown, " · ", fn {field, messages} ->
        "#{field}: #{messages |> List.wrap() |> Enum.join("; ")}"
      end)

    case length(fields) - length(shown) do
      0 -> line
      n -> line <> " (+#{n} more)"
    end
  end

  # `traverse_errors/2` hands each error as `{message, opts}` with `%{count}`
  # style placeholders still in the message. Interpolating them here keeps the
  # whole render inside this module — no `to_envelope`, and nothing from the
  # changeset's `:data` is ever read.
  defp changeset_message({message, opts}) do
    Enum.reduce(opts, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(inspect_scalar(value)))
    end)
  end

  defp inspect_scalar(value) when is_binary(value) or is_number(value) or is_atom(value),
    do: value

  # A non-scalar option (a list of allowed values, say) is summarised rather
  # than inspected in full — the same no-struct-internals rule as above.
  defp inspect_scalar(value) when is_list(value),
    do: Enum.map_join(value, ", ", &to_string(inspect_scalar(&1)))

  defp inspect_scalar(_), do: "?"

  @doc """
  Render the publish wall's documentation-grade rejection details
  (`{:label_spine, details}`) into one flash-sized line. The validator emits a
  violation as a `%{field, rule, fix}` map (or a list of them); anything else
  is inspected verbatim so a shape drift degrades loudly, not into "Action
  failed".
  """
  def format_wall_details(details) when is_list(details) do
    details |> Enum.map(&format_wall_details/1) |> Enum.join(" · ")
  end

  # The E3 tag-registry rejection (authoring-excellence D80/D81): each
  # unregistered tag names itself with its best-first trgm suggestions — "unknown
  # tag 'serach' — did you mean 'search'?". Bounded upstream (≤12 names via the
  # label-spine `@max_tags`, ≤3 suggestions/name via `@suggestion_limit`), so no
  # truncation is needed here. Ordered BEFORE the generic `%{}` clause below —
  # this payload has no field/rule/fix, so it must not fall through to it.
  def format_wall_details(%{unknown: unknown, suggestions: suggestions})
      when is_list(unknown) and is_map(suggestions) do
    unknown
    |> Enum.map(fn name ->
      case Map.get(suggestions, name, []) do
        [] ->
          "unknown tag '#{name}'"

        names ->
          "unknown tag '#{name}' — did you mean #{Enum.map_join(names, ", ", &"'#{&1}'")}?"
      end
    end)
    |> Enum.join(" · ")
  end

  # The E4 dedup rejection (authoring-excellence D81): the payload's `:message`
  # is FIXED generic prose that lacks the one actionable datum — the incumbent's
  # published id lives in `:duplicate_of`. So the flash composes fresh from that
  # id plus guidance consistent with the wall's @hints prose. `:similar`/`:advise`
  # are UNCAPPED upstream and deliberately NOT rendered here — only the incumbent
  # id. Ordered BEFORE the generic `%{}` clause below.
  def format_wall_details(%{duplicate_of: incumbent}) when is_binary(incumbent) do
    "duplicate of #{incumbent} — extend that document, or declare content.supersedes: \"#{incumbent}\" if this one replaces it"
  end

  def format_wall_details(%{} = detail) do
    field = wall_detail(detail, :field)
    rule = wall_detail(detail, :rule)
    fix = wall_detail(detail, :fix)

    case {field, rule, fix} do
      {nil, nil, nil} -> inspect(detail)
      _ -> Enum.join(Enum.reject([field, rule, fix], &is_nil/1), " — ")
    end
  end

  def format_wall_details(other), do: inspect(other)

  # Append the publish wall's drained advisory messages (authoring-excellence
  # D5 — the 2–4 tag-count norm, the dedup advise band) to a success flash. Each
  # entry is `%{code, severity, message}`; the human-readable `message` is what
  # the author reads. No advisories ⇒ the flash is unchanged.
  @doc false
  def with_advisories(msg, []), do: msg

  def with_advisories(msg, warnings) when is_list(warnings) do
    msg <> " · " <> Enum.map_join(warnings, " · ", & &1.message)
  end

  defp wall_detail(detail, key) do
    case detail[key] || detail[to_string(key)] do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  @doc false
  def bulk_action(socket, kind) do
    ids = MapSet.to_list(socket.assigns.selected_doc_ids)
    type = list_pane_type(socket)
    dataset = socket.assigns.dataset
    opts = hook_opts(socket)

    if type == nil or ids == [] do
      assign(socket, selected_doc_ids: MapSet.new())
    else
      # Open the advisory queue before the batch (authoring-excellence D5):
      # every successful publish in the set may queue a 2–4 norm / dedup-advise
      # warning; drained after the reduce and folded into the success flash so a
      # bulk publish surfaces the same advisories the single-doc path does.
      Warnings.reset()

      # `walled` tracks label-spine rejections separately from plugin halts and
      # generic failures (authoring-excellence D14): a wall rejection carries a
      # fix and must say so — "cancelled by plugin rules" would misattribute
      # it, "failed" would hide it. The first rejection's detail rides the
      # flash so the author sees a concrete field/rule/fix, not just a count.
      {ok, halted, err, walled, wall_detail} =
        Enum.reduce(ids, {0, 0, 0, 0, nil}, fn id, {ok, halted, err, walled, wall_detail} ->
          result =
            case kind do
              :publish -> Content.publish_document(id, type, dataset, opts)
              :unpublish -> Content.unpublish_document(id, type, dataset, opts)
            end

          case result do
            {:ok, _} ->
              {ok + 1, halted, err, walled, wall_detail}

            {:error, {:halted, _}} ->
              {ok, halted + 1, err, walled, wall_detail}

            {:error, {:label_spine, details}} ->
              {ok, halted, err, walled + 1, wall_detail || format_wall_details(details)}

            # The E3/E4 wall shapes (authoring-excellence D80): an unknown-tag or
            # near-duplicate rejection is a WALL block, not a generic failure —
            # fold both into the `walled` accumulator (first-wall_detail idiom) so
            # the batch flash attributes them to the wall with a concrete fix.
            {:error, {:unknown_tag, payload}} ->
              {ok, halted, err, walled + 1, wall_detail || format_wall_details(payload)}

            {:error, {:duplicate_of, payload}} ->
              {ok, halted, err, walled + 1, wall_detail || format_wall_details(payload)}

            _ ->
              {ok, halted, err + 1, walled, wall_detail}
          end
        end)

      verb = if kind == :publish, do: "Published", else: "Unpublished"
      advisories = Warnings.drain()

      flash =
        cond do
          walled > 0 ->
            "#{verb} #{ok} of #{length(ids)}. #{walled} blocked by the publish wall — " <>
              "#{wall_detail}" <>
              if(halted > 0, do: " (#{halted} cancelled by plugin rules)", else: "") <>
              if(err > 0, do: " (#{err} failed)", else: "")

          halted > 0 and err == 0 ->
            "#{verb} #{ok} of #{length(ids)}. #{halted} cancelled by plugin rules."

          halted > 0 and err > 0 ->
            "#{verb} #{ok} of #{length(ids)}. #{halted} cancelled by plugin rules (#{err} failed)."

          err == 0 ->
            "#{verb} #{ok} of #{length(ids)}"

          true ->
            "#{verb} #{ok} of #{length(ids)} (#{err} failed)"
        end

      socket
      |> assign(selected_doc_ids: MapSet.new())
      |> put_flash(:info, with_advisories(flash, advisories))
      |> rebuild_panes()
    end
  end

  @doc false
  def list_pane_type(socket) do
    socket.assigns
    |> Map.get(:panes, [])
    |> Enum.reverse()
    |> Enum.find_value(fn pane -> Map.get(pane, :type_name) end)
  end

  @doc false
  def ensure_tenancy_scope(socket) do
    if socket.assigns[:current_workspace] do
      socket
    else
      workspace = initial_workspace(socket)
      project = initial_project(workspace)

      assign(socket, current_workspace: workspace, current_project: project)
    end
  end

  @doc false
  def initial_project(%{id: ws_id}) do
    default_under_workspace =
      case Tenancy.get_default_project() do
        %{workspace_id: ^ws_id} = proj -> proj
        _ -> nil
      end

    default_under_workspace || List.first(Tenancy.list_projects(ws_id))
  end

  def initial_project(_), do: nil

  @doc false
  def rescope_dataset_for_project(socket, %{} = project) do
    socket = reset_nav_for_switch(socket)

    case default_dataset_for_project(project) do
      %{slug: slug} when is_binary(slug) and slug != "" ->
        cond do
          slug == socket.assigns[:dataset] and (socket.assigns[:scope_prefix] || "") != "" ->
            push_patch(socket, to: studio_path(socket, [], slug))

          slug == socket.assigns[:dataset] ->
            socket
            |> ensure_list_subscription(slug)
            |> ensure_presence_subscription()
            |> track_presence()
            |> rebuild_panes()

          true ->
            push_patch(socket, to: studio_path(socket, [], slug))
        end

      _ ->
        if (socket.assigns[:scope_prefix] || "") != "" do
          push_patch(socket, to: studio_path(socket, [], socket.assigns[:dataset]))
        else
          socket
          |> ensure_list_subscription(socket.assigns[:dataset])
          |> ensure_presence_subscription()
          |> track_presence()
          |> rebuild_panes()
        end
    end
  end

  def rescope_dataset_for_project(socket, _) do
    socket = reset_nav_for_switch(socket)

    if (socket.assigns[:scope_prefix] || "") != "" do
      push_patch(socket, to: studio_path(socket, [], socket.assigns[:dataset]))
    else
      socket
      |> ensure_list_subscription(socket.assigns[:dataset])
      |> ensure_presence_subscription()
      |> track_presence()
      |> rebuild_panes()
    end
  end

  @doc false
  def reset_nav_for_switch(socket) do
    nav_path = if socket.assigns[:editor_doc], do: [], else: socket.assigns[:nav_path] || []

    assign(socket,
      nav_path: nav_path,
      editor_doc: nil,
      editor_type: nil,
      editor_schema: nil,
      editor_view: :form,
      editor_form: %{},
      editor_blocks: [],
      editor_blocks_synth?: false,
      editor_mode: :classic,
      editor_is_draft: false,
      editor_has_published: false,
      published_doc: nil,
      diff_visible: false,
      graph_doc: nil,
      graph_data: %{nodes: [], edges: []}
    )
  end

  @doc false
  def default_dataset_for_project(%{} = project) do
    datasets = Tenancy.list_datasets(project)
    Enum.find(datasets, &(&1.slug == Content.default_dataset())) || List.first(datasets)
  end

  def default_dataset_for_project(_), do: nil

  @doc false
  def create_error(%Ecto.Changeset{} = changeset, what) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)
      end)

    case errors |> Map.to_list() |> List.first() do
      {field, [msg | _]} -> "Could not create #{what}: #{field} #{msg}"
      _ -> "Could not create #{what}"
    end
  end

  def create_error(_, what), do: "Could not create #{what}"

  @doc false
  def project_has_dataset?(%{} = project, slug) when is_binary(slug) do
    project
    |> Tenancy.list_datasets()
    |> Enum.any?(&(&1.slug == slug))
  end

  def project_has_dataset?(_, _), do: false

  @doc false
  def redirect_dataset_leaf(socket, dataset) do
    project = socket.assigns[:current_project]

    cond do
      project_has_dataset?(project, dataset) ->
        :ok

      true ->
        case default_dataset_for_project(project) do
          %{slug: slug} when is_binary(slug) and slug != "" and slug != dataset ->
            {:redirect, slug}

          _ ->
            :ok
        end
    end
  end

  @doc false
  def initial_workspace(socket) do
    case socket.assigns[:api_token] do
      %Barkpark.Auth.ApiToken{} = token ->
        case List.first(Tenancy.list_workspaces_for(token)) do
          %{} = ws -> ws
          _ -> Tenancy.get_default_workspace()
        end

      _ ->
        Tenancy.get_default_workspace()
    end
  end

  @doc false
  def can_reach_workspace?(socket, %{id: ws_id} = _workspace) do
    case socket.assigns[:api_token] do
      %Barkpark.Auth.ApiToken{} = token ->
        Barkpark.Tenancy.Auth.member?(token, ws_id)

      _ ->
        match?(%{id: ^ws_id}, socket.assigns[:current_workspace])
    end
  end

  @doc false
  def sync_scope_prefix(socket) do
    with prefix when is_binary(prefix) and prefix != "" <- socket.assigns[:scope_prefix],
         %{slug: ws_slug} when is_binary(ws_slug) <- socket.assigns[:current_workspace],
         %{slug: proj_slug} when is_binary(proj_slug) <- socket.assigns[:current_project] do
      assign(socket, :scope_prefix, "/w/#{ws_slug}/p/#{proj_slug}")
    else
      _ -> socket
    end
  end

  @doc false
  def studio_path(socket, path, dataset, opts \\ []) do
    (socket.assigns[:scope_prefix] || "") <> Paths.studio_path_for(path, dataset, opts)
  end

  @doc false
  def find_field(socket, field_name) do
    fields =
      case socket.assigns[:editor_schema] do
        %{fields: list} when is_list(list) -> list
        _ -> []
      end

    Enum.find(fields, fn f -> Map.get(f, "name") == field_name end)
  end

  @doc false
  def parse_idx(idx) when is_integer(idx), do: idx

  def parse_idx(idx) when is_binary(idx) do
    case Integer.parse(idx) do
      {n, _} -> n
      :error -> 0
    end
  end

  def parse_idx(_), do: 0

  @doc false
  def find_field_by_path(socket, path) do
    fields =
      case socket.assigns[:editor_schema] do
        %{fields: list} when is_list(list) -> list
        _ -> []
      end

    Path.field_at(fields, path)
  end

  @doc false
  def rebuild_panes(socket) do
    {panes, editor} =
      PaneBuilder.build(socket.assigns.dataset, socket.assigns.nav_path,
        desk: socket.assigns[:nav_desk],
        scope: ScopeHelpers.scope_opts(socket),
        scope_prefix: socket.assigns[:scope_prefix] || ""
      )

    new_schema = editor && editor[:schema]
    old_schema = socket.assigns[:editor_schema]
    nav_group = resolve_nav_group(socket.assigns[:nav_group], old_schema, new_schema)

    new_form = (editor && editor[:form]) || %{}

    editor_doc = editor && editor[:doc]
    editor_type = editor && editor[:type]
    is_draft = (editor && editor[:is_draft]) || false
    has_published = (editor && editor[:has_published]) || false

    {editor_blocks, editor_blocks_synth?} =
      Content.resolve_blocks_for_edit(editor_doc, editor_type, socket.assigns.dataset)

    same_doc? = same_editor_doc?(socket.assigns[:editor_doc], editor_doc)

    # spd-w19 — the third seam. When the walk produced NO editor, the shell used
    # to shrug ("Select a document to edit") no matter which of the nine
    # nil-editor producers fired. They are indistinguishable at the shell's
    # attrs (all return a bare nil), but they ARE distinguishable from
    # (panes, nav_path) — so the reason is derived HERE, once, and carried as a
    # single new assign the shell's `<:empty_state>` renders.
    editor_empty =
      if editor_doc,
        do: nil,
        else: socket |> empty_editor_state_for(panes) |> triage_not_found(socket)

    editor_mode =
      if same_doc?,
        do: socket.assigns[:editor_mode] || :classic,
        else: :classic

    socket =
      assign(socket,
        panes: panes,
        editor_doc: editor_doc,
        editor_schema: new_schema,
        editor_type: editor_type,
        editor_is_draft: is_draft,
        editor_has_published: has_published,
        editor_form: new_form,
        editor_mode: editor_mode,
        editor_blocks: editor_blocks,
        editor_blocks_synth?: editor_blocks_synth?,
        editor_empty: editor_empty,
        save_status:
          if(same_doc?,
            do: socket.assigns[:save_status] || "",
            else: ""
          ),
        nav_group: nav_group,
        cross_violations: compute_cross_violations(new_schema, new_form),
        published_doc:
          fetch_published_twin(
            editor_doc,
            editor_type,
            socket.assigns.dataset,
            is_draft,
            has_published,
            ScopeHelpers.scope_opts(socket)
          ),
        diff_visible:
          socket.assigns[:diff_visible] &&
            editor_doc != nil && is_draft && has_published
      )
      |> maybe_refresh_content_preview()
      |> clear_secondary_on_doc_change(same_doc?)

    case editor && editor[:view] do
      :paper ->
        socket
        |> clear_sheet_view()
        |> clear_graph_view()
        |> setup_paper_view(editor[:doc])

      :sheet ->
        socket
        |> clear_paper_view()
        |> clear_graph_view()
        |> setup_sheet_view(editor[:doc])

      :graph ->
        socket
        |> clear_paper_view()
        |> clear_sheet_view()
        |> setup_graph_view(editor[:doc], editor[:graph])

      :media_explorer ->
        socket
        |> clear_paper_view()
        |> clear_sheet_view()
        |> clear_graph_view()
        |> assign(
          editor_view: :media_explorer,
          media_kind_filter: editor[:kind_filter] || "all"
        )

      _ ->
        socket
        |> clear_paper_view()
        |> clear_sheet_view()
        |> clear_graph_view()
        |> assign(editor_view: :form, media_kind_filter: "all")
    end
  end

  defp empty_editor_state_for(socket, panes),
    do: empty_editor_state(panes, socket.assigns.nav_path)

  @doc """
  Refine a `:not_found` empty-state into the CAUSE the card can honestly name
  (Gyldendal field report 35c). The pane shape alone says "the type is real and
  the id resolved to nothing"; it cannot say WHY. Three cheap scoped reads can:

    * `:out_of_reach` — the row exists in THIS scope, but the caller's read is
      grant-narrowed (`grant_scoped_read`) and the grant does not cover it.
      Decided by re-reading WITHOUT the grant narrowing. Only a grantee can
      land here; a member's read is never narrowed.
    * `:elsewhere`    — the id exists in ANOTHER workspace the same principal is
      a member of (`Tenancy.Auth.list_workspaces_for/1` minus the current one,
      first hit wins, bounded fan-out). The card names that workspace and links
      to the document there. This is the ONLY arm allowed to say "it may live
      in another workspace" — the old card said it for every miss, and that
      one sentence sent a customer's debugging the wrong way for two weeks.
    * `:absent`       — neither of the above. No hint, no guess.

  Workspaces the principal is NOT a member of are never consulted, so a
  document's existence elsewhere cannot leak through the card.
  """
  def triage_not_found(%{reason: :not_found, doc_id: id, doc_type: type} = empty, socket)
      when is_binary(id) and is_binary(type) do
    dataset = socket.assigns.dataset
    opts = ScopeHelpers.scope_opts(socket)

    cond do
      socket.assigns[:grant_scoped_read] == true and
          exists_in_scope?(id, type, dataset, Keyword.delete(opts, :grant_scoped)) ->
        Map.merge(empty, %{cause: :out_of_reach, grant_scope: grant_scope_label(socket)})

      true ->
        case elsewhere(socket, id, type, dataset) do
          {ws, href} ->
            Map.merge(empty, %{cause: :elsewhere, elsewhere_name: ws.name, elsewhere_href: href})

          nil ->
            Map.put(empty, :cause, :absent)
        end
    end
  end

  # A grantee's desk is grant-narrowed down to the SCHEMA LIST (#15169), so a
  # type outside the grant is not merely empty — it is absent from the tree, and
  # the walk reports `:unknown_node` for a segment that names a real schema.
  # Same honest arm: the type exists in this dataset, the grant does not cover it.
  def triage_not_found(%{reason: :unknown_node, doc_type: type} = empty, socket)
      when is_binary(type) do
    opts = ScopeHelpers.scope_opts(socket)

    if socket.assigns[:grant_scoped_read] == true and
         match?(
           {:ok, _},
           Content.resolve_schema(
             type,
             socket.assigns.dataset,
             Keyword.delete(opts, :grant_scoped)
           )
         ) do
      Map.merge(empty, %{cause: :out_of_reach, grant_scope: grant_scope_label(socket)})
    else
      empty
    end
  end

  def triage_not_found(empty, _socket), do: empty

  defp exists_in_scope?(id, type, dataset, opts) do
    case Content.fetch_doc_with_draft(type, id, dataset, opts) do
      {nil, _, _} -> false
      _ -> true
    end
  end

  # Bounded: the card is rendered on every unresolved mount, so the fan-out is
  # capped rather than proportional to a principal's seat count.
  @elsewhere_fanout 12

  defp elsewhere(socket, id, type, dataset) do
    current_ws_id = socket.assigns[:current_workspace] && socket.assigns.current_workspace.id
    principal = socket.assigns[:api_token] || socket.assigns[:current_user]

    principal
    |> Tenancy.Auth.list_workspaces_for()
    |> Enum.reject(&(&1.id == current_ws_id))
    |> Enum.take(@elsewhere_fanout)
    |> Enum.find_value(fn ws ->
      case Content.fetch_doc_with_draft(type, id, dataset, workspace_id: ws.id) do
        {nil, _, _} ->
          nil

        {doc, _, _} ->
          case Tenancy.get_project_by_id(doc.project_id) do
            %{slug: proj_slug} ->
              {ws, "/w/#{ws.slug}/p/#{proj_slug}/d/#{dataset}/studio/#{type}/#{id}"}

            _ ->
              nil
          end
      end
    end)
  end

  # A one-line description of what the caller's grants DO cover, so the card
  # can say why this document is outside them without guessing.
  defp grant_scope_label(socket) do
    grants =
      case socket.assigns[:caller_context] do
        %{grants: grants} when is_list(grants) -> grants
        _ -> []
      end

    grants
    |> Enum.map(fn g ->
      [
        g.type && "type #{g.type}",
        g.dataset && "dataset #{g.dataset}",
        g.doc_id && "document #{g.doc_id}"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.join("; ")
  end

  @doc """
  Name WHY the editor is empty, from the two things that survive a nil editor:
  the pane stack and the nav path. Returns
  `%{reason: atom, doc_id: String.t() | nil, doc_type: String.t() | nil}`.

  `PaneBuilder` has nine distinct nil-editor producers and every one of them
  returns a bare `nil`, so `not_found == unknown_node == no_schema ==
  nothing_selected` by the time the shell renders (charter D260). The shapes,
  however, are distinct — this is the derivation charter D222 asked for:

    * `:nothing_selected` — no document was NAMED: either `nav_path == []`, or the
                            path drilled to a list pane and selected nothing in
                            it. Nothing went wrong, so this state does not shout.
    * `:unknown_node`     — the walk never advanced past the root pane while the
                            root pane had a selection: the first segment names
                            no node in this desk (stale link, disabled plugin).
    * `:not_found`        — the walk reached a document-list pane (it carries a
                            `type_name`), so the type is real and installed; the
                            id is simply not there.
    * `:no_schema`        — the walk reached a plain `:list` pane (no
                            `type_name`) — the …Rest column — and stopped: the
                            segment named a type that degraded to a
                            non-drillable `:document` node because it has no
                            installed schema.

  Deliberately SUPPRESSED, not named: a walk that stopped on a `:plugin_link`
  child. The node is a terminal outbound link, so no document was ever named
  and none is missing — it takes the calm `:nothing_selected` state rather
  than one of the four reasons above (task-554a33ca42c0c45a; the shape and
  both lies it used to produce are pinned in
  `studio_plugin_link_empty_state_test.exs`).

  Deliberately NOT a reason: `unrenderable_content`. A document that RESOLVES
  and cannot render is the OTHER arm, owned by
  `StudioLive.Components.unrenderable_document_notice/1` (#7897). Also deliberately absent:
  `draft_only` — D220's draft-first fetch resolves a never-published document,
  so that reason can never fire (charter D259).
  """
  @spec empty_editor_state([map()], [String.t()]) :: %{
          reason: atom(),
          doc_id: String.t() | nil,
          doc_type: String.t() | nil
        }
  def empty_editor_state(panes, nav_path) do
    last = List.last(panes || [])
    nav_path = nav_path || []

    cond do
      nav_path == [] ->
        %{reason: :nothing_selected, doc_id: nil, doc_type: nil}

      # The walk terminated on a `:plugin_link` CHILD of the last pane —
      # PaneBuilder's `%{type: :plugin_link}` branch returns `{panes, nil}`
      # because the node is a terminal outbound link, not a document that
      # failed to resolve. Nothing is missing, so nothing may shout: without
      # this arm the very next clause names a reason for a document that was
      # never named. Two lies, both observed and pinned in
      # `studio_plugin_link_empty_state_test.exs`:
      #
      #   * link nested in a group (`/studio/media-desk/media-library`) → the
      #     last pane is `role: :list` with no `type_name`, so `:no_schema`
      #     fires: "No schema for media-library is installed in this dataset."
      #   * link sitting at the desk root → the last pane is `role: :nav` with
      #     a selection, so `:unknown_node` fires: "This desk has no section
      #     named …" — about the section the human just clicked.
      #
      # It is NOT a one-frame flash. The desk LiveView issues no
      # `push_navigate` for a `:plugin_link` nav_path (the anchors navigate by
      # plain href), so the frame is the DEAD render AND every connected
      # render, and `assert_redirect` on that mount times out. The shape is
      # distinguishable from `(panes, nav_path)` alone: the terminal pane's
      # own `items` carry `%{type: :plugin_link, id: …}` (PaneBuilder
      # `list_items/2`) and one of them is what `:selected` names.
      terminated_on_plugin_link?(last) ->
        %{reason: :nothing_selected, doc_id: nil, doc_type: nil}

      match?(%{role: :nav}, last) and Map.get(last, :selected) != nil ->
        %{
          reason: :unknown_node,
          doc_id: List.last(nav_path),
          doc_type: List.first(nav_path)
        }

      # A list pane with NO selection means the human drilled to the list and
      # picked nothing — no document was named, so there is nothing to report as
      # missing. Reporting `:not_found` here would invent an id out of the type
      # segment and accuse the desk of losing a document nobody asked for.
      match?(%{role: :list}, last) and Map.get(last, :selected) == nil ->
        %{reason: :nothing_selected, doc_id: nil, doc_type: nil}

      match?(%{role: :list}, last) and Map.get(last, :type_name) != nil ->
        %{
          reason: :not_found,
          doc_id: Map.get(last, :selected),
          doc_type: Map.get(last, :type_name)
        }

      match?(%{role: :list}, last) ->
        %{
          reason: :no_schema,
          doc_id: List.last(nav_path),
          doc_type: Map.get(last, :selected)
        }

      true ->
        %{reason: :nothing_selected, doc_id: nil, doc_type: nil}
    end
  end

  # Did the desk walk stop on an outbound `:plugin_link` row? Keyed on the
  # terminal pane's OWN items rather than on the node type (the node is gone
  # by the time the panes reach here), which is why this works for both the
  # root `:nav` pane and any nested `:list` pane — both build their items with
  # `PaneBuilder.list_items/2`, and only that function emits `type:
  # :plugin_link`.
  defp terminated_on_plugin_link?(%{} = pane) do
    case Map.get(pane, :selected) do
      nil ->
        false

      selected ->
        pane
        |> Map.get(:items)
        |> List.wrap()
        |> Enum.any?(fn item ->
          is_map(item) and Map.get(item, :type) == :plugin_link and
            Map.get(item, :id) == selected
        end)
    end
  end

  defp terminated_on_plugin_link?(_), do: false

  # The secondary (split-view) pane belongs to the PRIMARY document it was
  # opened beside, so it clears on an ACTUAL primary-document identity change
  # only. rebuild_panes runs on every nav AND on same-document Save/reload
  # (the `_ ->` branch reaches clear_paper_view/1 either way), so the clear
  # must be gated here on the identity result — an unconditional clear inside
  # clear_paper_view/1 or setup_paper_view/2 wipes a live .bp-secondary-pane
  # on the very next same-doc save (D199). Left uncleaned, a surviving
  # secondary pane shrinks .editor-panel below the 860px scrim threshold at
  # standard/1024 and paints a scrim over live prose (D175/D187).
  defp clear_secondary_on_doc_change(socket, true), do: socket

  defp clear_secondary_on_doc_change(socket, false),
    do: assign(socket, secondary_doc: nil, secondary_schema: nil, secondary_type: nil)

  @doc false
  def setup_sheet_view(socket, %{} = doc) do
    socket
    |> ensure_sheet_subscription(doc)
    |> assign(editor_view: :sheet, sheet_doc: doc)
  end

  def setup_sheet_view(socket, _doc), do: clear_sheet_view(socket)

  @doc false
  def clear_sheet_view(socket) do
    socket
    |> ensure_sheet_subscription(nil)
    |> assign(sheet_doc: nil)
  end

  @doc false
  def setup_graph_view(socket, %{} = doc, graph) when is_map(graph) do
    assign(socket,
      editor_view: :graph,
      graph_doc: doc,
      graph_data: Map.merge(%{nodes: [], edges: []}, graph)
    )
  end

  def setup_graph_view(socket, _doc, _graph), do: clear_graph_view(socket)

  @doc false
  def clear_graph_view(socket) do
    if socket.assigns[:editor_view] == :graph do
      assign(socket, editor_view: :form, graph_doc: nil, graph_data: %{nodes: [], edges: []})
    else
      assign(socket, graph_doc: nil, graph_data: %{nodes: [], edges: []})
    end
  end

  @doc false
  def ensure_sheet_subscription(socket, doc) do
    {new_topic, new_presence_topic} =
      if doc != nil and connected?(socket) do
        {Barkpark.Plugins.Sheets.Session.topic(
           doc.doc_id,
           socket.assigns.dataset,
           doc.workspace_id
         ),
         Barkpark.Plugins.Sheets.Session.presence_topic(
           doc.doc_id,
           socket.assigns.dataset,
           doc.workspace_id
         )}
      else
        {nil, nil}
      end

    socket
    |> resub_sheet_deltas(new_topic)
    |> resub_sheet_presence(new_presence_topic)
  end

  @doc false
  def resub_sheet_deltas(socket, new_topic) do
    old_topic = socket.assigns[:sheet_topic]

    if new_topic == old_topic do
      socket
    else
      if old_topic, do: Phoenix.PubSub.unsubscribe(Barkpark.PubSub, old_topic)
      if new_topic, do: Phoenix.PubSub.subscribe(Barkpark.PubSub, new_topic)
      assign(socket, sheet_topic: new_topic)
    end
  end

  @doc false
  def resub_sheet_presence(socket, new_topic) do
    old_topic = socket.assigns[:sheet_presence_topic]

    if new_topic == old_topic do
      socket
    else
      if old_topic do
        Presence.untrack(self(), old_topic, socket.assigns.user_id)
        Phoenix.PubSub.unsubscribe(Barkpark.PubSub, old_topic)
      end

      presences =
        if new_topic do
          Phoenix.PubSub.subscribe(Barkpark.PubSub, new_topic)

          Presence.track(self(), new_topic, socket.assigns.user_id, %{
            name: socket.assigns.user_name,
            color: socket.assigns.user_color,
            tab: 0,
            active: "A1",
            selection: nil,
            editing: nil,
            joined_at: System.system_time(:second)
          })

          PresenceState.list(new_topic)
        else
          []
        end

      assign(socket, sheet_presence_topic: new_topic, sheet_presences: presences)
    end
  end

  @doc false
  defdelegate setup_paper_view(socket, paper), to: Paper

  @doc false
  defdelegate load_backlinks(socket, paper), to: Paper

  @doc false
  defdelegate clear_paper_view(socket), to: Paper

  @doc false
  def same_editor_doc?(%{doc_id: a}, %{doc_id: b}),
    do: Content.published_id(a) == Content.published_id(b)

  def same_editor_doc?(_, _), do: false

  @doc false
  def beta_editable?(socket) do
    socket.assigns[:editor_doc] != nil and socket.assigns[:editor_blocks] != []
  end

  @doc false
  defdelegate paper_stream_items(blocks, dataset, scope), to: Paper

  @doc false
  defdelegate paper_stream_block_id(block, index), to: Paper

  @doc false
  defdelegate paper_block_dom_id(id), to: Paper

  @doc false
  defdelegate paper_gap?(last_rev, incoming_rev), to: Paper

  @doc false
  defdelegate apply_paper_delta(socket, frame), to: Paper

  @doc false
  defdelegate refetch_paper(socket), to: Paper

  @doc false
  defdelegate reader_paper_html(socket, paper), to: Paper
  defdelegate editor_body_html(html), to: Paper

  @doc false
  defdelegate write_denied?(socket), to: Paper

  @doc false
  def fetch_published_twin(nil, _type, _dataset, _is_draft, _has_published, _scope_opts), do: nil
  def fetch_published_twin(_doc, nil, _dataset, _is_draft, _has_published, _scope_opts), do: nil
  def fetch_published_twin(_doc, _type, _dataset, false, _has_published, _scope_opts), do: nil
  def fetch_published_twin(_doc, _type, _dataset, _is_draft, false, _scope_opts), do: nil

  def fetch_published_twin(doc, type, dataset, true, true, scope_opts) do
    case Content.get_document(Content.published_id(doc.doc_id), type, dataset, scope_opts) do
      {:ok, pub} -> pub
      _ -> nil
    end
  end

  @doc false
  def compute_cross_violations(nil, _), do: []
  def compute_cross_violations(_, form) when not is_map(form), do: []

  def compute_cross_violations(schema, form) do
    Barkpark.Content.CrossValidator.violations(schema, form)
  end

  @doc false
  def resolve_nav_group(_current, _old, nil), do: nil

  def resolve_nav_group(current, old, new_schema) do
    cond do
      schema_id(new_schema) == schema_id(old) and current != nil -> current
      true -> first_group_name(new_schema)
    end
  end

  @doc false
  def schema_id(nil), do: nil
  def schema_id(schema), do: Map.get(schema, :name) || Map.get(schema, "name")

  @doc false
  def first_group_name(schema) do
    case BarkparkWeb.StudioComponents.schema_groups(schema) do
      [%{"name" => name} | _] -> name
      _ -> nil
    end
  end

  @doc false
  # THE SHARES PANEL'S READ HALF, scoped (task-c91e5e19da811fe5).
  #
  # `Sharing.shares_env/0` and `list_stored/0` are INSTANCE-WIDE, and this
  # function used to take no scope argument at all. Its only gate was
  # `Caps.admin?/1` in the callers — admin of the MOUNTED workspace — so an
  # account admin of workspace A was assigned every other tenant's share rows:
  # their workspace/project/dataset slugs, their surfaces, and each share's
  # anonymous `:papers` reader URL (`Sharing.share_urls/0`, a tokenless entry
  # point into that tenant's shared data). That is strictly more than the HTTP
  # twin grants: `GET /v1/shares` runs `:require_admin`, which an account
  # session cannot satisfy at all.
  #
  # THE SAME PREDICATE AS THE WRITE HALVES, deliberately. `shares_add/2` and
  # `shares_remove/2` both clamp with `declarable_scope?/2` — and the latter's
  # comment calls its own clamp "the availability mirror of the disclosure
  # hole". This is that disclosure hole, closed with the predicate that was
  # already there rather than a second one, so what the panel LISTS and what it
  # lets you TOUCH can never drift apart.
  #
  # THE FOREIGN ARM IS THE WRITE HALVES' OWN PREDICATE (task-87c43ffa0be7ad95).
  #
  # This filter used to be `declarable_scope?/2` alone, whose foreign arm is
  # `instance_declare_authority?/1` — `Auth.has_permission?(token, "admin")`,
  # a GLOBAL bit with no membership lookup and no workspace resolution. That
  # made the token arm of the clamp VACUOUS rather than merely weak:
  # `Caps.admin?/1`'s token arm already requires the SAME global bit to open
  # the panel at all, so every token principal that could reach this listing
  # satisfied the foreign arm for EVERY scope, and nothing was filtered.
  #
  # Meanwhile PR #15025 clamped both WRITE halves with
  # `Handlers.Shares.target_workspace_admits?/2`, which resolves the scope's
  # workspace and demands `Tenancy.Auth.workspace_admin?/2` — the predicate
  # `POST/DELETE /v1/shares` enforces. So the panel LISTED, for a global-admin
  # token seated as a plain `member` of workspace B, exactly the rows it
  # refused to let that token declare or remove. The read half now asks THAT
  # function — not a second copy of it — so the disclosure half cannot drift
  # from the availability half again.
  #
  # DELIBERATELY `workspace_admin?/2`, NEVER `authorize/3`: `authorize/3`'s
  # api_token arm ORs the token's GLOBAL permissions[] with membership, so the
  # attacker shape passes it. That ruling is recorded at
  # `Handlers.Shares.target_workspace_admits?/2` and in `ShareController`.
  #
  # A principal that administers the foreign workspace still sees its rows: the
  # list is scoped to authority, not to the mounted workspace.
  def load_share_rows(socket) do
    env = Enum.map(Barkpark.Sharing.shares_env(), &share_row(&1, "env"))
    stored = Enum.map(Barkpark.Sharing.list_stored(), &share_row(&1, "stored"))
    urls = share_url_index()

    env
    |> Enum.concat(stored)
    |> Enum.filter(&share_scope_visible?(socket, &1.scope))
    |> Enum.map(fn row -> %{row | url: Map.get(urls, row.scope)} end)
  end

  @doc false
  # May this caller act on — and see — a share scope?
  #
  # ONE predicate, three enforcement points: `shares_add/2`, `shares_remove/2`,
  # and `load_share_rows/1` above. It lived as a private in `Handlers.Shares`
  # while the read path had no clamp at all; that split is precisely how the
  # disclosure half stayed open after the availability half was closed.
  #
  # Splits on "/" and takes the first segment, so it accepts a full
  # `ws/proj/dataset` scope (add, and a row's `:scope`) and a bare workspace
  # slug (remove) identically.
  # @canonical capability:share-scope-tenancy aka:declarable_scope,shares panel scope,cross-workspace share,share disclosure clamp
  def declarable_scope?(socket, scope) do
    mounted = scope_slug(socket.assigns[:current_workspace], "default")

    case scope_workspace(scope) do
      ^mounted -> true
      _ -> instance_declare_authority?(socket)
    end
  end

  @doc false
  # MAY THIS CALLER SEE THIS SHARE ROW? The read half's clamp, and the reason
  # `load_share_rows/1` above is no longer vacuous on the token arm.
  #
  # BOTH predicates, ANDed, deliberately: `declarable_scope?/2` keeps the read
  # half a third enforcement point of the shared predicate (so the listing can
  # never be WIDER than what the write halves' first gate admits), and
  # `Handlers.Shares.target_workspace_admits?/2` adds what that first gate does
  # not ask on the foreign arm — the scope's own workspace, resolved, with
  # `Tenancy.Auth.workspace_admin?/2` demanded on it. The mounted arm is
  # untouched by both: there `Caps.admin?/1` has already proved an admin seat
  # in this workspace, for BOTH principal kinds.
  def share_scope_visible?(socket, scope) do
    declarable_scope?(socket, scope) and
      SharesHandler.target_workspace_admits?(socket, scope_workspace(scope))
  end

  # The workspace segment of a share scope. ONE splitter for
  # `declarable_scope?/2` and `share_scope_visible?/2`, so a full
  # `ws/proj/dataset` scope and a bare workspace slug are read identically by
  # both — and neither can drift about what "the scope's workspace" means.
  defp scope_workspace(scope) do
    scope
    |> String.split("/")
    |> List.first()
    |> to_string()
    |> String.trim()
  end

  @doc false
  # The authority `/v1/shares` demands: a token carrying the `admin` permission
  # (`BarkparkWeb.Plugs.RequireAdmin`). Never the account arm.
  #
  # Fail-closed on the account arm: `Auth.has_permission?/2` reads
  # `token.permissions` with no nil clause, so an account session (no
  # `:api_token`) would RAISE rather than deny. Match the struct instead.
  def instance_declare_authority?(socket) do
    case socket.assigns[:api_token] do
      %Barkpark.Auth.ApiToken{} = token -> Barkpark.Auth.has_permission?(token, "admin")
      _ -> false
    end
  end

  @doc false
  def share_row(%Barkpark.Sharing.Share{} = s, source) do
    %{
      scope: "#{s.workspace_slug}/#{s.project_slug}/#{s.dataset}",
      surfaces: Enum.map_join(s.surfaces, ", ", &Atom.to_string/1),
      access: Atom.to_string(s.access),
      source: source,
      url: nil
    }
  end

  @doc false
  def share_url_index do
    Barkpark.Sharing.share_urls()
    |> Map.new(fn {s, url} -> {"#{s.workspace_slug}/#{s.project_slug}/#{s.dataset}", url} end)
  end

  @doc false
  def shares_scope_prefill(socket) do
    ws = scope_slug(socket.assigns[:current_workspace], "default")
    proj = scope_slug(socket.assigns[:current_project], "default")
    dataset = socket.assigns[:dataset] || "production"
    "#{ws}/#{proj}/#{dataset}"
  end

  @doc false
  def scope_slug(%{slug: slug}, _default) when is_binary(slug), do: slug
  def scope_slug(_, default), do: default

  @doc false
  # `fresh` is `%{link_id => raw_token}` for links MINTED IN THIS SESSION, held
  # in socket assigns and never in the database
  # (`arpss-w8-bl-share-link-raw-token-at-rest`, RULED 2026-09-02: retire the
  # plaintext column). A stored row carries only its SHA256 digest, so a link
  # this socket did not just mint has NO url — `nil` here is the honest answer,
  # not a missing value, and the popover renders the regenerate affordance for
  # it. This is the Studio half of the same one-way rule the HTTP mint 201 obeys.
  def load_item_links(socket, item, fresh \\ %{})

  def load_item_links(socket, %{kind: kind, ref_type: ref_type, ref_id: ref_id}, fresh) do
    case socket.assigns[:current_workspace] do
      %{id: ws_id} ->
        base = Barkpark.Sharing.share_link_base()

        Barkpark.Sharing.Links.list_for(ws_id, kind, ref_type, ref_id)
        |> Enum.map(fn l ->
          raw = Map.get(fresh || %{}, l.id)
          %{id: l.id, access: l.access, url: raw && link_url(base, raw)}
        end)

      _ ->
        []
    end
  end

  def load_item_links(_socket, _, _), do: []

  @doc false
  def link_url(nil, token), do: "/s/#{token}"
  def link_url(base, token), do: "#{base}/s/#{token}"

  @doc false
  # `project_id` STAYS nil-able here on purpose (task-2da739b78e938be0): this
  # function reports the socket's scope, it does not invent one. A nil reaches
  # `ShareLink.changeset/2`, which REFUSES the write — a link bound to no project
  # is revocable by no cascade. `ItemShare.item_share_create/2` short-circuits
  # first so the refusal carries a reason. Substituting a default project HERE
  # would bind the link to a project nobody chose.
  def item_link_attrs(socket, item, access) do
    %{
      workspace_id: socket.assigns.current_workspace.id,
      project_id: socket.assigns[:current_project] && socket.assigns.current_project.id,
      dataset: socket.assigns[:dataset] || "production",
      kind: item.kind,
      ref_type: item.ref_type,
      ref_id: item.ref_id,
      access: access
    }
  end
end
