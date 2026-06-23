defmodule BarkparkWeb.Studio.StudioLive.Handlers.Fields do
  @moduledoc """
  Document lifecycle (new/save/autosave) + editor toggles + ArrayField ops.
  Behaviour-preserving extraction of the StudioLive handler bodies.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView

  alias Barkpark.Content
  alias BarkparkWeb.Components.Fields.ArrayField
  alias BarkparkWeb.Studio.StudioLive
  alias BarkparkWeb.Studio.StudioLive.Shared

  def new_document(%{"type" => type}, socket) do
    id = "#{type}-#{:rand.uniform(999_999)}"

    case Content.create_document(
           type,
           %{"doc_id" => id, "title" => "Untitled", "content" => Shared.seed_new_doc_content(type)},
           socket.assigns.dataset,
           Shared.hook_opts(socket)
         ) do
      {:ok, doc} ->
        pub_id = Content.published_id(doc.doc_id)
        new_path = socket.assigns.nav_path ++ [pub_id]
        {:noreply, push_patch(socket, to: Shared.studio_path(socket, new_path, socket.assigns.dataset))}

      {:error, {:halted, reason}} ->
        {:noreply, put_flash(socket, :error, "Create cancelled: #{reason}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to create")}
    end
  end

  def save(%{"doc" => params}, socket) do
    socket = Shared.do_autosave(socket, params)

    case socket.assigns[:save_status] do
      "Saved" -> {:noreply, socket |> put_flash(:info, "Saved") |> Shared.rebuild_panes()}
      _ -> {:noreply, socket}
    end
  end

  def slug_generate(%{"field" => field}, socket) do
    title =
      case Map.get(socket.assigns[:editor_form] || %{}, "title") do
        t when is_binary(t) and t != "" -> t
        _ -> socket.assigns[:editor_doc] && socket.assigns.editor_doc.title
      end

    case title do
      t when is_binary(t) and t != "" ->
        {:noreply, Shared.do_autosave(socket, %{field => Barkpark.Tenancy.slugify(t)})}

      _ ->
        {:noreply, socket}
    end
  end

  def autosave(%{"doc" => params}, socket) do
    {:noreply, Shared.do_autosave(socket, params)}
  end

  def autosave(_params, socket) do
    {:noreply, socket}
  end

  def toggle_content_preview(socket) do
    {:noreply, assign(socket, content_preview_visible: !socket.assigns.content_preview_visible)}
  end

  def toggle_diff(socket) do
    {:noreply, assign(socket, diff_visible: !socket.assigns.diff_visible)}
  end

  def editor_set_mode(%{"mode" => mode}, socket) do
    next =
      case mode do
        "beta" -> if Shared.beta_editable?(socket), do: :beta, else: :classic
        _ -> :classic
      end

    socket =
      if next == :beta, do: Shared.sync_editor_blocks(socket), else: socket

    {:noreply, assign(socket, editor_mode: next)}
  end

  def array_op(%{"action" => action} = params, socket) do
    path = StudioLive.parse_path(params["path"] || "")

    {field, key_path} =
      case path do
        [] ->
          case params["field"] do
            name when is_binary(name) -> {Shared.find_field(socket, name), [name]}
            _ -> {nil, []}
          end

        _ ->
          {Shared.find_field_by_path(socket, path), path}
      end

    if is_nil(field) or key_path == [] do
      {:noreply, socket}
    else
      idx = Shared.parse_idx(params["index"])
      form = socket.assigns[:editor_form] || %{}
      current = StudioLive.list_value_at(form, key_path)

      new_list =
        case action do
          "add_row" -> ArrayField.add_row(current, StudioLive.empty_for_of(field))
          "remove_row" -> ArrayField.remove_row(current, idx)
          "move_up" -> ArrayField.move_up(current, idx)
          "move_down" -> ArrayField.move_down(current, idx)
          _ -> current
        end

      new_form = StudioLive.put_value_at(form, key_path, new_list)
      {:noreply, Shared.do_autosave(socket, new_form)}
    end
  end
end
