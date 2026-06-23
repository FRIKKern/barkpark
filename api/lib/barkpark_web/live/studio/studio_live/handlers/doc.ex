defmodule BarkparkWeb.Studio.StudioLive.Handlers.Doc do
  @moduledoc """
  Publish / unpublish (blast-radius guard) / duplicate. Behaviour-preserving
  extraction of the StudioLive handler bodies.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView

  alias Barkpark.Content
  alias BarkparkWeb.ScopeHelpers
  alias BarkparkWeb.Studio.StudioLive.Shared

  def publish(socket) do
    doc = socket.assigns[:editor_doc]
    type = socket.assigns[:editor_type]

    if doc && type do
      content = Content.build_content(socket.assigns.editor_form, socket.assigns[:editor_schema])
      title = Map.get(socket.assigns.editor_form, "title", doc.title)

      case Content.validate_document(type, title, content, socket.assigns.dataset) do
        {:error, errs} ->
          {:noreply,
           socket
           |> assign(validation_errors: errs)
           |> put_flash(:error, "Fix validation errors before publishing")}

        _ ->
          opts = Shared.hook_opts(socket)

          Shared.do_action(
            socket,
            fn d, t ->
              Content.publish_document(
                Content.published_id(d.doc_id),
                t,
                socket.assigns.dataset,
                opts
              )
            end,
            "Published"
          )
      end
    else
      {:noreply, socket}
    end
  end

  def unpublish(socket) do
    doc = socket.assigns[:editor_doc]
    type = socket.assigns[:editor_type]

    if doc && type do
      published_id = Content.published_id(doc.doc_id)

      refs =
        Content.Graph.reverse_referencers(
          published_id,
          [dataset: socket.assigns.dataset] ++ ScopeHelpers.scope_opts(socket)
        )

      if refs == [] do
        Shared.do_unpublish(socket)
      else
        {:noreply, assign(socket, show_unpublish_guard: true, unpublish_refs: refs)}
      end
    else
      {:noreply, socket}
    end
  end

  def close_unpublish_guard(socket) do
    {:noreply, assign(socket, show_unpublish_guard: false, unpublish_refs: [])}
  end

  def confirm_unpublish(params, socket) do
    doc = socket.assigns[:editor_doc]

    if doc && socket.assigns[:editor_type] do
      socket =
        if params["disconnect"] == "true" do
          Content.disconnect_references(
            doc.doc_id,
            socket.assigns.dataset,
            ScopeHelpers.scope_opts(socket)
          )

          socket
        else
          socket
        end

      socket
      |> assign(show_unpublish_guard: false, unpublish_refs: [])
      |> Shared.do_unpublish()
    else
      {:noreply, assign(socket, show_unpublish_guard: false, unpublish_refs: [])}
    end
  end

  def duplicate_doc(socket) do
    doc = socket.assigns[:editor_doc]
    type = socket.assigns[:editor_type]

    if doc && type do
      case Content.clone_document(doc, type, socket.assigns.dataset, Shared.hook_opts(socket)) do
        {:ok, new_doc} ->
          pub_id = Content.published_id(new_doc.doc_id)
          base = Enum.take(socket.assigns.nav_path, length(socket.assigns.nav_path) - 1)
          new_path = base ++ [pub_id]

          {:noreply,
           socket
           |> put_flash(:info, "Duplicated as #{pub_id}")
           |> push_patch(to: Shared.studio_path(socket, new_path, socket.assigns.dataset))}

        {:error, {:halted, reason}} ->
          {:noreply, put_flash(socket, :error, "Duplicate cancelled: #{reason}")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to duplicate")}
      end
    else
      {:noreply, socket}
    end
  end
end
