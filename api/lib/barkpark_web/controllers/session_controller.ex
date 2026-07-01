defmodule BarkparkWeb.SessionController do
  @moduledoc """
  Browser-facing session controller. Lets a human paste their raw API
  token via `GET /login`, stores it in `session["api_token"]` on success,
  and clears the session via `POST /logout`.

  This is the canonical browser entry point for admin LiveViews; see
  `BarkparkWeb.LiveAuth` for the on_mount that consumes the session key.
  """
  use BarkparkWeb, :controller

  @default_return_to "/studio"

  def new(conn, params) do
    return_to = sanitize_return_to(params["return_to"])
    render(conn, :new, return_to: return_to, page_title: "Sign in")
  end

  def create(conn, %{"token" => raw_token} = params) when is_binary(raw_token) do
    return_to = sanitize_return_to(params["return_to"])
    trimmed = String.trim(raw_token)

    case Barkpark.Auth.verify_token(trimmed) do
      {:ok, _api_token} ->
        conn
        |> configure_session(renew: true)
        |> put_session("api_token", trimmed)
        |> put_flash(:info, "Signed in.")
        |> redirect(to: return_to)

      {:error, :unauthorized} ->
        conn
        |> put_flash(:error, "Invalid API token.")
        |> render(:new, return_to: return_to, page_title: "Sign in")
    end
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, "Token is required.")
    |> render(:new, return_to: @default_return_to, page_title: "Sign in")
  end

  @doc """
  Consume a single-use login ticket (dwb-7 "Studio one-click entry").

  `GET /login/ticket/:ticket` — atomically consumes the ticket (single-use +
  60s TTL, enforced in `Barkpark.Auth.consume_login_ticket/1`), drops the bound
  RAW api_token into `session["api_token"]` exactly like `create/2` does for a
  pasted token, and redirects to `/studio`. One click, no paste, works from a
  fresh browser.

  Consuming on GET is the magic-link tradeoff: mitigated by single-use + short
  TTL + `Cache-Control: no-store` (no proxy/history reuse) + `Referrer-Policy:
  no-referrer` (the ticket URL never leaks as a Referer to /studio). Every
  failure kind (unknown / used / expired) yields the SAME friendly flash — no
  oracle.
  """
  def ticket(conn, %{"ticket" => raw_ticket}) when is_binary(raw_ticket) do
    conn = no_store(conn)

    case Barkpark.Auth.consume_login_ticket(raw_ticket) do
      {:ok, api_token} ->
        conn
        |> configure_session(renew: true)
        |> put_session("api_token", api_token)
        |> put_flash(:info, "Signed in.")
        |> redirect(to: @default_return_to)

      {:error, :invalid} ->
        conn
        |> put_flash(:error, "This sign-in link is invalid or has expired.")
        |> redirect(to: "/login")
    end
  end

  def ticket(conn, _params) do
    conn
    |> no_store()
    |> put_flash(:error, "This sign-in link is invalid or has expired.")
    |> redirect(to: "/login")
  end

  def delete(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> put_flash(:info, "Signed out.")
    |> redirect(to: "/studio")
  end

  # Harden the one-time-link response: never cached/stored, and the ticket URL
  # is never leaked onward as a Referer.
  defp no_store(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
  end

  defp sanitize_return_to(nil), do: @default_return_to
  defp sanitize_return_to(""), do: @default_return_to

  defp sanitize_return_to(path) when is_binary(path) do
    if String.starts_with?(path, "/") and not String.starts_with?(path, "//") do
      path
    else
      @default_return_to
    end
  end

  defp sanitize_return_to(_), do: @default_return_to
end
