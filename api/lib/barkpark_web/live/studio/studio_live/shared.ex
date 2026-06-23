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
  alias Barkpark.PortableDoc.{Projection, Render}
  alias BarkparkWeb.Presence
  alias BarkparkWeb.ScopeHelpers
  alias BarkparkWeb.Studio.{PaneBuilder, PresenceState}
  alias BarkparkWeb.Studio.StudioLive.{Blocks, Mount, Path, Paths}

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
  def seed_new_doc_content(_type), do: %{}

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

  @doc false
  def paper_pane_op(socket, op) do
    paper = socket.assigns[:paper_doc]
    slug = paper && paper.doc_id
    dataset = socket.assigns.dataset

    cond do
      is_nil(slug) ->
        socket

      true ->
        case Content.apply_paper_block_op(slug, op, dataset) do
          {:ok, _result} ->
            sync_paper_edit_doc(socket)

          {:error, _reason} ->
            put_flash(socket, :error, "Edit failed")
        end
    end
  end

  @doc false
  def document_op(socket, op) do
    doc = socket.assigns[:editor_doc]
    type = socket.assigns[:editor_type]
    dataset = socket.assigns.dataset

    case Content.apply_document_block_op(doc.doc_id, type, op, dataset, hook_opts(socket)) do
      {:ok, _result} ->
        sync_editor_blocks(socket)

      {:error, _reason} ->
        put_flash(socket, :error, "Edit failed")
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
    after_id = if idx >= 2, do: Map.get(Enum.at(blocks, idx - 2), "id"), else: nil
    paper_op(socket, %{"op" => "move-block", "id" => Map.get(moved, "id"), "after" => after_id})
  end

  def paper_reorder(socket, blocks, idx, "down") when idx < length(blocks) - 1 do
    moved = Enum.at(blocks, idx)
    anchor_id = Map.get(Enum.at(blocks, idx + 1), "id")
    paper_op(socket, %{"op" => "move-block", "id" => Map.get(moved, "id"), "after" => anchor_id})
  end

  def paper_reorder(socket, _blocks, _idx, _dir), do: socket

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
      case action.(doc, type) do
        {:ok, _} ->
          {:noreply, socket |> put_flash(:info, msg) |> rebuild_panes()}

        {:error, {:halted, reason}} ->
          {:noreply, put_flash(socket, :error, "#{msg} cancelled: #{reason}")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Action failed")}
      end
    else
      {:noreply, socket}
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
      {ok, halted, err} =
        Enum.reduce(ids, {0, 0, 0}, fn id, {ok, halted, err} ->
          result =
            case kind do
              :publish -> Content.publish_document(id, type, dataset, opts)
              :unpublish -> Content.unpublish_document(id, type, dataset, opts)
            end

          case result do
            {:ok, _} -> {ok + 1, halted, err}
            {:error, {:halted, _}} -> {ok, halted + 1, err}
            _ -> {ok, halted, err + 1}
          end
        end)

      verb = if kind == :publish, do: "Published", else: "Unpublished"

      flash =
        cond do
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
      |> put_flash(:info, flash)
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
        scope: ScopeHelpers.scope_opts(socket)
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

    editor_mode =
      if same_editor_doc?(socket.assigns[:editor_doc], editor_doc),
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
        save_status: socket.assigns[:save_status] || "",
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
  def setup_paper_view(socket, %{content: content} = paper) when is_map(content) do
    blocks = Map.get(content, "blocks")
    rev = Map.get(content, "rev") || 0
    html = Map.get(content, "body_html") || ""
    {linked, unlinked} = load_backlinks(socket, paper)

    if is_list(blocks) do
      socket
      |> assign(
        editor_view: :paper,
        paper_doc: paper,
        paper_rev: rev,
        paper_html: html,
        paper_block_mode: true,
        paper_edit_mode: false,
        backlinks_linked: linked,
        backlinks_unlinked: unlinked,
        backlinks_open: true
      )
      |> stream(
        :paper_blocks,
        paper_stream_items(blocks, socket.assigns.dataset, ScopeHelpers.scope_opts(socket)),
        reset: true
      )
    else
      socket
      |> assign(
        editor_view: :paper,
        paper_doc: paper,
        paper_rev: rev,
        paper_html: html,
        paper_block_mode: false,
        paper_edit_mode: false,
        backlinks_linked: linked,
        backlinks_unlinked: unlinked,
        backlinks_open: true
      )
      |> stream(:paper_blocks, [], reset: true)
    end
  end

  def setup_paper_view(socket, _paper), do: clear_paper_view(socket)

  @doc """
  Read-only inbound-reference load for the backlinks panel. Resolves the paper's
  published id and runs the arrayOf-aware `Content.Graph.reverse_referencers/2`
  ONCE (scope + dataset bound), then partitions the single result into two
  mutually-exclusive lists by edge origin:

    * `linked`  — direct schema-field reference edges (`plugin_source == nil`),
                  i.e. real "Linked mentions".
    * `derived` — plugin/derived inbound edges (`plugin_source` set).

  Returns `{[], []}` for a draft / unresolvable / never-referenced paper — the
  panel renders an empty state, never crashes.
  """
  def load_backlinks(socket, %{doc_id: doc_id}) when is_binary(doc_id) do
    published_id = Content.published_id(doc_id)
    opts = [dataset: socket.assigns.dataset] ++ ScopeHelpers.scope_opts(socket)

    published_id
    |> Content.Graph.reverse_referencers(opts)
    |> Enum.split_with(fn ref -> is_nil(ref[:plugin_source]) end)
  end

  def load_backlinks(_socket, _paper), do: {[], []}

  @doc false
  def clear_paper_view(socket) do
    if socket.assigns[:editor_view] == :paper do
      assign(socket,
        editor_view: :form,
        paper_doc: nil,
        paper_rev: 0,
        paper_html: "",
        paper_block_mode: false,
        paper_edit_mode: false,
        backlinks_linked: [],
        backlinks_unlinked: [],
        backlinks_open: true
      )
    else
      assign(socket,
        editor_view: :form,
        backlinks_linked: [],
        backlinks_unlinked: [],
        backlinks_open: true
      )
    end
  end

  @doc false
  def same_editor_doc?(%{doc_id: a}, %{doc_id: b}),
    do: Content.published_id(a) == Content.published_id(b)

  def same_editor_doc?(_, _), do: false

  @doc false
  def beta_editable?(socket) do
    socket.assigns[:editor_doc] != nil and socket.assigns[:editor_blocks] != []
  end

  @doc false
  def paper_stream_items(blocks, dataset, scope) do
    resolver = fn value, ref_type -> Content.reference_title(value, ref_type, dataset, scope) end

    codelist_resolver = fn plugin, codelist_id, code ->
      Content.codelist_label(plugin, codelist_id, code)
    end

    opts = %{ref_resolver: resolver, codelist_resolver: codelist_resolver, style: :article}

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

    case slug && Content.get_paper(slug, dataset) do
      nil ->
        socket

      paper ->
        content = paper.content || %{}

        case Map.get(content, "blocks") do
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
            |> assign(:paper_html, Map.get(content, "body_html") || "")
            |> assign(:paper_rev, Map.get(content, "rev") || 0)
            |> assign(:paper_block_mode, false)
        end
    end
  end

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
