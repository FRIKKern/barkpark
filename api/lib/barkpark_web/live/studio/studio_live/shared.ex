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
  alias BarkparkWeb.Studio.StudioLive.{Mount, Path, Paths}
  alias BarkparkWeb.Studio.StudioLive.Shared.Paper

  @doc false
  def maybe_open_shares(socket, %{"shares" => "open"}) do
    if Mount.shares_admin?(socket) do
      assign(socket,
        show_shares: true,
        shares_error: nil,
        shares_rows: load_share_rows(),
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

  @doc false
  def do_autosave(socket, params) do
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

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Action failed")}
      end
    else
      {:noreply, socket}
    end
  end

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
    "duplicate of #{incumbent} — extend that document, or differentiate this one's title/tags"
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
        else: empty_editor_state(panes, socket.assigns.nav_path)

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
  def load_share_rows do
    env = Enum.map(Barkpark.Sharing.shares_env(), &share_row(&1, "env"))
    stored = Enum.map(Barkpark.Sharing.list_stored(), &share_row(&1, "stored"))
    urls = share_url_index()

    Enum.map(env ++ stored, fn row -> %{row | url: Map.get(urls, row.scope)} end)
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
  def load_item_links(socket, %{kind: kind, ref_type: ref_type, ref_id: ref_id}) do
    case socket.assigns[:current_workspace] do
      %{id: ws_id} ->
        base = Barkpark.Sharing.share_link_base()

        Barkpark.Sharing.Links.list_for(ws_id, kind, ref_type, ref_id)
        |> Enum.map(fn l ->
          %{id: l.id, access: l.access, url: l.token && link_url(base, l.token)}
        end)

      _ ->
        []
    end
  end

  def load_item_links(_socket, _), do: []

  @doc false
  def link_url(nil, token), do: "/s/#{token}"
  def link_url(base, token), do: "#{base}/s/#{token}"

  @doc false
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
