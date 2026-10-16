defmodule BarkparkWeb.PersonalChatController do
  @moduledoc """
  Account-owned storage in the existing StudioChat engine. Execution and live
  transport remain unavailable until a personal application runtime is bound.
  No client may import assistant history, choose ownership, or run a provider.

  Stored `claude`/`plan` defaults are inert legacy values, not an application
  provider choice. A future closed application binding must explicitly handle
  existing rows; it must never activate these defaults as a repo-worker runtime.
  """
  use BarkparkWeb, :controller
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Session
  alias BarkparkWeb.ErrorResponse

  def create(conn, params) do
    with {:ok, attrs} <- continuity(Map.drop(params, ["workspace_slug"]), ["title"]),
         {:ok, session} <-
           StudioChat.create_session(
             Map.merge(%{id: Ecto.UUID.generate(), mode: "plan"}, atom_attrs(attrs)),
             conn.assigns.chat_scope
           ) do
      conn |> put_status(:created) |> json(session_json(session, []))
    else
      {:error, _} -> invalid(conn)
    end
  end

  def index(conn, params) do
    case Map.get(params, "archived", "false") do
      archived when archived in ["true", "false"] ->
        sessions =
          StudioChat.list_sessions([archived: archived == "true"], conn.assigns.chat_scope)

        json(conn, %{sessions: Enum.map(sessions, &summary/1), runtime_available: false})

      _ ->
        invalid(conn)
    end
  end

  def show(conn, %{"id" => id} = params) do
    with %Session{} = session <- owned(conn, id),
         {:ok, since} <- since(Map.get(params, "since", "0")),
         {:ok, page} <- StudioChat.personal_messages_since(id, since, conn.assigns.chat_scope) do
      json(conn, Map.merge(session_json(session, page.messages), %{page: page.page}))
    else
      nil -> missing(conn)
      {:error, :not_found} -> missing(conn)
      {:error, _} -> invalid(conn)
    end
  end

  def update(conn, %{"id" => id} = params) do
    with %Session{} <- owned(conn, id),
         {:ok, attrs} <- continuity(body(params), ["title", "draft"]),
         {:ok, session} <- StudioChat.update_personal_session(id, attrs, conn.assigns.chat_scope) do
      json(conn, session_json(session, []))
    else
      nil -> missing(conn)
      {:error, :not_found} -> missing(conn)
      {:error, _} -> invalid(conn)
    end
  end

  def archive(conn, %{"id" => id}),
    do: lifecycle(conn, StudioChat.archive_session(id, conn.assigns.chat_scope))

  def unarchive(conn, %{"id" => id}),
    do: lifecycle(conn, StudioChat.unarchive_session(id, conn.assigns.chat_scope))

  def unavailable(conn, %{"id" => id}) do
    case owned(conn, id) do
      %Session{} -> unavailable(conn, %{})
      nil -> missing(conn)
    end
  end

  def unavailable(conn, _params) do
    ErrorResponse.emit_custom(
      conn,
      503,
      "personal_chat_runtime_unavailable",
      "personal chat storage is available; its runtime and live transport are not released"
    )
  end

  defp owned(conn, id), do: StudioChat.get_session(id, conn.assigns.chat_scope)
  defp body(params), do: Map.drop(params, ["workspace_slug", "id"])

  defp continuity(params, allowed) do
    valid =
      is_map(params) and Map.keys(params) -- allowed == [] and
        Enum.all?(params, fn
          {"title", value} when is_binary(value) ->
            String.trim(value) != "" and byte_size(value) <= 256

          {"draft", nil} ->
            true

          {"draft", value} when is_binary(value) ->
            byte_size(value) <= 65_536

          _ ->
            false
        end)

    if valid, do: {:ok, params}, else: {:error, :invalid}
  end

  defp atom_attrs(attrs) do
    case attrs do
      %{"title" => title} -> %{title: String.trim(title), title_source: "human"}
      _ -> %{}
    end
  end

  defp since(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 and n <= 2_147_483_647 -> {:ok, n}
      _ -> {:error, :invalid}
    end
  end

  defp since(_), do: {:error, :invalid}

  defp lifecycle(conn, {:ok, session}), do: json(conn, session_json(session, []))
  defp lifecycle(conn, :noop), do: missing(conn)
  defp lifecycle(conn, _), do: invalid(conn)

  defp summary(session),
    do: Map.take(session, [:id, :title, :title_source, :archived_at, :inserted_at, :updated_at])

  defp session_json(session, messages),
    do:
      Map.merge(summary(session), %{
        draft: session.draft,
        messages: messages,
        runtime_available: false
      })

  defp missing(conn), do: ErrorResponse.emit(conn, {:error, :not_found}, "chat session not found")

  defp invalid(conn),
    do: ErrorResponse.emit_custom(conn, 400, "invalid_request", "invalid personal chat request")
end
