defmodule BarkparkWeb.Studio.StudioLive.Handlers.Scope do
  @moduledoc """
  Pane navigation + workspace/project/dataset scope switch + switcher create
  affordances. Behaviour-preserving extraction of the StudioLive handler bodies.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView

  require Logger

  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.ScopeResolver
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
        # spd-w18-bl-select-detects-dead-destination — THE NAVIGATION RECEIPT.
        #
        # `push_patch/2` is fire-and-forget: it hands the destination to
        # `handle_params/3` and returns. If that transition RAISES, the
        # LiveView process dies before anything is flushed, so the browser
        # keeps the old URL, the row never wears `aria-current`, and the
        # console stays silent — a crashing destination is byte-identical to
        # a dead button (measured: 8s of nothing clicking the …Rest row while
        # `/studio/rest` 500'd, spd-w18-nil-icon-500).
        #
        # So select/2 does not merely fire. It writes a RECEIPT naming the row
        # it just asked for, and the destination's own `handle_params/3` is
        # the only thing that can settle it (`settle_pending_select/2` below,
        # called from `StudioLive.handle_params/3`):
        #
        #   * transition returns  -> the receipt is TORN UP. Nothing else
        #                            changes; this is every navigation today.
        #   * transition RAISES   -> the receipt is still open, so we know
        #                            WHICH row the user clicked, and the raise
        #                            is converted into a named flash instead
        #                            of a dead process. The receipt is the
        #                            answer to "how does select learn": the
        #                            rescue is licensed by, and names, the
        #                            intent select recorded.
        #
        # The receipt is one-shot and scoped: a `handle_params` with NO open
        # receipt (mount, back/forward, a scope switch) is NOT rescued — a
        # crash there must still crash, because swallowing it would leave the
        # socket un-built and the next render would die anyway, further from
        # the cause.
        {:noreply,
         socket
         |> assign(
           focus_pane_idx: nil,
           focus_doc_on_open: socket.assigns[:width_bucket] in ["narrow", "phone"],
           pending_select: %{id: id, path: new_path},
           nav_error: nil
         )
         |> push_patch(to: Shared.studio_path(socket, new_path, socket.assigns.dataset))}

      _ ->
        {:noreply, socket}
    end
  end

  @doc """
  Settle the receipt `select/2` wrote, by running the destination transition.

  This is the OTHER half of the navigation receipt (see `select/2`). It wraps
  the whole `handle_params` transition so the ONE navigation the user cannot
  see the result of — a drill into a destination they have never rendered —
  can never come back as silence.

  With no open receipt the transition runs bare: this is deliberately NOT a
  blanket rescue over `handle_params/3`.
  """
  def settle_pending_select(socket, transition) when is_function(transition, 1) do
    case socket.assigns[:pending_select] do
      nil ->
        transition.(socket)

      %{id: id} ->
        try do
          {:noreply, socket} = transition.(socket)
          {:noreply, assign(socket, pending_select: nil)}
        rescue
          error ->
            Logger.error(
              "studio select: destination #{inspect(id)} raised — " <>
                Exception.format(:error, error, __STACKTRACE__)
            )

            message = "Couldn't open \"#{id}\" — that view failed to load. Nothing was changed."

            # BOTH surfaces on purpose. The flash is the human notice; the
            # `nav_error` assign is the DOM binary the desk itself renders
            # (`studio-nav-error`, role="alert"), so the named state is part
            # of the LiveView's own diff — the flash lives in the layout and
            # a patch does not re-render it.
            {:noreply,
             socket
             |> assign(pending_select: nil, nav_error: message)
             |> put_flash(:error, message)}
        end
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

  # BOTH create affordances decide on the SAME principal the scope menu itself
  # is built from (`ScopeResolver.principal_from_assigns/1`: a token, else the
  # account session's %User{}, else nil) — not on `:api_token` alone. This is
  # the StudioLive half of the #16012 fix: `StudioChrome.chrome_fallback/3`
  # only runs on NON-StudioLive views, so on the MAIN Studio surface these
  # handlers still told a signed-in account session "Sign in to create a
  # workspace". The message was false and the affordance dead.
  #
  # The authority is REUSED, never invented: `create_workspace_with_owner/2`
  # already has a `%User{}` head that writes a `principal_type: "user"` owner
  # membership. Only a `nil` principal — a genuinely anonymous / public-demo
  # session — still gets "Sign in", and for that one it is TRUE.
  #
  # The MEMBERSHIP half is NOT re-asked here, unlike the chrome copy. On
  # StudioLive `Caps.gate/3` already classifies `create-workspace` and
  # `create-project` as `:write` and halts a principal-carrying socket that
  # lacks write with "You don't have access to do that." — an honest sentence
  # that never claims the person is signed out. A `Tenancy.Auth.member?/2` arm
  # underneath it would be unreachable code (proved: the signed-in non-member
  # test below never reaches this module). `chrome_fallback/3` needs its own
  # copy only because those surfaces run without the gate.
  def create_workspace(%{"name" => name}, socket) do
    case principal(socket) do
      nil ->
        {:noreply, put_flash(socket, :error, "Sign in to create a workspace")}

      principal ->
        case Tenancy.create_workspace_with_owner(%{name: name}, principal) do
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
    end
  end

  def create_workspace(_params, socket), do: {:noreply, socket}

  def create_project(%{"name" => name}, socket) do
    ws = socket.assigns[:current_workspace]

    cond do
      is_nil(principal(socket)) ->
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

  # Who is asking, by the ONE precedence rule the flat->scoped funnel and the
  # scope menu already share. Never re-encoded here (two copies of "token wins
  # over user" drift, and a create gate that disagrees with the menu that
  # rendered it is #34 all over again).
  defp principal(socket), do: ScopeResolver.principal_from_assigns(socket.assigns)

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
