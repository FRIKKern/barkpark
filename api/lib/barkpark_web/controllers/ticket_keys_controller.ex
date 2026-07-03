defmodule BarkparkWeb.TicketKeysController do
  @moduledoc """
  `/v1/plugins/tickets/keys` — the OPERATOR's ticket-key management surface
  (Barkpark Tickets, charter route table). Mounted by the tickets plugin (a
  sibling slice) on the `:api` bucket → `[:api, :require_admin]`: minting a key
  that grants an outsider access is an administrative act.

  * `create` (mint) — 201 with the key metadata, the raw key shown ONCE, and a
    forwardable `quickstart` handoff card (`Handoff.card/2`) the operator sends
    to the key-holder. The raw key is never recoverable after this response.
  * `index`  — the operator's keys (never the hash / raw).
  * `rotate` — new secret on the same identity (old secret dies instantly).
  * `pause` / `unpause` — mute / un-mute (403 "key paused" vs live).
  * `delete` — permanent revoke.

  Every write goes through `Barkpark.Plugins.Tickets.Keys`; this controller only
  shapes params and JSON.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Plugins.Tickets.{Handoff, Keys}

  @doc """
  `POST /v1/plugins/tickets/keys` — mint a named ticket key.

  Body/params: `name` (required, the human identity label), `dataset`
  (optional, default `"production"`). 201 with `{key, raw, quickstart}`; 422 on
  a missing/blank/over-long name.
  """
  def create(conn, params) do
    attrs = %{
      name: params["name"],
      dataset: params["dataset"],
      workspace_id: current_workspace_id(conn)
    }

    case Keys.mint(attrs) do
      {:ok, %{key: key, raw: raw}} ->
        conn
        |> put_status(:created)
        |> json(%{
          key: key_json(key),
          raw: raw,
          quickstart: Handoff.card(host_base(conn), raw)
        })

      {:error, :invalid_name} ->
        unprocessable(conn, "a non-empty `name` (the key-holder's identity label) is required")

      {:error, :name_too_long} ->
        unprocessable(conn, "`name` must be at most 200 characters")

      {:error, _changeset} ->
        unprocessable(conn, "could not mint ticket key")
    end
  end

  @doc "`GET /v1/plugins/tickets/keys` — list the operator's ticket keys."
  def index(conn, _params) do
    keys = conn |> current_workspace_id() |> Keys.list() |> Enum.map(&key_json/1)
    json(conn, %{keys: keys})
  end

  @doc """
  `POST /v1/plugins/tickets/keys/:id/rotate` — new secret, SAME identity. 200
  with the rotated key + the new raw shown ONCE.
  """
  def rotate(conn, %{"id" => id}) do
    case Keys.rotate(id) do
      {:ok, %{key: key, raw: raw}} -> json(conn, %{key: key_json(key), raw: raw})
      {:error, :not_found} -> not_found(conn, "ticket key not found")
      {:error, _} -> unprocessable(conn, "could not rotate ticket key")
    end
  end

  @doc "`POST /v1/plugins/tickets/keys/:id/pause` — mute a key (→ 403 on use)."
  def pause(conn, %{"id" => id}), do: stamp_response(conn, Keys.pause(id))

  @doc "`POST /v1/plugins/tickets/keys/:id/unpause` — un-mute a paused key."
  def unpause(conn, %{"id" => id}), do: stamp_response(conn, Keys.unpause(id))

  @doc "`DELETE /v1/plugins/tickets/keys/:id` — permanently revoke a key."
  def delete(conn, %{"id" => id}) do
    case Keys.revoke(id) do
      {:ok, key} -> json(conn, %{revoked: true, key: key_json(key)})
      {:error, :not_found} -> not_found(conn, "ticket key not found")
      {:error, _} -> unprocessable(conn, "could not revoke ticket key")
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp stamp_response(conn, {:ok, key}), do: json(conn, %{key: key_json(key)})
  defp stamp_response(conn, {:error, :not_found}), do: not_found(conn, "ticket key not found")
  defp stamp_response(conn, {:error, _}), do: unprocessable(conn, "could not update ticket key")

  # The key row MINUS the secret — token_hash never leaves the server. `paused`
  # is the operator-facing state; `status` folds revoked/paused/live into one
  # label for the CLI/Studio inbox to render without recomputing.
  defp key_json(key) do
    %{
      id: key.id,
      name: key.name,
      dataset: key.dataset,
      status: key_status(key),
      paused_at: key.paused_at,
      revoked_at: key.revoked_at,
      expires_at: key.expires_at,
      last_used_at: key.last_used_at,
      created_at: key.inserted_at
    }
  end

  defp key_status(%{revoked_at: r}) when not is_nil(r), do: "revoked"
  defp key_status(%{paused_at: p}) when not is_nil(p), do: "paused"
  defp key_status(_), do: "live"

  defp current_workspace_id(conn) do
    case conn.assigns[:current_workspace] do
      %{id: id} -> id
      _ -> nil
    end
  end

  # The public base URL of THIS request — what the handoff-card curls target.
  # Rebuilt from the request so the card matches the host the operator actually
  # called (guerrilla.barkpark.cloud, a self-host, localhost in dev).
  #
  # Behind a TLS-terminating proxy (Caddy on the cloud hosts) `conn.scheme` is
  # the INTERNAL hop (`http`), and a card that says `http://…` sends the
  # key-holder's very first curl into the proxy's 308 https redirect — curl
  # doesn't follow it, and the 2-minute story dies on step one. So when the
  # proxy declares the outside world via `x-forwarded-proto` (Caddy sets it by
  # default), trust that scheme, and take the public port from
  # `x-forwarded-port` when present (absent ⇒ the scheme's standard port, which
  # is elided). Spoofing is a non-issue: the header only shapes the caller's OWN
  # card text on an admin-gated route.
  @doc false
  def host_base(conn) do
    case forwarded_proto(conn) do
      nil -> base_url(to_string(conn.scheme), conn.host, conn.port)
      proto -> base_url(proto, conn.host, forwarded_port(conn) || standard_port(proto))
    end
  end

  defp base_url(scheme, host, port) do
    if standard_port?(scheme, port) do
      "#{scheme}://#{host}"
    else
      "#{scheme}://#{host}:#{port}"
    end
  end

  # First entry of x-forwarded-proto (chained proxies comma-join), lowercased;
  # only literal http/https are trusted — anything else falls back to conn.scheme.
  defp forwarded_proto(conn) do
    with [value | _] <- get_req_header(conn, "x-forwarded-proto"),
         proto = value |> String.split(",") |> hd() |> String.trim() |> String.downcase(),
         true <- proto in ["http", "https"] do
      proto
    else
      _ -> nil
    end
  end

  defp forwarded_port(conn) do
    with [value | _] <- get_req_header(conn, "x-forwarded-port"),
         {port, ""} <- Integer.parse(String.trim(value)) do
      port
    else
      _ -> nil
    end
  end

  defp standard_port("http"), do: 80
  defp standard_port("https"), do: 443

  defp standard_port?("http", 80), do: true
  defp standard_port?("https", 443), do: true
  defp standard_port?(_, _), do: false

  defp unprocessable(conn, message) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "unprocessable", message: message}})
  end

  defp not_found(conn, message) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{code: "not_found", message: message}})
  end
end
