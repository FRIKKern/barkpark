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
    * `rotate/2`   — new secret on the SAME row (identity + ticket history
                     preserved); the old secret dies instantly.
    * `pause/2`    — mute (→ 403 "key paused"), reversible.
    * `unpause/2`  — clear the mute.
    * `revoke/2`   — permanent kill (indistinguishable from missing = 401).
    * `list/1`     — the operator's keys for a workspace, newest first.

  Every workspace-scoped call — the by-id mutations (`rotate`/`pause`/
  `unpause`/`revoke`) AND the `list/1` read — goes through the one
  `scope_workspace/2` fence: a key belonging to another workspace is simply NOT
  FOUND, so an operator can never reach across the tenant boundary (the
  cross-tenant IDOR this module was hardened against). The scope is FAIL-CLOSED
  — a nil workspace matches only the (rare) un-bound keys, never every
  tenant's. `list/1` used to be the exception, widening nil to every tenant's
  keys on the theory that a read is not a destructive act; that was the leak,
  not the exemption. Both of its callers
  (`BarkparkWeb.TicketKeysController.index/2`, `InboxLive`'s key panel) hand it
  the caller's OWN workspace, and each resolves to nil when no tenancy was
  seeded — so the widening only ever fired where the scope was unknown, which
  is precisely when it must not fire.

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

  Scoped by `ws_id` — a key in another workspace resolves to `{:error,
  :not_found}` (fail-closed: `nil` matches only un-bound keys).
  """
  @spec rotate(binary(), binary() | nil) :: key_result()
  def rotate(id, ws_id) do
    case get_ticket_key(id, ws_id) do
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

  @doc """
  Mute a ticket key — `verify/1` then returns `{:error, :paused}` (403). Scoped
  by `ws_id` (a key in another workspace is `{:error, :not_found}`).
  """
  @spec pause(binary(), binary() | nil) ::
          {:ok, ApiToken.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def pause(id, ws_id), do: stamp(id, ws_id, paused_at: now())

  @doc "Un-mute a paused key — `verify/1` returns `{:ok, row}` again. Scoped by `ws_id`."
  @spec unpause(binary(), binary() | nil) ::
          {:ok, ApiToken.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def unpause(id, ws_id), do: stamp(id, ws_id, paused_at: nil)

  @doc """
  Permanently revoke a ticket key (stamp `revoked_at`). After this `verify/1`
  returns `{:error, :unauthorized}` — indistinguishable from a missing key.
  Scoped by `ws_id` (a key in another workspace is `{:error, :not_found}`).
  """
  @spec revoke(binary(), binary() | nil) ::
          {:ok, ApiToken.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def revoke(id, ws_id), do: stamp(id, ws_id, revoked_at: now())

  @doc """
  List the ticket keys, newest first. `workspace` may be a `%Workspace{}`
  struct, a workspace id binary, or `nil`. Rows only — the caller MUST NOT
  expose `token_hash`.

  FAIL-CLOSED on nil, exactly like the by-id fence: `nil` names the un-bound
  tenant, NOT every tenant. See `scope_workspace/2`.
  """
  @spec list(struct() | binary() | nil) :: [ApiToken.t()]
  def list(workspace \\ nil) do
    ApiToken
    |> where([t], t.kind == @kind)
    |> order_by([t], desc: t.inserted_at)
    |> scope_workspace(workspace_id(workspace))
    |> Repo.all()
  end

  # ── internals ──────────────────────────────────────────────────────────

  defp generate_raw,
    do: @prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  # Kind-fenced, WORKSPACE-scoped fetch by id, guarding the :binary_id UUID cast
  # (a non-UUID id would raise Ecto.CastError → 500; a malformed id identifies no
  # row → nil). The workspace predicate is the cross-tenant IDOR fence: a key in
  # another workspace is invisible here, so every by-id mutation is confined to
  # the caller's own tenant.
  defp get_ticket_key(id, ws_id) when is_binary(id) do
    case Repo.uuid_or_nil(id) do
      nil ->
        nil

      uuid ->
        ApiToken
        |> where([t], t.id == ^uuid and t.kind == @kind)
        |> scope_workspace(ws_id)
        |> Repo.one()
    end
  end

  defp get_ticket_key(_, _), do: nil

  # THE workspace fence, fail-closed, shared by the by-id mutations and by
  # `list/1`: a bound caller sees only its workspace's keys; a nil-scoped caller
  # sees only the (rare) un-bound keys — NEVER every tenant's. A nil-scoped
  # operator kill-switching every tenant's key, or READING every tenant's
  # key roster, is the exact fail-OPEN this fence exists to prevent. `list/1`
  # was the one caller that skipped it and widened nil to all tenants; routing
  # it here is what closed that door, so keep this the single scope predicate —
  # a second, laxer copy is how the hole came back.
  defp scope_workspace(query, ws_id) when is_binary(ws_id),
    do: where(query, [t], t.workspace_id == ^ws_id)

  defp scope_workspace(query, nil),
    do: where(query, [t], is_nil(t.workspace_id))

  defp stamp(id, ws_id, changes) do
    case get_ticket_key(id, ws_id) do
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
