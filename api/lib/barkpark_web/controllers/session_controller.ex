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

  def delete(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> put_flash(:info, "Signed out.")
    |> redirect(to: "/studio")
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
