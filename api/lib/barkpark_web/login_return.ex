defmodule BarkparkWeb.LoginReturn do
  @moduledoc """
  Where a sign-in that leaves the login page lands (task-1757bffde0f4c254).

  `/login?return_to=<path>` carries the path in hidden fields for the forms
  on the page itself. Two sign-ins leave the page and come back on a new
  request with no form: "Log in with Barkpark Cloud" (back on
  `/login/ticket/:t`) and the emailed magic link (`/auth/magic/:t`). Those
  read the path from the browser session instead, where `GET /login` put it.

  The stored path is used only when:

    * it passes `BarkparkWeb.ReturnTo.safe_path/1`, both as written and
      percent-decoded (a browser reads `%2e` as `.`);
    * it is not a sign-in or sign-out page (`/login…`, `/logout…`,
      `/auth/…`), so a sign-in never lands back on a sign-in step;
    * it was stored less than 15 minutes ago. Asking for a
      magic link restamps it, so it lasts as long as the link does.

  Anything else lands on `/studio`. Every sign-in that mints a session
  forgets the path, and sign-out clears the whole session, so the next
  person on the same browser does not inherit it.
  """

  import Plug.Conn, only: [get_session: 2, put_session: 3, delete_session: 2]

  alias BarkparkWeb.ReturnTo

  @key "login_return_to"
  @ttl_seconds 15 * 60
  @default "/studio"

  @doc "Store `return_to` (from `GET /login`), or forget any stored path when it is unusable."
  @spec remember(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def remember(conn, return_to) do
    case usable(return_to) do
      nil -> forget(conn)
      path -> put_session(conn, @key, %{"path" => path, "at" => now()})
    end
  end

  @doc "Restamp a stored, still-usable path (a magic link was just asked for)."
  @spec refresh(Plug.Conn.t()) :: Plug.Conn.t()
  def refresh(conn) do
    case stored(conn) do
      nil -> forget(conn)
      path -> put_session(conn, @key, %{"path" => path, "at" => now()})
    end
  end

  @doc "The stored path if it is still usable, else `/studio`. Leaves the session as it is."
  @spec path(Plug.Conn.t()) :: String.t()
  def path(conn), do: stored(conn) || @default

  @doc "`/login`, keeping a stored path, for a sign-in that failed and starts again."
  @spec login_path(Plug.Conn.t()) :: String.t()
  def login_path(conn) do
    case stored(conn) do
      nil -> "/login"
      path -> "/login?" <> URI.encode_query(%{"return_to" => path})
    end
  end

  @doc "Drop the stored path."
  @spec forget(Plug.Conn.t()) :: Plug.Conn.t()
  def forget(conn), do: delete_session(conn, @key)

  @doc "The session key, for tests."
  def session_key, do: @key

  @doc "How long a stored path lasts, in seconds."
  def ttl_seconds, do: @ttl_seconds

  defp stored(conn) do
    with %{"path" => path, "at" => at} when is_integer(at) <- get_session(conn, @key),
         true <- fresh?(at) do
      usable(path)
    else
      _ -> nil
    end
  end

  # Same sidedness as the MFA window: an anchor later than now is refused.
  defp fresh?(at) do
    now = now()
    at <= now and now - at <= @ttl_seconds
  end

  defp usable(path) do
    with safe when is_binary(safe) <- ReturnTo.safe_path(path),
         {:ok, decoded} <- decode(safe),
         true <- ReturnTo.safe_path(decoded) == decoded,
         false <- sign_in_page?(decoded),
         false <- safe == @default do
      safe
    else
      _ -> nil
    end
  end

  defp decode(path) do
    {:ok, URI.decode(path)}
  rescue
    ArgumentError -> :error
  end

  defp sign_in_page?(path) do
    segments =
      (URI.parse(path).path || "")
      |> String.split("/", trim: true)

    Enum.any?(segments, &(&1 in [".", ".."])) or
      match?([first | _] when first in ["login", "logout", "auth"], segments)
  end

  defp now, do: System.system_time(:second)
end
