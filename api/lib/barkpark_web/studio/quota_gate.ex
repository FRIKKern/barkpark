defmodule BarkparkWeb.Studio.QuotaGate do
  @moduledoc """
  Workspace suspension and the document quota for LiveView writes
  (task-72437f78ef0d3184; design: `/papers/studio-liveview-quota-gate`).

  Over HTTP, `BarkparkWeb.Plugs.RequireWithinQuota` refuses a suspended
  workspace's writes (403) and a full workspace's creates (402). Studio writes
  run inside LiveView callbacks and pass no plug, so this module asks the same
  `Quota.check/2` from a `:handle_event` hook, and from the few write paths a
  hook cannot see (a `handle_info` op, a LiveComponent's own events).

    * Which events: `Caps.classify/1`'s `:write` and `:publish` tiers, read
      here, never copied. `:admin` events and the writes that touch no
      workspace document (`@exempt`) pass.
    * Room: 1 for an event that adds a document (`@creates`), 0 for any other
      write, the rule `/v1/data/mutate` applies to `delete` and `patch`. So a
      full workspace still edits, publishes and deletes; it cannot add.
    * The workspace is re-read by id on every gated write: the struct in
      assigns is set at mount, and `Quota.suspend/2` tells no socket.
    * Hooks run in attach order, so attached after `Caps.attach/1`, an event
      Caps refuses never reaches this gate.

  Caps, `LiveWriteGate`, tenancy and `Quota` are unchanged.
  """

  import Phoenix.LiveView, only: [attach_hook: 4, put_flash: 3, push_event: 3]

  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Quota
  alias BarkparkWeb.Studio.Caps

  # Events that add a document row.
  @creates ~w(new-document duplicate-doc upload-image)

  # Studio writes that touch no workspace document: tenancy rows, the user's
  # own profile, and taking access away.
  @exempt ~w(create-workspace create-project save-profile access-revoke)

  # Paper edit events (BulldocsLive) that only read.
  @paper_reads ~w(paper-toggle-edit task-preview-refresh paper-wikilink-search
                  paper-tag-search paper-valueref-inspect)

  @suspended "This workspace is suspended, so it cannot be changed."
  @full "This workspace has reached its document quota. Delete documents or ask an admin to raise it."

  @doc "Attach the gate to a Studio socket, after `Caps.attach/1`."
  def attach(socket) do
    if socket.assigns[:quota_gate?] do
      socket
    else
      socket
      |> Phoenix.Component.assign(:quota_gate?, true)
      |> attach_hook(:studio_quota_gate, :handle_event, &studio_event/3)
      |> attach_hook(:studio_quota_info, :handle_info, &info/2)
    end
  end

  @doc """
  Attach the gate to the paper reader (`BulldocsLive`), whose edits belong to
  the paper's workspace, after `Edit.attach_gate/1`.
  """
  def attach_paper(socket, edit_events) do
    events = edit_events -- @paper_reads

    socket
    |> attach_hook(:paper_quota_gate, :handle_event, fn event, _params, socket ->
      if event in events, do: gate(socket, 0), else: {:cont, socket}
    end)
    |> attach_hook(:paper_quota_info, :handle_info, &info/2)
  end

  @doc """
  `:ok`, or `{:error, message}` when the workspace may not take this write:
  suspended, or (with `needed` > 0) without room. A nil workspace (an
  anonymous demo socket) passes, as the plug does.
  """
  @spec check(String.t() | nil, non_neg_integer()) :: :ok | {:error, String.t()}
  def check(nil, _needed), do: :ok

  def check(workspace_id, needed) do
    case Tenancy.get_workspace_by_id(workspace_id) do
      nil ->
        :ok

      ws ->
        case Quota.check(ws, needed) do
          :ok -> :ok
          {:error, :suspended} -> {:error, @suspended}
          {:error, :quota_exceeded} -> {:error, @full}
        end
    end
  end

  defp studio_event(event, _params, socket) do
    cond do
      event in @exempt -> {:cont, socket}
      Caps.classify(event) in [:write, :publish] -> gate(socket, needed(event))
      true -> {:cont, socket}
    end
  end

  defp needed(event) when event in @creates, do: 1
  defp needed(_event), do: 0

  # The op and autosave messages a LiveComponent sends its host write too, and
  # never pass a `:handle_event` hook.
  defp info({:paper_op, %{"op" => _}, request_id} = _msg, socket) when is_binary(request_id) do
    case check(workspace_id(socket), 0) do
      :ok ->
        {:cont, socket}

      {:error, message} ->
        socket =
          socket
          |> put_flash(:error, message)
          |> push_event("bp:paper-field-save-result", %{saved: false, request_id: request_id})

        {:halt, socket}
    end
  end

  defp info({:paper_op, %{"op" => _}}, socket), do: gate(socket, 0)
  defp info({:autosave_form, _form}, socket), do: gate(socket, 0)
  defp info(_msg, socket), do: {:cont, socket}

  defp gate(socket, needed) do
    case check(workspace_id(socket), needed) do
      :ok -> {:cont, socket}
      {:error, message} -> {:halt, put_flash(socket, :error, message)}
    end
  end

  # The paper reader edits the paper's workspace; Studio its mounted one.
  defp workspace_id(socket) do
    case socket.assigns do
      %{quota_workspace_id: id} -> id
      %{current_workspace: %{id: id}} -> id
      _ -> nil
    end
  end
end
