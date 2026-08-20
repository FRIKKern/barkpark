defmodule BarkparkWeb.ChatHostController do
  use BarkparkWeb, :controller

  alias Barkpark.ChatHosts
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  def index(conn, _params) do
    json(conn, %{hosts: ChatHosts.list_hosts(conn.assigns.current_workspace.id)})
  end

  def create_enrollment(conn, params) do
    workspace_id = conn.assigns.current_workspace.id

    if TenancyAuth.membership_role(conn.assigns.api_token, workspace_id) == "owner" do
      case ChatHosts.issue_enrollment(workspace_id, params) do
        {:ok, result} -> conn |> put_status(:created) |> json(result)
        {:error, changeset} -> unprocessable(conn, changeset)
      end
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: %{code: "forbidden", message: "workspace owner required"}})
    end
  end

  def enroll(conn, %{"enrollment_token" => token} = params) do
    case ChatHosts.enroll(token, params) do
      {:ok, result} -> conn |> put_status(:created) |> json(result)
      {:error, _reason} -> unauthorized_enrollment(conn)
    end
  end

  def enroll(conn, _params), do: unauthorized_enrollment(conn)

  def revoke(conn, %{"id" => id}) do
    case ChatHosts.revoke(conn.assigns.current_workspace.id, id) do
      {:ok, host} -> json(conn, %{host: host})
      {:error, :not_found} -> not_found(conn)
      {:error, reason} -> unprocessable(conn, reason)
    end
  end

  def heartbeat(conn, params) do
    case ChatHosts.heartbeat(conn.assigns.chat_host, params) do
      {:ok, host} -> json(conn, %{host: host})
      {:error, changeset} -> unprocessable(conn, changeset)
    end
  end

  def rotate(conn, _params) do
    case ChatHosts.rotate_credential(conn.assigns.chat_host) do
      {:ok, result} -> json(conn, result)
      {:error, changeset} -> unprocessable(conn, changeset)
    end
  end

  def commands(conn, _params) do
    json(conn, %{commands: ChatHosts.next_commands(conn.assigns.chat_host)})
  end

  def event(conn, params) do
    case ChatHosts.accept_event(conn.assigns.chat_host, params) do
      {:ok, :accepted} -> conn |> put_status(:accepted) |> json(%{accepted: true})
      {:ok, :duplicate} -> json(conn, %{accepted: false, duplicate: true})
      {:error, reason} when reason in [:stale_fence, :lease_expired] -> conflict(conn, reason)
      {:error, reason} -> unprocessable(conn, reason)
    end
  end

  # POST /v1/chat/sessions/:id/state (herd-s6, charter D78h–D80h): the fenced
  # reporter's authoritative herd-state write. Vocabulary is the persisted
  # four-state — anything else is 422 BEFORE the store is touched. `epoch` must
  # be the integer the host received with its lease (`lease_and_enqueue` /
  # `GET /v1/chat-host/commands`); it is compared by the fence but VESTIGIAL —
  # nothing ever bumps it (today it is always the insert default 1). The fence
  # deny grammar mirrors /v1/chat-host/events: stale_fence / lease_expired →
  # 409, lease_not_found → 422, a vanished session → 404.
  @agent_states ~w(working blocked idle unknown)

  def report_state(conn, %{"id" => session_id, "state" => agent_state, "epoch" => epoch})
      when agent_state in @agent_states and is_integer(epoch) do
    case ChatHosts.report_state(conn.assigns.chat_host, session_id, agent_state, epoch) do
      {:ok, result} -> json(conn, result)
      {:error, reason} when reason in [:stale_fence, :lease_expired] -> conflict(conn, reason)
      {:error, :session_not_found} -> session_not_found(conn)
      {:error, reason} -> unprocessable(conn, reason)
    end
  end

  def report_state(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        code: "invalid_state_report",
        message:
          "state must be one of working|blocked|idle|unknown and epoch must be the lease's integer epoch"
      }
    })
  end

  defp session_not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{code: "not_found", message: "session not found"}})
  end

  defp unauthorized_enrollment(conn) do
    conn
    |> put_status(:unauthorized)
    |> json(%{
      error: %{code: "invalid_enrollment", message: "enrollment token is invalid or expired"}
    })
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{code: "not_found", message: "host not found"}})
  end

  defp conflict(conn, reason) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{code: to_string(reason), message: "host lease fence is no longer current"}
    })
  end

  defp unprocessable(conn, %Ecto.Changeset{} = changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
        Regex.replace(~r"%{(\w+)}", message, fn _, key ->
          opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
        end)
      end)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "unprocessable", fields: errors}})
  end

  defp unprocessable(conn, reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "unprocessable", message: inspect(reason)}})
  end
end
