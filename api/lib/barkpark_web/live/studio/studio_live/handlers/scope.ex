defmodule BarkparkWeb.Studio.StudioLive.Handlers.Scope do
  @moduledoc """
  Pane navigation + workspace/project/dataset scope switch + switcher create
  affordances. Behaviour-preserving extraction of the StudioLive handler bodies.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView

  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.StudioLive.Shared

  def select(%{"pane" => pane_str, "id" => id}, socket) do
    case Integer.parse(pane_str) do
      {pane_idx, ""} when pane_idx >= 0 ->
        # The clicked pane's own address (`:path`, stamped by PaneBuilder.build/3
        # from the NORMALIZED segments) is the prefix — never a slice of the raw
        # URL by rendered index, which appended the id whenever the desk had
        # normalized a demoted type into its group (#35b). The fallback keeps the
        # old formula for a pane built without the stamp (plugin panes that
        # bypass build/3).
        prefix =
          case Enum.at(socket.assigns[:panes] || [], pane_idx) do
            %{path: path} when is_list(path) -> path
            _ -> Enum.take(socket.assigns.nav_path, pane_idx)
          end

        new_path = prefix ++ [id]

        # spd-bl-focus-after-select — THE DECISION, bucket by bucket (full
        # write-up in studio_focus_after_select_test.exs):
        #   wide/standard  -> nothing. The clicked row survives the patch
        #                     (it re-renders wearing aria-current), so the
        #                     browser never moves activeElement.
        #   narrow/phone   -> the clicked row is DESTROYED (the pane strips
        #                     at narrow and hides at phone), so focus falls
        #                     to <body>. The strip is refused as a target —
        #                     its activation truncates the document segment,
        #                     i.e. focusing it puts "close the document"
        #                     under the keyboard user's hands — and at phone
        #                     no pane element exists at all. The mark lands
        #                     on the opened document's own header instead
        #                     (document_header/1), which announces the title.
        # One-shot like focus_pane_idx: expand_pane and a width-bucket flip
        # spend it, so it never re-fires on an unrelated re-render.
        {:noreply,
         socket
         |> assign(
           focus_pane_idx: nil,
           focus_doc_on_open: socket.assigns[:width_bucket] in ["narrow", "phone"]
         )
         |> push_patch(to: Shared.studio_path(socket, new_path, socket.assigns.dataset))}

      _ ->
        {:noreply, socket}
    end
  end

  def select_group(%{"group" => name}, socket) do
    {:noreply, assign(socket, nav_group: name)}
  end

  def select_desk(%{"desk" => name}, socket) do
    desk = if name == "" or name == socket.assigns[:nav_desk], do: nil, else: name

    {:noreply,
     push_patch(socket,
       to: Shared.studio_path(socket, socket.assigns.nav_path, socket.assigns.dataset, desk: desk)
     )}
  end

  def switch_workspace(%{"workspace" => slug}, socket) do
    case Tenancy.get_workspace_by_slug(slug) do
      nil ->
        {:noreply, socket}

      workspace ->
        cond do
          not Shared.can_reach_workspace?(socket, workspace) ->
            {:noreply, socket}

          is_nil(Shared.initial_project(workspace)) ->
            {:noreply,
             put_flash(socket, :error, "Workspace has no projects yet — create one first")}

          true ->
            project = Shared.initial_project(workspace)

            {:noreply,
             socket
             |> assign(current_workspace: workspace, current_project: project)
             |> Shared.sync_scope_prefix()
             |> Shared.rescope_dataset_for_project(project)}
        end
    end
  end

  def switch_project(%{"project" => slug}, socket) do
    ws = socket.assigns[:current_workspace]

    with %{} = ws <- ws,
         true <- Shared.can_reach_workspace?(socket, ws),
         %{} = project <- Tenancy.get_project(ws.slug, slug) do
      {:noreply,
       socket
       |> assign(current_project: project)
       |> Shared.sync_scope_prefix()
       |> Shared.rescope_dataset_for_project(project)}
    else
      _ -> {:noreply, socket}
    end
  end

  def switch_dataset(%{"dataset" => slug}, socket) do
    project = socket.assigns[:current_project]

    cond do
      not is_binary(slug) or slug == "" ->
        {:noreply, socket}

      slug == socket.assigns[:dataset] ->
        {:noreply, socket}

      Shared.project_has_dataset?(project, slug) ->
        {:noreply, push_patch(socket, to: Shared.studio_path(socket, [], slug))}

      true ->
        {:noreply, socket}
    end
  end

  def toggle_create(%{"target" => target}, socket)
      when target in ["workspace", "project"] do
    next = if socket.assigns[:create_open] == target, do: nil, else: target
    {:noreply, assign(socket, create_open: next)}
  end

  def toggle_create(_params, socket), do: {:noreply, socket}

  def create_workspace(%{"name" => name}, socket) do
    case socket.assigns[:api_token] do
      %Barkpark.Auth.ApiToken{} = token ->
        case Tenancy.create_workspace_with_owner(%{name: name}, token) do
          {:ok, workspace} ->
            project = Shared.initial_project(workspace)

            {:noreply,
             socket
             |> assign(create_open: nil, current_workspace: workspace, current_project: project)
             |> Shared.sync_scope_prefix()
             |> put_flash(:info, "Workspace created")
             |> Shared.rescope_dataset_for_project(project)}

          {:error, changeset} ->
            {:noreply, put_flash(socket, :error, Shared.create_error(changeset, "workspace"))}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Sign in to create a workspace")}
    end
  end

  def create_workspace(_params, socket), do: {:noreply, socket}

  def create_project(%{"name" => name}, socket) do
    ws = socket.assigns[:current_workspace]

    cond do
      not match?(%Barkpark.Auth.ApiToken{}, socket.assigns[:api_token]) ->
        {:noreply, put_flash(socket, :error, "Sign in to create a project")}

      is_nil(ws) ->
        {:noreply, socket}

      true ->
        case Tenancy.create_project_with_dataset(ws, %{name: name}) do
          {:ok, created} ->
            project = Tenancy.get_project_by_id(created.id) || created

            {:noreply,
             socket
             |> assign(create_open: nil, current_project: project)
             |> Shared.sync_scope_prefix()
             |> put_flash(:info, "Project created")
             |> Shared.rescope_dataset_for_project(project)}

          {:error, changeset} ->
            {:noreply, put_flash(socket, :error, Shared.create_error(changeset, "project"))}
        end
    end
  end

  def create_project(_params, socket), do: {:noreply, socket}

  # Activating the collapsed strip DESTROYS it (the <button> is replaced by the
  # expanded <div>), so the browser drops focus to <body> — measured live on the
  # authenticated desk, charter D79. `:focus_pane_idx` marks the pane this
  # navigation just re-opened; the shell renders `phx-mounted={JS.focus()}` on
  # that pane alone, so focus lands where the strip said it would. Drilling
  # (`select/2`) and a width-bucket flip both clear it, so the mark is spent on
  # the navigation that set it and never re-fires on an unrelated re-render.
  def expand_pane(%{"idx" => idx_str}, socket) do
    case Integer.parse(idx_str) do
      {idx, ""} when idx >= 0 ->
        new_path = Enum.take(socket.assigns.nav_path, idx)

        {:noreply,
         socket
         |> assign(focus_pane_idx: idx, focus_doc_on_open: false)
         |> push_patch(to: Shared.studio_path(socket, new_path, socket.assigns.dataset))}

      _ ->
        {:noreply, socket}
    end
  end
end
