defmodule BarkparkWeb.Studio.SearchLive do
  @moduledoc """
  Studio Search page: what people searched for in one dataset, and the
  synonym rules that help them find it. Workspace admins only.

  The page shows two surfaces, Documents and Media, as tabs. Both read the
  same functions with the same shapes: `Search.Intelligence.insights/3` and
  `Search.Synonyms`. The numbers come from finished periods (yesterday, last
  week, last month), because that is what the nightly roll-up writes.

  ## Scope and access

  The workspace, project and dataset are the ones in the URL. `LiveScope`
  resolves and authorizes them for the `:scoped_studio` session, re-checks
  them on every patch that changes one, and holds a dataset-bound token to
  its dataset. This page never falls back to a default workspace or dataset:
  every read and write passes the URL workspace's id, and without one the
  page refuses.

  Admin is the workspace seat (`Studio.Caps.admin?/1`), the same answer the
  navigation uses. It is asked at mount, on every URL change, and again on
  every event, so a demoted admin loses the page on the next click. A
  refusal is the one the other admin pages give: "Admin access required" and
  a redirect to the Studio.

  Synonym writes mirror `SearchController`: the same `Synonyms` calls, the
  URL workspace's id, and no write while the instance is held
  (`WriteAdmissionLive`, the socket half of `RefuseWhileHeld`).
  """

  use BarkparkWeb, :live_view

  require Logger

  import BarkparkWeb.Studio.PageScroll

  alias Barkpark.Search.{Intelligence, Synonyms}
  alias BarkparkWeb.Studio.Caps
  alias BarkparkWeb.Studio.Desk.Text
  alias BarkparkWeb.Studio.SearchLive.View

  on_mount {BarkparkWeb.WriteAdmissionLive, :refuse_while_held}

  @surfaces ~w(documents media)
  @periods ~w(day week month)
  @kinds ~w(one_way alt_correction)
  @blank_rule %{"from" => "", "to" => "", "kind" => "one_way"}

  @impl true
  def mount(%{"dataset" => dataset}, _session, socket) do
    # A dataset segment the database refuses as text names no dataset: a 404
    # before the first read, as on the Media page.
    Text.text?(dataset) || raise BarkparkWeb.Studio.DeskLive.NotFound

    if admin?(socket) do
      {:ok,
       socket
       |> assign_new(:scope_prefix, fn -> "" end)
       |> assign(
         dataset: dataset,
         page_title: gettext("Search"),
         surface: "documents",
         period: "week",
         insights: nil,
         synonyms: [],
         shared: MapSet.new(),
         confirm_delete: nil,
         rule: @blank_rule,
         preview: nil,
         rule_error: nil
       )}
    else
      {:ok, refuse(socket)}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    dataset = params["dataset"]

    cond do
      not admin?(socket) ->
        {:noreply, refuse(socket)}

      not (is_binary(dataset) and Text.text?(dataset)) ->
        {:noreply, refuse(socket)}

      true ->
        {:noreply,
         socket
         |> assign(
           dataset: dataset,
           surface: pick(params["surface"], @surfaces, "documents"),
           period: pick(params["period"], @periods, "week"),
           preview: nil,
           rule_error: nil,
           confirm_delete: nil
         )
         |> load()}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.studio_page_scroll>
      <View.page
        scope_prefix={@scope_prefix}
        dataset={@dataset}
        surface={@surface}
        period={@period}
        insights={@insights}
        synonyms={@synonyms}
        rule={@rule}
        preview={@preview}
        rule_error={@rule_error}
        shared={@shared}
        confirm_delete={@confirm_delete}
      />
    </.studio_page_scroll>
    """
  end

  # Every event asks for admin again. A phx event can come from a socket
  # whose seat changed after mount, or from markup that was never rendered.
  @impl true
  def handle_event(event, params, socket)
      when event in ~w(rule_change rule_preview rule_save rule_prefill rule_promote
                       rule_delete_ask rule_delete_cancel rule_delete) do
    if admin?(socket),
      do: {:noreply, event(event, params, socket)},
      else: {:noreply, refuse(socket)}
  end

  # Fall-through: a stale or forged phx event must not crash the session.
  def handle_event(event, _params, socket) do
    Logger.warning("studio/search: unhandled event #{inspect(event)}")
    {:noreply, socket}
  end

  # Fall-through: an unexpected message must not crash the LiveView.
  @impl true
  def handle_info(msg, socket) do
    Logger.debug("studio/search: unhandled info #{inspect(msg)}")
    {:noreply, socket}
  end

  defp event("rule_change", params, socket),
    do: assign(socket, rule: shown(rule_from(params)), preview: nil, rule_error: nil)

  defp event("rule_prefill", %{"from" => from}, socket) when is_binary(from) do
    if Text.text?(from),
      do: assign(socket, rule: %{@blank_rule | "from" => from}, preview: nil, rule_error: nil),
      else: socket
  end

  defp event("rule_preview", _params, socket) do
    %{surface: surface, dataset: dataset, rule: rule} = socket.assigns

    case rule_problem(rule) do
      nil ->
        preview = Synonyms.preview(surface, dataset, rule["from"], rule, workspace_id(socket))
        assign(socket, preview: preview, rule_error: nil)

      problem ->
        assign(socket, preview: nil, rule_error: problem)
    end
  end

  defp event("rule_save", params, socket) do
    rule = if is_map(params["rule"]), do: rule_from(params), else: socket.assigns.rule
    %{surface: surface, dataset: dataset} = socket.assigns

    with nil <- rule_problem(rule),
         {:ok, _row} <- Synonyms.create(surface, dataset, rule, workspace_id(socket)) do
      socket
      |> assign(rule: @blank_rule, preview: nil, rule_error: nil)
      |> put_flash(:info, gettext("Synonym saved."))
      |> load()
    else
      {:error, _changeset} ->
        assign(socket,
          rule: rule,
          rule_error: gettext("Could not save the synonym. It may already exist.")
        )

      problem ->
        assign(socket, rule: shown(rule), rule_error: problem)
    end
  end

  defp event("rule_promote", %{"from" => from, "to" => to}, socket)
       when is_binary(from) and is_binary(to) do
    %{surface: surface, dataset: dataset} = socket.assigns
    rule = %{"from" => from, "to" => to}

    with nil <- rule_problem(rule),
         {:ok, _row} <- Synonyms.promote(surface, dataset, rule, workspace_id(socket)) do
      socket |> put_flash(:info, gettext("Synonym saved.")) |> load()
    else
      _ -> put_flash(socket, :error, gettext("Could not save the synonym. It may already exist."))
    end
  end

  # Delete takes two clicks: the first asks, the second deletes. The second is
  # held to the row the first one named, so a lone `rule_delete` deletes nothing.
  defp event("rule_delete_ask", %{"id" => id}, socket) when is_binary(id),
    do: assign(socket, confirm_delete: id)

  defp event("rule_delete_cancel", _params, socket), do: assign(socket, confirm_delete: nil)

  defp event("rule_delete", %{"id" => id}, %{assigns: %{confirm_delete: id}} = socket)
       when is_binary(id) do
    %{surface: surface, dataset: dataset} = socket.assigns
    socket = assign(socket, confirm_delete: nil)

    case Synonyms.delete(id, surface, dataset, workspace_id(socket)) do
      :ok ->
        socket |> put_flash(:info, gettext("Synonym deleted.")) |> load()

      {:error, :not_found} ->
        socket |> put_flash(:error, gettext("That synonym is already gone.")) |> load()
    end
  end

  # A known event with params of another shape: nothing to do.
  defp event(_event, _params, socket), do: socket

  defp load(socket) do
    %{surface: surface, dataset: dataset, period: period} = socket.assigns
    ws_id = workspace_id(socket)

    assign(socket,
      insights: Intelligence.insights(surface, dataset, period: period, workspace_id: ws_id),
      synonyms: Synonyms.list(surface, dataset, ws_id),
      # The rows with no workspace: every workspace on this dataset name reads
      # them. A nil workspace lists that shared layer alone.
      shared: MapSet.new(Synonyms.list(surface, dataset, nil), & &1.id)
    )
  end

  # What stops a rule being saved or previewed, in words; nil when nothing does.
  defp rule_problem(rule) do
    cond do
      blank?(rule["from"]) or blank?(rule["to"]) ->
        gettext("Fill in both words first.")

      not (Text.text?(rule["from"]) and Text.text?(rule["to"])) ->
        gettext("A synonym cannot hold that character. Remove it and try again.")

      true ->
        nil
    end
  end

  # The workspace seat, asked live, and only for a workspace the URL resolved.
  # No workspace id means no page: `Synonyms` and `Intelligence` read a nil
  # workspace as the shared legacy rows, which are not this admin's to manage.
  defp admin?(socket), do: is_binary(workspace_id(socket)) and Caps.admin?(socket)

  defp workspace_id(socket) do
    case socket.assigns[:current_workspace] do
      %{id: id} when is_binary(id) -> id
      _ -> nil
    end
  end

  # The refusal `LiveAuth`'s `:scoped_admin` gate gives on the Settings page.
  defp refuse(socket) do
    socket
    |> put_flash(:error, gettext("Admin access required"))
    |> redirect(to: "/studio")
  end

  defp rule_from(%{"rule" => %{} = rule}) do
    %{
      "from" => text(rule["from"]),
      "to" => text(rule["to"]),
      "kind" => pick(rule["kind"], @kinds, "one_way")
    }
  end

  defp rule_from(_params), do: @blank_rule

  # The rule as the form may show it: a value that is not text (a NUL, bytes
  # that are not UTF-8) cannot be sent to the page, so its field goes blank.
  defp shown(rule) do
    Map.new(rule, fn {key, value} -> {key, if(Text.text?(value), do: value, else: "")} end)
  end

  defp text(value) when is_binary(value), do: value
  defp text(_value), do: ""

  defp blank?(value), do: String.trim(value) == ""

  defp pick(value, allowed, default), do: if(value in allowed, do: value, else: default)
end
