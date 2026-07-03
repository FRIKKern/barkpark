defmodule Barkpark.Plugins.Tickets.Keys do
  @moduledoc """
  The low-trust TICKET-KEY tier (Barkpark Tickets, charter Decision 1).

  Possession of a named ticket key IS identity: an operator mints one, hands it
  to an outside user, and the key-holder files/reads tickets with it. The key
  rides the existing `api_tokens` table (`kind == "ticket"`) so it reuses
  SHA-256 hashing, revocation, expiry, and tenant scoping — but it is
  DELIBERATELY inert everywhere a normal token acts: `Auth.verify_token/1`
  filters `kind == "api"`, so RequireToken / RequireAdmin / session auth all
  reject it. This module's `verify/1` (kind == "ticket") is the ONLY resolver
  that accepts one, consumed solely by `BarkparkWeb.Plugs.RequireTicketKey`.

  Raw keys are prefixed `bptk_` (greppable, self-describing) and shown ONCE at
  mint — only the SHA-256 hash is stored, so a raw key is never recoverable.

  Lifecycle:

    * `mint/1`     — new key, returns `{:ok, %{key: row, raw: "bptk_…"}}`.
    * `verify/1`   — resolve a raw key: live → `{:ok, row}`, paused →
                     `{:error, :paused}`, everything else (missing / revoked /
                     expired / wrong-kind) → `{:error, :unauthorized}`.
    * `rotate/1`   — new secret on the SAME row (identity + ticket history
                     preserved); the old secret dies instantly.
    * `pause/1`    — mute (→ 403 "key paused"), reversible.
    * `unpause/1`  — clear the mute.
    * `revoke/1`   — permanent kill (indistinguishable from missing = 401).
    * `list/1`     — the operator's keys for a workspace, newest first.

  Permissions are the opaque `["ticket"]` — it satisfies no global read/write/
  admin tier, so even if the fail-closed WHERE clause were bypassed the key
  could drive nothing but the ticket surface.
  """

  import Ecto.Query

  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo

  @kind "ticket"
  @prefix "bptk_"
  @default_dataset "production"
  # Cap the operator-supplied name well under the varchar(255) `name`/`label`
  # columns so an over-long name is a clean {:error, :name_too_long} (422), not
  # a Postgrex value-too-long raise (500).
  @max_name_length 200

  @type key_result :: {:ok, %{key: ApiToken.t(), raw: binary()}} | {:error, term()}

  @doc """
  Mint a ticket key. `attrs` (map, atom OR string keys):

    * `:name` (required) — the human identity label the operator sees
      ("Gyldendal — Kari"). Also mirrored to `label`.
    * `:workspace_id` — the workspace the key is bound to (nil allowed for the
      back-compat un-bound path, mirroring `Auth.create_token/5`).
    * `:dataset` (default `"production"`).

  Returns `{:ok, %{key: row, raw: "bptk_…"}}` — the raw key is returned ONCE and
  never recoverable — or `{:error, changeset}` / `{:error, :invalid_name}` /
  `{:error, :name_too_long}` (> #{@max_name_length} characters — the columns are
  varchar(255), so an unchecked name would surface as a 500, not a 422).

  No `Membership` row is created (like the P5 share tokens): a ticket key is
  member-less AND kind-fenced, so it is inert on every normal route.
  """
  @spec mint(map()) :: key_result()
  def mint(attrs) when is_map(attrs) do
    name = fetch(attrs, :name)

    cond do
      not (is_binary(name) and String.trim(name) != "") ->
        {:error, :invalid_name}

      String.length(name) > @max_name_length ->
        {:error, :name_too_long}

      true ->
        raw = generate_raw()

        token_attrs = %{
          token_hash: ApiToken.hash_token(raw),
          kind: @kind,
          name: name,
          label: name,
          dataset: fetch(attrs, :dataset) || @default_dataset,
          # Opaque, satisfies no global tier — defence-in-depth behind the
          # kind-fence: a ticket key can never drive a permission-gated route.
          permissions: ["ticket"],
          workspace_id: fetch(attrs, :workspace_id)
        }

        case %ApiToken{} |> ApiToken.changeset(token_attrs) |> Repo.insert() do
          {:ok, row} -> {:ok, %{key: row, raw: raw}}
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  def mint(_), do: {:error, :invalid_name}

  @doc """
  Resolve a raw ticket key.

    * live (not revoked, not expired, `kind == "ticket"`) → `{:ok, row}`
    * `paused_at` set → `{:error, :paused}` (403 "key paused")
    * missing / revoked / expired / wrong-kind → `{:error, :unauthorized}`

  Revocation + expiry + kind are enforced in the WHERE clause (never a
  post-filter), so a revoked/expired/api-kind key is indistinguishable from a
  missing one. `paused_at` is a POST-check because a paused key must be
  DISTINGUISHABLE (a live identity the operator can un-mute), unlike a revoked
  one.
  """
  @spec verify(binary()) :: {:ok, ApiToken.t()} | {:error, :unauthorized | :paused}
  def verify(raw) when is_binary(raw) do
    hash = ApiToken.hash_token(raw)
    now = DateTime.utc_now()

    ApiToken
    |> where([t], t.token_hash == ^hash)
    |> where([t], t.kind == @kind)
    |> where([t], is_nil(t.revoked_at))
    |> where([t], is_nil(t.expires_at) or t.expires_at > ^now)
    |> Repo.one()
    |> case do
      nil -> {:error, :unauthorized}
      %ApiToken{paused_at: paused_at} when not is_nil(paused_at) -> {:error, :paused}
      row -> {:ok, row}
    end
  end

  def verify(_), do: {:error, :unauthorized}

  @doc """
  Rotate a key's secret: a NEW `bptk_…` on the SAME row, so the key's identity,
  name, and (in a sibling slice) ticket history all survive — only the secret
  changes. The OLD secret dies the instant this commits (the hash no longer
  matches). Returns `{:ok, %{key: row, raw: new_raw}}` or `{:error, :not_found}`.
  """
  @spec rotate(binary()) :: key_result()
  def rotate(id) do
    case get_ticket_key(id) do
      nil ->
        {:error, :not_found}

      %ApiToken{} = row ->
        raw = generate_raw()

        case row
             |> ApiToken.changeset(%{token_hash: ApiToken.hash_token(raw)})
             |> Repo.update() do
          {:ok, updated} -> {:ok, %{key: updated, raw: raw}}
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  @doc "Mute a ticket key — `verify/1` then returns `{:error, :paused}` (403)."
  @spec pause(binary()) :: {:ok, ApiToken.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def pause(id), do: stamp(id, paused_at: now())

  @doc "Un-mute a paused key — `verify/1` returns `{:ok, row}` again."
  @spec unpause(binary()) :: {:ok, ApiToken.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def unpause(id), do: stamp(id, paused_at: nil)

  @doc """
  Permanently revoke a ticket key (stamp `revoked_at`). After this `verify/1`
  returns `{:error, :unauthorized}` — indistinguishable from a missing key.
  """
  @spec revoke(binary()) :: {:ok, ApiToken.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def revoke(id), do: stamp(id, revoked_at: now())

  @doc """
  List the ticket keys, newest first. `workspace` may be a `%Workspace{}`
  struct, a workspace id binary, or `nil` (every ticket key). Rows only — the
  caller MUST NOT expose `token_hash`.
  """
  @spec list(struct() | binary() | nil) :: [ApiToken.t()]
  def list(workspace \\ nil) do
    query =
      ApiToken
      |> where([t], t.kind == @kind)
      |> order_by([t], desc: t.inserted_at)

    case workspace_id(workspace) do
      nil -> query
      ws_id -> where(query, [t], t.workspace_id == ^ws_id)
    end
    |> Repo.all()
  end

  # ── internals ──────────────────────────────────────────────────────────

  defp generate_raw,
    do: @prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  # Kind-fenced fetch by id, guarding the :binary_id UUID cast (a non-UUID id
  # would raise Ecto.CastError → 500; a malformed id identifies no row → nil).
  defp get_ticket_key(id) when is_binary(id) do
    case Repo.uuid_or_nil(id) do
      nil ->
        nil

      uuid ->
        ApiToken
        |> where([t], t.id == ^uuid and t.kind == @kind)
        |> Repo.one()
    end
  end

  defp get_ticket_key(_), do: nil

  defp stamp(id, changes) do
    case get_ticket_key(id) do
      nil -> {:error, :not_found}
      %ApiToken{} = row -> row |> Ecto.Changeset.change(changes) |> Repo.update()
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp workspace_id(nil), do: nil
  defp workspace_id(id) when is_binary(id), do: id
  defp workspace_id(%{id: id}), do: id

  defp fetch(attrs, key) when is_atom(key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> Map.get(attrs, Atom.to_string(key))
    end
  end
end
