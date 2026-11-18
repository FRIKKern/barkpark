defmodule BarkparkWeb.Studio.Desk.HelpMenu do
  @moduledoc """
  The desk navbar's "Help and resources", as the TanStack Studio's
  (`Navbar.tsx` `Help`, Sanity's, top right): Report a problem, the Studio's
  version, Documentation, Changelog and What's new.

  The version item names the build this page loaded (`BuildInfo.commit/0`).
  Up to date, it opens the "Studio version" dialog; when the server runs a
  newer build it reads "Reload to update to …" and reloads, and the button's
  tip says "New version available" beside a dot. `bp-desk-navbar.js` asks
  `GET /api/version` when the page loads, every minute and when the tab
  comes back, and compares; it also opens the two dialogs. So the menu is
  `phx-update="ignore"`: a patch keeps what the script set.

  The script is also named here, for the first page load: the desk's hook
  loads it again only when it is not in the page (a live navigation).
  """
  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  alias Barkpark.BuildInfo
  alias BarkparkWeb.Studio.Desk.Menu

  @repo "https://github.com/FRIKKern/barkpark"

  attr :build, :string, default: nil, doc: "the build this page runs; `BuildInfo.commit/0`"

  @doc "The help button, its menu and the two dialogs it opens."
  def menu(assigns) do
    assigns =
      assigns
      |> assign(:build, assigns.build || BuildInfo.commit())
      |> assign_new(:script, fn -> BarkparkWeb.StaticAssets.path("bp-desk-navbar.js") end)
      |> assign(:repo, @repo)
      |> assign(:built, built())

    ~H"""
    <div
      class="menu-wrap help dk"
      id="dk-help"
      phx-update="ignore"
      data-build={@build}
      data-desk-new-version={gettext("New version available")}
      data-desk-reload={gettext("Reload to update")}
      data-desk-reload-to={gettext("Reload to update to %{version}", version: "%{version}")}
      data-desk-reloading={gettext("Saving, then reloading…")}
    >
      <script :if={@script} src={@script} async data-desk-navbar></script>
      <button
        id="help-menu"
        type="button"
        class="icon-btn"
        popovertarget="dk-help-menu"
        aria-label={gettext("Help and resources")}
        data-tip={gettext("Help and resources")}
        aria-haspopup="menu"
        style="anchor-name: --dk-help-menu"
      >
        <BarkparkWeb.Icons.desk_icon name="help-circle" size={21} />
        <span class="update-dot" aria-hidden="true" hidden></span>
      </button>
      <div
        id="dk-help-menu"
        popover
        role="menu"
        aria-labelledby="help-menu"
        class="dk-menu help-menu"
        style="position-anchor: --dk-help-menu; inset: auto; top: anchor(bottom); right: anchor(right); margin: 4px 0 0"
      >
        <Menu.item href={"#{@repo}/issues/new/choose"} target="_blank" rel="noreferrer" role="menuitem" tabindex="-1" icon="comment">{gettext("Report a problem")}</Menu.item>
        <Menu.separator />
        <button type="button" role="menuitem" tabindex="-1" class="dk-menu-item studio-version" data-desk-version>
          <span class="version-text">
            <span>Barkpark Studio</span>
            <span class="muted" data-desk-version-state>{gettext("Up to date")}</span>
          </span>
          <span class="version-badge">{short(@build)}</span>
        </button>
        <Menu.separator />
        <Menu.item href={"#{@repo}#readme"} target="_blank" rel="noreferrer" role="menuitem" tabindex="-1">{gettext("Documentation")}</Menu.item>
        <Menu.item href={"#{@repo}/blob/main/CHANGELOG.md"} target="_blank" rel="noreferrer" role="menuitem" tabindex="-1">{gettext("Changelog")}</Menu.item>
        <button type="button" role="menuitem" tabindex="-1" class="dk-menu-item" data-desk-dialog="dk-whats-new">{gettext("What's new")}</button>
      </div>
      <dialog id="dk-version-dialog" class="dk-nav-dialog version-dialog" aria-label={gettext("Studio version")}>
        <div class="dialog-body version-body">
          <span class="logo version-logo" aria-hidden="true">B</span>
          <p class="version-name">
            <strong>Barkpark Studio</strong>
            <a
              :if={sha?(@build)}
              class="version-badge"
              href={"#{@repo}/commit/#{@build}"}
              target="_blank"
              rel="noreferrer"
              aria-label={gettext("Open commit %{commit} on GitHub", commit: short(@build))}
            >{short(@build)}</a>
            <span :if={!sha?(@build)} class="version-badge">{@build}</span>
          </p>
          <p class="version-state">
            {gettext("Up to date")}<span :if={@built}> · {gettext("Built %{date}", date: @built)}</span>
          </p>
        </div>
        <footer>
          <button type="button" class="dk-publish publish" autofocus data-desk-dialog-close>{gettext("OK")}</button>
        </footer>
      </dialog>
      <dialog id="dk-whats-new" class="dk-nav-dialog whats-new-dialog" aria-label={gettext("What's new")}>
        <header>
          <h2>{gettext("What's new")}</h2>
          <button type="button" class="icon-btn" aria-label={gettext("Close")} data-tip={gettext("Close")} data-desk-dialog-close>
            <BarkparkWeb.Icons.desk_icon name="close" size={21} />
          </button>
        </header>
        <div class="dialog-body">
          <p>{gettext("No changes are listed in this build.")}</p>
        </div>
        <footer class="whats-new-foot">
          <a href={"#{@repo}/blob/main/CHANGELOG.md"} target="_blank" rel="noreferrer">{gettext("Full changelog on GitHub")} →</a>
        </footer>
      </dialog>
    </div>
    """
  end

  defp sha?(build), do: is_binary(build) and Regex.match?(~r/^[0-9a-f]{7,40}$/, build)

  # The commit as the menu shows it: its first seven characters.
  defp short(build) when is_binary(build),
    do: if(sha?(build), do: String.slice(build, 0, 7), else: build)

  defp short(_build), do: ""

  defp built do
    case DateTime.from_iso8601(BuildInfo.built_at()) do
      {:ok, at, _offset} -> Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")
      _ -> nil
    end
  end
end
