defmodule BarkparkWeb.Studio.Desk.ScopeSwitch do
  @moduledoc """
  The desk's workspace, project and dataset switcher, as the TanStack Studio's
  (`ScopeSwitcher.tsx`, Sanity's workspace menu): the workspace's name with a
  chevron is the navbar's brand button, named "Workspace w, project p, dataset
  d. Switch". It opens a card with one row a place, where you are first and
  checked; one click goes there.

  The card is a popover, as the desk's other menus (`Desk.Menu`): the
  browser opens and closes it at once, on the button, a click outside and
  Escape, and a patch keeps it open. Opening it also asks the server for the
  places (`desk-scope-load`), once a page; until they come the card shows
  its head only. A pick closes it (`bp-desk-navbar.js`).

  The places are the workspaces this socket's principal is a member of
  (`Tenancy.list_workspaces_for/1`, the old switcher's list), their projects
  and their datasets, read when the card opens. A dataset-bound token sees
  the others greyed: it opens only its own dataset.

  A pick is checked again on the server (`go/2`): the workspace must be one
  the principal reaches (`Shared.can_reach_workspace?/2`, the old
  switcher's gate), the project in it, the dataset in that, and a bound
  token's own dataset. Then the page opens fresh there (a full load, so
  nothing read here shows there), on the same panes from the left as far as
  the target has them: each list's type in its schema, each document there
  (draft or published). The URL's query goes along only when every pane did.
  """
  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  import Phoenix.LiveView, only: [put_flash: 3, redirect: 2]

  alias Barkpark.Auth.ApiToken
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.ScopeHelpers
  alias BarkparkWeb.Studio.Desk.Panes
  alias BarkparkWeb.Studio.ScopeResolver
  alias BarkparkWeb.Studio.StudioLive.Paths
  alias BarkparkWeb.Studio.StudioLive.Shared

  # Sanity colours each workspace's icon; a steady hue per place.
  @hues [230, 270, 0, 160, 30, 200, 320, 100]

  @doc "The card's events: read its places (once), and go to a place."
  def handle_event("desk-scope-load", _params, socket) do
    if socket.assigns[:desk_scope],
      do: {:noreply, socket},
      else: {:noreply, Phoenix.Component.assign(socket, :desk_scope, places(socket.assigns))}
  end

  def handle_event("desk-scope-go", params, socket), do: {:noreply, go(socket, params)}
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @doc """
  Every place the principal may open, grouped by workspace and project, the
  current group first. Each place says whether it is where the page is and
  whether a bound token may open it.
  """
  @spec places(map()) :: %{groups: [map()], bound: String.t() | nil}
  def places(assigns) do
    here = here(assigns)
    bound = bound(assigns)

    groups =
      for ws <- workspaces(assigns),
          proj <- Tenancy.list_projects(ws.id) do
        rows =
          for ds <- Tenancy.list_datasets(proj.id) do
            key = {ws.slug, proj.slug, ds.slug}

            %{
              ws: ws.slug,
              proj: proj.slug,
              ds: ds.slug,
              title: ds.name || ds.slug,
              initials: initials(ds.name || ds.slug),
              hue: hue(Enum.join(Tuple.to_list(key), "/")),
              current?: key == here,
              off?: is_binary(bound) and ds.slug != bound
            }
          end

        %{
          key: "#{ws.slug}/#{proj.slug}",
          label: "#{ws.name} / #{proj.name}",
          here?: {ws.slug, proj.slug} == Tuple.delete_at(here, 2),
          places: rows
        }
      end

    %{
      groups: groups |> Enum.reject(&(&1.places == [])) |> Enum.sort_by(&(!&1.here?)),
      bound: bound
    }
  end

  # The workspace the page is in is listed too: it was reached to mount here.
  defp workspaces(assigns) do
    member = assigns |> ScopeResolver.principal_from_assigns() |> Tenancy.list_workspaces_for()

    case assigns[:current_workspace] do
      %{id: id} = current ->
        if Enum.any?(member, &(&1.id == id)), do: member, else: [current | member]

      _ ->
        member
    end
  end

  defp here(assigns) do
    {slug(assigns[:current_workspace]), slug(assigns[:current_project]), assigns[:dataset]}
  end

  defp slug(%{slug: slug}), do: slug
  defp slug(_), do: nil

  defp bound(assigns) do
    case assigns[:api_token] do
      %ApiToken{dataset: dataset} = token -> if ApiToken.dataset_bound?(token), do: dataset
      _ -> nil
    end
  end

  @doc "A place's two-letter mark: the initials of its words."
  def initials(name) do
    name
    |> String.split(~r/[\s_-]+/u, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&(&1 |> String.first() |> String.upcase()))
    |> case do
      "" -> "?"
      marks -> marks
    end
  end

  defp hue(key) do
    at = key |> String.to_charlist() |> Enum.reduce(7, &rem(&2 * 31 + &1, 4_294_967_296))
    Enum.at(@hues, rem(at, length(@hues)))
  end

  # A pick, gated again: never trust the card the browser holds.
  defp go(socket, %{"ws" => ws_slug, "proj" => proj_slug, "ds" => ds})
       when is_binary(ws_slug) and is_binary(proj_slug) and is_binary(ds) do
    assigns = socket.assigns

    with %Tenancy.Workspace{} = ws <- Tenancy.get_workspace_by_slug(ws_slug),
         true <- Shared.can_reach_workspace?(socket, ws),
         %Tenancy.Project{} = project <- Tenancy.get_project(ws.slug, proj_slug),
         true <- Enum.any?(Tenancy.list_datasets(project.id), &(&1.slug == ds)),
         true <- bound(assigns) in [nil, ds] do
      if {ws.slug, project.slug, ds} == here(assigns) do
        socket
      else
        redirect(socket, to: switched_path(assigns, ws, project, ds))
      end
    else
      _ -> refuse(socket)
    end
  end

  defp go(socket, _params), do: refuse(socket)

  # One sentence for not found, not reachable and gone stale, as the old
  # switcher's: a guessed slug must not learn that it exists.
  defp refuse(socket) do
    put_flash(
      socket,
      :error,
      gettext("Could not open that place. It does not exist, or you do not have access to it.")
    )
  end

  @doc """
  Where a switch to `ds` in `project` lands: the desk there, on as many of
  the open panes from the left as the target has (a menu pane stops them).
  """
  @spec switched_path(map(), map(), map(), String.t()) :: String.t()
  def switched_path(assigns, ws, project, ds) do
    base = Paths.studio_path("/w/#{ws.slug}/p/#{project.slug}", ["_desk"], ds)
    chain = assigns[:chain] || [%{kind: :types}]

    opts =
      ScopeHelpers.scope_opts_from_assigns(
        Map.merge(assigns, %{current_workspace: ws, current_project: project})
      )

    asked = chain |> Enum.drop(1) |> Enum.take_while(&(&1[:kind] in [:list, :doc]))
    kept = asked |> Enum.take_while(&there?(&1, ds, opts)) |> length()
    path = Panes.to_path(Enum.take(chain, 1 + kept), base)

    if kept == length(chain) - 1, do: path <> uri_query(assigns[:desk_uri]), else: path
  end

  defp there?(%{kind: :list, type: type}, ds, opts) when is_binary(type),
    do: match?({:ok, _}, Content.get_schema(type, ds, opts))

  defp there?(%{kind: :doc, type: type, id: id}, ds, opts)
       when is_binary(type) and is_binary(id) do
    id = String.replace_prefix(id, "drafts.", "")

    Enum.any?([id, "drafts." <> id], &match?({:ok, _}, Content.get_document(&1, type, ds, opts)))
  end

  defp there?(_pane, _ds, _opts), do: false

  defp uri_query(uri) when is_binary(uri) do
    case URI.parse(uri).query do
      q when is_binary(q) and q != "" -> "?" <> q
      _ -> ""
    end
  end

  defp uri_query(_uri), do: ""

  attr :workspace, :map, required: true
  attr :project, :map, default: nil
  attr :dataset, :string, required: true
  attr :menu, :map, default: nil, doc: "`places/1` once the card has asked for them, else nil"

  @doc "The brand button and its card (hidden until the button opens it)."
  def switcher(assigns) do
    assigns = assign(assigns, :name, assigns.workspace.name || assigns.workspace.slug)

    ~H"""
    <div class="menu-wrap scope-switcher dk-scope dk" id="dk-scope">
      <button
        id="dk-scope-button"
        type="button"
        class="scope-button brand-button"
        popovertarget="dk-scope-card"
        aria-haspopup="dialog"
        style="anchor-name: --dk-scope"
        aria-label={
          gettext("Workspace %{workspace}, project %{project}, dataset %{dataset}. Switch",
            workspace: @workspace.slug,
            project: slug(@project),
            dataset: @dataset
          )
        }
        title={"#{@workspace.slug} / #{@dataset}"}
        phx-click="desk-scope-load"
      >
        <span class="brand-name">{@name}</span>
        <BarkparkWeb.Icons.desk_icon name="chevron-down" size={21} />
      </button>
      <div
        id="dk-scope-card"
        popover
        class="popover scope-popover"
        role="dialog"
        aria-label={gettext("Switch workspace, project or dataset")}
        style="position-anchor: --dk-scope; inset: auto; top: anchor(bottom); left: anchor(left); margin: 6px 0 0 -37px"
      >
        <div class="scope-head">
          <div class="scope-card">
            <span class="logo scope-card-logo" aria-hidden="true">{brand_initials(@name)}</span>
            <span class="scope-card-text">
              <span class="scope-card-where">{@workspace.slug} / {@dataset}</span>
              <span class="scope-card-name">{@name}</span>
            </span>
          </div>
        </div>
        <div :if={@menu} class="scope-places">
          <section :for={group <- @menu.groups} aria-label={group.label}>
            <h2 class="scope-places-head">{group.label}</h2>
            <ul class="scope-list">
              <li :for={place <- group.places}>
                <button
                  type="button"
                  class="scope-place"
                  aria-current={place.current? && "true"}
                  disabled={place.off?}
                  phx-click="desk-scope-go"
                  phx-value-ws={place.ws}
                  phx-value-proj={place.proj}
                  phx-value-ds={place.ds}
                >
                  <span class="scope-place-icon" aria-hidden="true" style={"--place-hue: #{place.hue}"}>{place.initials}</span>
                  <span class="scope-place-text">
                    <span class="scope-place-title">{place.title}</span>
                    <span class="scope-place-sub">{place.ws} / {place.ds}</span>
                  </span>
                  <BarkparkWeb.Icons.desk_icon :if={place.current?} name="checkmark" size={21} />
                </button>
              </li>
            </ul>
          </section>
          <p :if={@menu.bound} class="scope-note">
            {gettext("This token can only open the dataset %{dataset}.", dataset: @menu.bound)}
          </p>
        </div>
      </div>
    </div>
    """
  end

  @doc "The navbar logo's letters for a studio name, as the TanStack Studio's (`studioBrand`)."
  def brand_initials(name) when is_binary(name) do
    name
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.reject(&(String.downcase(&1) == "studio"))
    |> Enum.take(2)
    |> Enum.map_join(&(&1 |> String.first() |> String.upcase()))
    |> case do
      "" -> "B"
      marks -> marks
    end
  end

  def brand_initials(_name), do: "B"
end
