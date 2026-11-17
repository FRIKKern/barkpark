defmodule BarkparkWeb.AccessRequestController do
  @moduledoc """
  The ASKER's side of access requests (task-1b99ba8512bb758e): a signed-in
  user with no seat in a workspace asks for one, lists their requests and
  withdraws a pending one. The admin's side is
  `BarkparkWeb.WorkspaceAccessRequestController`.

  Mounted on `[:user_auth, :access_principal]`, the pipeline `bp access claim`
  uses: the caller is a user, from a login session or from a token that user
  owns. An owned token counts because it can only be minted from that user's
  session (`POST /v1/auth/tokens`, org MFA checked at issuance) and carries no
  authority here beyond naming its owner: the request is for the OWNER's seat,
  and an admin decides. A token nobody owns names no person and gets 401.

  ## The answer says nothing about the workspace

  `POST` answers `202 {"access_request": {id, workspace, status, note,
  inserted_at, decided_at}}` whether the slug names a workspace or not, and the
  same row again for a repeat while one is pending. A member gets `409
  already_member` (a member knows the workspace exists).
  """
  use BarkparkWeb, :controller

  alias Barkpark.Content.Errors
  alias Barkpark.RateLimiter
  alias Barkpark.Tenancy.AccessRequest
  alias Barkpark.Tenancy.AccessRequests
  alias BarkparkWeb.ErrorResponse

  # Five asks per user per hour (one process; a restart refills it, see
  # `Barkpark.RateLimiter`). A repeat of a pending ask is billed too.
  @per_hour 5
  @window_seconds 3600

  @doc "`POST /v1/auth/access-requests` — `{\"workspace\": slug, \"note\"?: text}`."
  def create(conn, params) do
    user = conn.assigns.current_user

    with {:ok, slug} <- fetch_slug(params),
         {:ok, note} <- fetch_note(params),
         :ok <- throttle(conn, user.id) do
      case AccessRequests.request(user, slug, note) do
        {:ok, row} -> conn |> put_status(:accepted) |> json(%{access_request: row})
        {:error, reason} -> deny(conn, reason)
      end
    else
      {:error, reason} -> deny(conn, reason)
    end
  end

  @doc "`GET /v1/auth/access-requests` — the caller's own requests, newest first."
  def index(conn, _params) do
    json(conn, %{access_requests: AccessRequests.list_for_user(conn.assigns.current_user.id)})
  end

  @doc "`DELETE /v1/auth/access-requests/:id` — withdraw one of the caller's pending requests."
  def withdraw(conn, %{"id" => id}) do
    case AccessRequests.withdraw(conn.assigns.current_user.id, id) do
      {:ok, row} -> json(conn, %{withdrawn: row})
      {:error, :not_found} -> deny(conn, :not_found)
    end
  end

  defp fetch_slug(%{"workspace" => slug}) when is_binary(slug) do
    case String.trim(slug) do
      "" -> {:error, :missing_workspace}
      trimmed -> {:ok, String.downcase(trimmed)}
    end
  end

  defp fetch_slug(_), do: {:error, :missing_workspace}

  defp fetch_note(params) do
    case Map.get(params, "note") do
      nil -> {:ok, nil}
      note when is_binary(note) -> {:ok, note}
      _ -> {:error, :invalid_note}
    end
  end

  defp throttle(conn, user_id) do
    opts = [capacity: @per_hour, refill_per_sec: @per_hour / @window_seconds]

    case RateLimiter.check(RateLimiter.scoped_key(conn, {:access_request, user_id}), opts) do
      :ok -> :ok
      :rate_limited -> {:error, :rate_limited}
    end
  end

  defp deny(conn, :rate_limited) do
    retry_after = div(@window_seconds, @per_hour)
    env = Errors.to_envelope({:error, :rate_limited, %{retry_after: retry_after}}, conn)

    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> put_status(env.status)
    |> json(%{error: Map.delete(env, :status)})
  end

  defp deny(conn, :missing_workspace),
    do: unprocessable(conn, "workspace is required: the slug of the workspace to ask for")

  defp deny(conn, :invalid_note),
    do: unprocessable(conn, "note must be text of at most #{AccessRequest.note_max()} characters")

  defp deny(conn, :already_member),
    do: fields(conn, :conflict, "already_member", "you already have a seat in this workspace")

  defp deny(conn, :email_unconfirmed),
    do:
      fields(
        conn,
        :forbidden,
        "email_unconfirmed",
        "confirm your email address before asking for access"
      )

  defp deny(conn, :too_many_pending),
    do:
      fields(
        conn,
        :conflict,
        "too_many_pending",
        "you have #{AccessRequests.max_pending()} pending requests; withdraw one first"
      )

  defp deny(conn, :not_found),
    do: fields(conn, :not_found, "not_found", "no such pending access request for this account")

  defp deny(conn, %Ecto.Changeset{} = cs) do
    if Keyword.has_key?(cs.errors, :note),
      do: deny(conn, :invalid_note),
      else: unprocessable(conn, "workspace must be a workspace slug (a-z, 0-9 and -)")
  end

  defp deny(conn, _), do: unprocessable(conn, "could not record the request")

  defp unprocessable(conn, message),
    do: fields(conn, :unprocessable_entity, "unprocessable", message)

  defp fields(conn, status, code, message),
    do: ErrorResponse.emit_fields(conn, status, %{code: code, message: message})
end
