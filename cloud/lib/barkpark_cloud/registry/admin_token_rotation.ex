defmodule BarkparkCloud.Registry.AdminTokenRotation do
  @moduledoc """
  Rotate the admin token Cloud holds for an instance
  (`POST /v1/operator/barkparks/:id/admin-token/rotate`,
  `bp barkparks rotate-admin-token`). Operator only.

      1. read:   GET  <url>/v1/tokens/current (held token) -> id + workspace seat
      2. mint:   POST <url>/w/<ws>/p/default/v1/tokens/elevated (held token)
                 label "barkpark cloud admin" -> the successor
      3. prove:  GET  <url>/v1/capabilities (successor) -> auth_tier admin
      4. store:  the successor, Vault-encrypted, replaces the held ciphertext
                 (compare-and-set on the old ciphertext), read back and compared
      5. revoke: DELETE <url>/w/<ws>/p/default/v1/tokens/<old id> (old token)
      6. check:  GET  <url>/v1/tokens/current (old token) -> the status, 401 expected

  The old token revokes itself in step 5. The box lets an actor revoke a
  token only when the actor administers every workspace that token is seated
  in, and the old token is the one principal sure to. The successor is seated
  only in the workspace it was minted in, and the box has no route that seats
  a token elsewhere, so the receipt names the old token's other seats as
  `seats_not_carried`.

  The old token stays usable and stored until step 5 succeeds. A failure in
  steps 3 to 5 revokes the successor on the box with the old token, and a
  failure after step 4 also writes the old ciphertext back. The successor is
  minted the way `Registry.Adoption` mints Cloud's credential, so it carries
  the same label and `bp token rotate` keeps refusing it.

  Transport is the `:studio_link_http_client` seam every instance call uses,
  to the row's `url`. The old token is read through
  `Registry.reveal_admin_token/1`, so its withholding rules apply here too.
  """

  import Ecto.Query, warn: false
  require Logger

  alias BarkparkCloud.Registry
  alias BarkparkCloud.Registry.{Adoption, Barkpark, Vault}
  alias BarkparkCloud.Repo

  @project "default"
  @dataset "production"

  @typedoc "Why a rotation stopped. The old token is stored and live on every one."
  @type refusal ::
          :not_live
          | :no_admin_token
          | :decrypt_failed
          | :unreachable
          | {:held_token_refused, non_neg_integer()}
          | {:box_too_old, String.t()}
          | {:mint_refused, non_neg_integer(), String.t() | nil}
          | :minted_token_not_admin
          | :store_failed
          | {:revoke_refused, non_neg_integer() | nil}

  @doc """
  Rotate `bp`'s held admin token. Returns `{:ok, barkpark, receipt}` where the
  receipt names the old and new token ids (never a secret), the workspace, and
  the status the old token now gets, or `{:error, refusal}`.
  """
  @spec rotate(Barkpark.t()) :: {:ok, Barkpark.t(), map()} | {:error, refusal()}
  def rotate(%Barkpark{} = bp) do
    with {:ok, base} <- base_url(bp),
         {:ok, old} <- held_token(bp),
         {:ok, held} <- describe(base, old),
         {:ok, minted} <- mint(base, held.workspace, old),
         :ok <- prove(base, held.workspace, minted, old),
         {:ok, stored} <- store(bp, held.workspace, minted, base, old),
         :ok <- revoke_old(bp, base, held, minted, old) do
      {:ok, stored,
       %{
         old_token_id: held.id,
         new_token_id: minted.id,
         label: Adoption.cloud_label(),
         workspace: held.workspace,
         seats_not_carried: held.seats -- [held.workspace],
         old_token_status: probe_status(base, old)
       }}
    end
  end

  # ── 0. the row ────────────────────────────────────────────────────────────

  defp base_url(%Barkpark{url: url}) when is_binary(url) and url != "",
    do: {:ok, String.trim_trailing(url, "/")}

  defp base_url(_), do: {:error, :not_live}

  defp held_token(bp) do
    case Registry.reveal_admin_token(bp) do
      {:ok, nil} -> {:error, :no_admin_token}
      {:ok, token} -> {:ok, token}
      :error -> {:error, :decrypt_failed}
    end
  end

  # ── 1. what the box says the held token is ────────────────────────────────

  # The workspace must be one the held token holds a seat in: the box revokes
  # a token only through a workspace it is seated in.
  defp describe(base, token) do
    case request(base, :get, "/v1/tokens/current", token) do
      {:ok, 200, %{"token" => %{"id" => id} = t} = body} when is_binary(id) ->
        seats =
          for %{"workspace_slug" => slug} when is_binary(slug) <- List.wrap(body["memberships"]),
              do: slug

        {:ok, %{id: id, seats: seats, workspace: seat_workspace(t["workspace"], seats)}}

      {:ok, 404, _} ->
        {:error, {:box_too_old, "GET /v1/tokens/current"}}

      {:ok, status, _} ->
        {:error, {:held_token_refused, status}}

      {:error, :unreachable} ->
        {:error, :unreachable}
    end
  end

  defp seat_workspace(home, seats) do
    cond do
      is_binary(home) and home in seats -> home
      seats != [] -> hd(seats)
      is_binary(home) and home != "" -> home
      true -> "default"
    end
  end

  # ── 2. mint the successor with the held token ─────────────────────────────

  defp mint(base, workspace, token) do
    body = %{
      label: Adoption.cloud_label(),
      permissions: ["read", "write", "admin"],
      dataset: @dataset,
      no_expiry: true
    }

    case request(base, :post, scoped(workspace, "/v1/tokens/elevated"), token, body) do
      {:ok, status, %{"token" => raw, "id" => id}}
      when status in 200..299 and is_binary(raw) and raw != "" ->
        {:ok, %{token: raw, id: id}}

      {:ok, 404, _} ->
        {:error, {:box_too_old, "POST /v1/tokens/elevated"}}

      {:ok, status, body} ->
        {:error, {:mint_refused, status, body["reason"] || body["code"] || body["message"]}}

      {:error, :unreachable} ->
        {:error, :unreachable}
    end
  end

  # ── 3. the successor must read admin ──────────────────────────────────────

  defp prove(base, workspace, minted, old) do
    case request(base, :get, "/v1/capabilities", minted.token) do
      {:ok, 200, %{"auth_tier" => "admin"}} ->
        :ok

      _ ->
        revoke_successor(base, workspace, minted, old)
        {:error, :minted_token_not_admin}
    end
  end

  # ── 4. store it in place of the held token ────────────────────────────────

  defp store(%Barkpark{id: id, admin_token_encrypted: held_ct}, workspace, minted, base, old) do
    now = DateTime.utc_now()

    {count, _} =
      Repo.update_all(
        from(b in Barkpark, where: b.id == ^id and b.admin_token_encrypted == ^held_ct),
        set: [admin_token_encrypted: Vault.encrypt(minted.token), updated_at: now]
      )

    stored = if count == 1, do: Registry.get_barkpark(id)

    if stored && Registry.reveal_admin_token(stored) == {:ok, minted.token} do
      {:ok, stored}
    else
      if count == 1, do: put_back(id, held_ct)
      revoke_successor(base, workspace, minted, old)
      {:error, :store_failed}
    end
  end

  # ── 5. the old token revokes itself ───────────────────────────────────────

  defp revoke_old(bp, base, held, minted, old) do
    case request(base, :delete, scoped(held.workspace, "/v1/tokens/#{held.id}"), old) do
      {:ok, status, _} when status in 200..299 ->
        :ok

      other ->
        put_back(bp.id, bp.admin_token_encrypted)
        revoke_successor(base, held.workspace, minted, old)

        status =
          case other do
            {:ok, s, _} -> s
            _ -> nil
          end

        {:error, {:revoke_refused, status}}
    end
  end

  # ── 6. what the old token gets now ────────────────────────────────────────

  # `/v1/tokens/current` and not `/v1/capabilities`: capabilities answers 200
  # to any bearer, a dead one included (it reads as a public caller), so only
  # a route that requires a token can show the 401.
  defp probe_status(base, token) do
    case request(base, :get, "/v1/tokens/current", token) do
      {:ok, status, _} -> status
      {:error, :unreachable} -> nil
    end
  end

  # ── undo ──────────────────────────────────────────────────────────────────

  defp put_back(id, ciphertext) do
    now = DateTime.utc_now()

    Repo.update_all(from(b in Barkpark, where: b.id == ^id),
      set: [admin_token_encrypted: ciphertext, updated_at: now]
    )
  end

  # Best-effort, with the old token: a successor Cloud does not keep must not
  # stay live. A failed revoke is logged with the token id, never the secret.
  defp revoke_successor(base, workspace, %{id: id}, old) do
    case request(base, :delete, scoped(workspace, "/v1/tokens/#{id}"), old) do
      {:ok, status, _} when status in 200..299 ->
        :ok

      other ->
        Logger.warning(
          "admin-token rotate: could not revoke the unused successor #{inspect(id)} on " <>
            "#{base} (#{inspect(other)}); revoke it on the box"
        )
    end
  end

  # ── transport ─────────────────────────────────────────────────────────────

  defp scoped(workspace, path),
    do: "/w/#{URI.encode(workspace, &URI.char_unreserved?/1)}/p/#{@project}" <> path

  defp request(base, method, path, bearer, body \\ nil) do
    req = %{
      method: method,
      url: base <> path,
      headers: [
        {"Authorization", "Bearer " <> bearer},
        {"Accept", "application/json"},
        {"Content-Type", "application/json"}
      ],
      body: if(body, do: Jason.encode!(body), else: "")
    }

    case http_client().request(req) do
      {:ok, %{status: status, body: resp}} when is_integer(status) ->
        case Jason.decode(resp || "") do
          {:ok, %{} = decoded} -> {:ok, status, decoded}
          _ -> {:ok, status, %{}}
        end

      _ ->
        {:error, :unreachable}
    end
  end

  defp http_client do
    Application.get_env(
      :barkpark_cloud,
      :studio_link_http_client,
      BarkparkCloud.Billing.HttpClient
    )
  end
end
