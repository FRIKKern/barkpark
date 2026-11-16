defmodule BarkparkWeb.Studio.WebhooksLive do
  @moduledoc """
  Studio Webhooks page: the webhooks of one dataset, for workspace admins.

  An admin sees each hook's address, events, type filter, whether it is on
  (and why not, when the system turned it off after failures) and its last
  delivery. They can add, edit, turn off and on, delete, rotate the signing
  secret, send a test, open a hook's deliveries and replay one.

  ## Scope and access

  The workspace, project and dataset are the ones in the URL; `LiveScope`
  resolves and authorizes them for the `:scoped_studio` session. Every read
  and write goes through the same calls and the same scope as the HTTP API
  (`WebhookController`): `ScopeHelpers.scope_opts/1` into `Barkpark.Webhooks`,
  and `Barkpark.Webhooks.Console` for the lookup, replay and test. So the page
  shows this project's hooks plus the workspace-wide hooks that have no
  project, and nothing of another workspace or project. Without a resolved
  workspace and project the page refuses rather than read unscoped.

  Admin is the workspace seat (`Studio.Caps.admin?/1`), asked at mount, on
  every URL change and on every event, as on the Search page.

  ## The signing secret

  A secret is shown once: right after a create or a rotate. It is never in a
  `%Webhook{}` held by the socket (rows are plain maps without it), never in a
  flash, a log line or an audit row. The reveal puts it in the assigns for one
  render only: the same event sends this process `:forget_secret`, which runs
  after that render and drops it. The reveal box is `phx-update="ignore"`, so
  the browser keeps showing what it got while the server holds nothing.
  """

  use BarkparkWeb, :live_view

  require Logger

  import BarkparkWeb.Studio.PageScroll

  alias Barkpark.Webhooks
  alias Barkpark.Webhooks.{Console, Dispatcher}
  alias BarkparkWeb.ScopeHelpers
  alias BarkparkWeb.Studio.Caps
  alias BarkparkWeb.Studio.Desk.Text
  alias BarkparkWeb.Studio.WebhooksLive.View

  on_mount {BarkparkWeb.WriteAdmissionLive, :refuse_while_held}

  @events ~w(create update publish unpublish delete discardDraft)
  @blank_form %{"name" => "", "url" => "", "events" => [], "types" => ""}
  @delivery_page 25

  @impl true
  def mount(%{"dataset" => dataset}, _session, socket) do
    # A dataset segment the database refuses as text names no dataset: a 404
    # before the first read, as on the Search and Media pages.
    Text.text?(dataset) || raise BarkparkWeb.Studio.DeskLive.NotFound

    if admin?(socket) do
      {:ok,
       socket
       |> assign_new(:scope_prefix, fn -> "" end)
       |> assign(dataset: dataset, page_title: gettext("Webhooks"))
       |> reset()}
    else
      {:ok, refuse(socket)}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    dataset = params["dataset"]

    cond do
      not admin?(socket) -> {:noreply, refuse(socket)}
      not (is_binary(dataset) and Text.text?(dataset)) -> {:noreply, refuse(socket)}
      true -> {:noreply, socket |> assign(dataset: dataset) |> reset() |> load()}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.studio_page_scroll>
      <View.page
        dataset={@dataset}
        events={events()}
        hooks={@hooks}
        form={@form}
        form_error={@form_error}
        confirm={@confirm}
        reveal={@reveal}
        tests={@tests}
        open={@open}
        deliveries={@deliveries}
      />
    </.studio_page_scroll>
    """
  end

  # Every event asks for admin again: a phx event can come from a socket whose
  # seat changed after mount, or from markup that was never rendered.
  @impl true
  def handle_event(event, params, socket)
      when event in ~w(new edit form_cancel form_change save toggle reenable ask ask_cancel
                       delete rotate test deliveries deliveries_close replay secret_done) do
    if admin?(socket),
      do: {:noreply, event(event, params, socket)},
      else: {:noreply, refuse(socket)}
  end

  # Fall-through: a stale or forged phx event must not crash the session.
  def handle_event(event, _params, socket) do
    Logger.warning("studio/webhooks: unhandled event #{inspect(event)}")
    {:noreply, socket}
  end

  # The reveal render has gone out; drop the secret from the assigns. The key
  # check keeps a late message from blanking a newer reveal.
  @impl true
  def handle_info({:forget_secret, key}, %{assigns: %{reveal: %{key: key} = r}} = socket),
    do: {:noreply, assign(socket, reveal: %{r | secret: nil})}

  def handle_info({:forget_secret, _key}, socket), do: {:noreply, socket}

  # Fall-through: an unexpected message must not crash the LiveView.
  def handle_info(msg, socket) do
    Logger.debug("studio/webhooks: unhandled info #{inspect(msg)}")
    {:noreply, socket}
  end

  defp event("secret_done", _params, socket), do: assign(socket, reveal: nil)

  defp event("new", _params, socket),
    do: assign(socket, form: %{mode: :new, values: @blank_form}, form_error: nil, confirm: nil)

  defp event("edit", %{"id" => id}, socket) do
    with_hook(socket, id, fn wh ->
      values = %{
        "name" => wh.name,
        "url" => wh.url,
        "events" => wh.events,
        "types" => Enum.join(wh.types, ", ")
      }

      assign(socket, form: %{mode: {:edit, wh.id}, values: values}, form_error: nil, confirm: nil)
    end)
  end

  defp event("form_cancel", _params, socket), do: assign(socket, form: nil, form_error: nil)

  defp event("form_change", params, %{assigns: %{form: %{} = form}} = socket),
    do: assign(socket, form: %{form | values: values_from(params)})

  defp event("save", params, %{assigns: %{form: %{mode: mode}}} = socket) do
    values = values_from(params)
    attrs = attrs_from(values)

    case save(mode, attrs, socket) do
      {:ok, :created, wh, secret} ->
        socket
        |> assign(form: nil, form_error: nil)
        |> reveal(wh, :created, secret)
        |> put_flash(:info, gettext("Webhook added."))
        |> load()

      {:ok, :updated} ->
        socket
        |> assign(form: nil, form_error: nil)
        |> put_flash(:info, gettext("Webhook saved."))
        |> load()

      {:error, problem} ->
        assign(socket, form: %{mode: mode, values: values}, form_error: problem)
    end
  end

  defp event("toggle", %{"id" => id}, socket) do
    with_hook(socket, id, fn wh ->
      case Webhooks.update_webhook(wh, %{"active" => not wh.active}) do
        {:ok, %{active: true}} ->
          socket |> put_flash(:info, gettext("Webhook turned on.")) |> load()

        {:ok, _off} ->
          socket |> put_flash(:info, gettext("Webhook turned off.")) |> load()

        {:error, _} ->
          put_flash(socket, :error, gettext("Could not change the webhook."))
      end
    end)
  end

  defp event("reenable", %{"id" => id}, socket) do
    with_hook(socket, id, fn wh ->
      case Webhooks.reenable_webhook(wh) do
        {:ok, _} -> socket |> put_flash(:info, gettext("Webhook turned on.")) |> load()
        {:error, _} -> put_flash(socket, :error, gettext("Could not change the webhook."))
      end
    end)
  end

  # Delete and rotate take two clicks: the first asks, the second acts. The
  # second is held to the hook the first one named, so a lone `delete` or
  # `rotate` event does nothing.
  defp event("ask", %{"action" => action, "id" => id}, socket)
       when action in ~w(delete rotate) and is_binary(id),
       do: assign(socket, confirm: {action, id})

  defp event("ask_cancel", _params, socket), do: assign(socket, confirm: nil)

  defp event("delete", %{"id" => id}, %{assigns: %{confirm: {"delete", id}}} = socket) do
    socket = assign(socket, confirm: nil)

    with_hook(socket, id, fn wh ->
      case Webhooks.delete_webhook(wh) do
        {:ok, _} ->
          socket
          |> assign(open: if(socket.assigns.open == id, do: nil, else: socket.assigns.open))
          |> put_flash(:info, gettext("Webhook deleted."))
          |> load()

        {:error, _} ->
          socket |> put_flash(:error, gettext("That webhook is already gone.")) |> load()
      end
    end)
  end

  defp event("rotate", %{"id" => id}, %{assigns: %{confirm: {"rotate", id}}} = socket) do
    socket = assign(socket, confirm: nil)

    with_hook(socket, id, fn wh ->
      secret = Console.generate_secret()

      case Webhooks.rotate_secret(wh, secret) do
        {:ok, rotated} -> socket |> reveal(rotated, :rotated, secret) |> load()
        {:error, _} -> put_flash(socket, :error, gettext("Could not change the webhook."))
      end
    end)
  end

  defp event("test", %{"id" => id}, socket) do
    with_hook(socket, id, fn wh ->
      {:ok, delivery} = Console.send_test(wh)
      assign(socket, tests: Map.put(socket.assigns.tests, wh.id, View.delivery_row(delivery)))
    end)
  end

  defp event("deliveries", %{"id" => id}, socket),
    do:
      with_hook(socket, id, fn wh ->
        socket |> assign(open: wh.id) |> load_deliveries() |> load()
      end)

  defp event("deliveries_close", _params, socket), do: assign(socket, open: nil, deliveries: [])

  defp event("replay", %{"id" => id, "event_id" => event_id}, socket) do
    with_hook(socket, id, fn wh ->
      case Console.replay(wh, event_id) do
        {:ok, delivery} ->
          socket
          |> put_flash(:info, replayed(delivery))
          |> assign(open: wh.id)
          |> load_deliveries()
          |> load()

        {:error, _} ->
          put_flash(socket, :error, gettext("That event can no longer be sent again."))
      end
    end)
  end

  # A known event with params of another shape: nothing to do.
  defp event(_event, _params, socket), do: socket

  defp save(:new, attrs, socket) do
    {attrs, secret} = Console.ensure_secret(Map.put(attrs, "dataset", socket.assigns.dataset))

    case Webhooks.create_webhook(attrs, scope_opts(socket)) do
      {:ok, wh} -> {:ok, :created, wh, secret}
      {:error, changeset} -> {:error, problem(changeset)}
    end
  end

  defp save({:edit, id}, attrs, socket) do
    with {:ok, wh} <- Console.fetch_scoped(id, socket.assigns.dataset, scope_opts(socket)),
         {:ok, _} <- Webhooks.update_webhook(wh, attrs) do
      {:ok, :updated}
    else
      :error -> {:error, gettext("That webhook is already gone.")}
      {:error, changeset} -> {:error, problem(changeset)}
    end
  end

  # The secret goes into the assigns for the next render only; see moduledoc.
  defp reveal(socket, wh, kind, secret) do
    key = System.unique_integer([:positive])
    send(self(), {:forget_secret, key})
    assign(socket, reveal: %{key: key, id: wh.id, name: wh.name, kind: kind, secret: secret})
  end

  # Load a hook through the same scoped lookup the HTTP API uses; an id outside
  # this workspace, project or dataset is treated like an unknown one.
  defp with_hook(socket, id, fun) do
    case Console.fetch_scoped(id, socket.assigns.dataset, scope_opts(socket)) do
      {:ok, wh} -> fun.(wh)
      :error -> socket |> put_flash(:error, gettext("That webhook is already gone.")) |> load()
    end
  end

  defp reset(socket) do
    assign(socket,
      hooks: [],
      form: nil,
      form_error: nil,
      confirm: nil,
      reveal: nil,
      tests: %{},
      open: nil,
      deliveries: []
    )
  end

  defp load(socket) do
    hooks =
      socket.assigns.dataset
      |> Webhooks.list_webhooks(scope_opts(socket))
      |> Enum.map(fn wh ->
        last = wh.id |> Webhooks.list_deliveries(limit: 1) |> List.first()

        View.hook_row(
          wh,
          last && View.delivery_row(last),
          not Dispatcher.blank_secret?(wh.secret)
        )
      end)

    open = if Enum.any?(hooks, &(&1.id == socket.assigns.open)), do: socket.assigns.open
    assign(socket, hooks: hooks, open: open)
  end

  defp load_deliveries(%{assigns: %{open: id}} = socket) when is_binary(id) do
    rows = id |> Webhooks.list_deliveries(limit: @delivery_page) |> Enum.map(&View.delivery_row/1)
    assign(socket, deliveries: rows)
  end

  defp load_deliveries(socket), do: assign(socket, deliveries: [])

  defp replayed(%{status: "ok", last_status_code: code}),
    do: gettext("Sent again. The receiver answered %{code}.", code: code)

  defp replayed(_delivery), do: gettext("Sent again, but the receiver did not accept it.")

  # What stops a hook being saved, in words.
  defp problem(%Ecto.Changeset{errors: errors}) do
    cond do
      Keyword.has_key?(errors, :name) ->
        gettext("Give the webhook a name.")

      Keyword.has_key?(errors, :url) ->
        gettext("Enter an address that starts with http:// or https://.")

      true ->
        gettext("Could not save the webhook. Check the fields and try again.")
    end
  end

  defp values_from(%{"webhook" => %{} = w}) do
    %{
      "name" => text(w["name"]),
      "url" => text(w["url"]),
      "events" => w |> Map.get("events", []) |> List.wrap() |> Enum.filter(&(&1 in @events)),
      "types" => text(w["types"])
    }
  end

  defp values_from(_params), do: @blank_form

  # Only these four keys reach the changeset: the page never sets scope,
  # secret, audit or chat subscriptions.
  defp attrs_from(values) do
    %{
      "name" => String.trim(values["name"]),
      "url" => String.trim(values["url"]),
      "events" => values["events"],
      "types" =>
        values["types"]
        |> String.split([",", " "], trim: true)
        |> Enum.uniq()
    }
  end

  defp text(value) when is_binary(value), do: if(Text.text?(value), do: value, else: "")
  defp text(_value), do: ""

  defp events, do: @events

  defp scope_opts(socket), do: ScopeHelpers.scope_opts(socket)

  # The workspace seat, asked live, and only for a workspace and project the
  # URL resolved. Without both, `Webhooks` would read unscoped (every tenant's
  # hooks), so the page refuses instead.
  defp admin?(socket) do
    is_binary(id_of(socket.assigns[:current_workspace])) and
      is_binary(id_of(socket.assigns[:current_project])) and Caps.admin?(socket)
  end

  defp id_of(%{id: id}), do: id
  defp id_of(_), do: nil

  # The refusal the other admin pages give.
  defp refuse(socket) do
    socket
    |> put_flash(:error, gettext("Admin access required"))
    |> redirect(to: "/studio")
  end
end
