defmodule BarkparkWeb.MemberController do
  @moduledoc """
  Admin-gated workspace ROSTER: list seats, seat a human, change a role, remove
  a seat.

  Mounted under `:scoped_api` + `:scoped_admin`, the same gate as schema
  management and the token mint — so authority here is the membership ROLE
  (`owner`/`admin`) in the resolved workspace, never a token's global
  permissions. A globally-privileged token that is merely a `member` of this
  workspace cannot administer its roster.

  Why the surface exists at all: every primitive was already in the tree, but
  with no endpoint an owner could not answer "who can reach my workspace?", let
  alone seat somebody. See `Barkpark.Tenancy.Members` for the two safety rails
  (last-owner protection, explicit principal kind).

  ## Denial shapes

  `404` for a seat this workspace does not have — including a raw id that names
  a principal in some OTHER workspace, which must not be distinguishable from
  one that does not exist. `409` for a state conflict the caller can resolve
  (already a member; last owner). `422` for a malformed request.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Auth
  alias Barkpark.Tenancy.Members

  @default_role "member"

  @doc """
  `GET /w/:ws/p/:proj/v1/members` — the roster, humans and tokens alike, ONE
  PAGE at a time.

  `?limit=` (default 100, clamped to [1, 1000]) and `?offset=` (clamped to
  [0, 100_000]) — the same spelling and the same clamps `doc query` already
  uses, so one paginator works against both. The envelope keeps `members:`
  and adds the `count/total/limit/offset/hasMore/nextOffset` quintet the other
  paginated list reads carry: without a `total` a caller cannot tell a page
  that happens to be short from the last one.
  """
  def index(conn, params) do
    with %{id: ws_id} <- conn.assigns[:current_workspace] do
      {limit, offset} = page_window(params)
      members = Members.list_members(ws_id, limit: limit, offset: offset)
      total = Members.count_members(ws_id)

      json(conn, page_envelope(:members, members, total, limit, offset))
    else
      _ -> unresolved_workspace(conn)
    end
  end

  @doc """
  `POST /w/:ws/p/:proj/v1/members` — seat a human.

  Body: `{"email": "person@example.com", "role": "member|admin|owner|<custom>"}`.
  `role` defaults to `member`; the membership changeset validates it against
  the built-ins plus this workspace's custom roles.
  """
  def create(conn, params) do
    with %{id: ws_id} <- conn.assigns[:current_workspace],
         {:ok, email} <- fetch_string(params, "email", :missing_email),
         role <- Map.get(params, "role", @default_role) do
      case Members.add_user_member(ws_id, email, to_string(role)) do
        {:ok, member} ->
          conn |> put_status(:created) |> json(%{member: member})

        {:error, reason} ->
          deny(conn, reason)
      end
    else
      {:error, :missing_email} ->
        unprocessable(conn, "email is required and must be a non-empty string")

      _ ->
        unresolved_workspace(conn)
    end
  end

  @doc """
  `PATCH /w/:ws/p/:proj/v1/members/:principal_ref` — change a seat's role.

  `principal_ref` is an e-mail or a raw principal id; a raw id is read as a
  USER unless `?principal_type=api_token` says otherwise, because a bare UUID
  carries no kind and guessing is the hazard `Tenancy.Auth` documents.
  """
  def update(conn, %{"principal_ref" => ref} = params) do
    with %{id: ws_id} <- conn.assigns[:current_workspace],
         {:ok, role} <- fetch_string(params, "role", :missing_role),
         {:ok, principal} <- Members.resolve_principal(ref, principal_type(params)) do
      case Members.update_role(ws_id, principal, role) do
        {:ok, member} -> json(conn, %{member: member})
        {:error, reason} -> deny(conn, reason)
      end
    else
      {:error, :missing_role} ->
        unprocessable(conn, "role is required and must be a non-empty string")

      {:error, reason} when is_atom(reason) ->
        deny(conn, reason)

      _ ->
        unresolved_workspace(conn)
    end
  end

  @doc """
  `DELETE /w/:ws/p/:proj/v1/members/:principal_ref` — remove a seat.

  Removing a token seat does not revoke the token; it only ends its membership
  in this workspace (`DELETE /v1/tokens/:id` kills the credential itself).
  """
  def delete(conn, %{"principal_ref" => ref} = params) do
    with %{id: ws_id} <- conn.assigns[:current_workspace],
         {:ok, principal} <- Members.resolve_principal(ref, principal_type(params)) do
      case Members.remove_member(ws_id, principal) do
        {:ok, member} -> json(conn, %{removed: member})
        {:error, reason} -> deny(conn, reason)
      end
    else
      {:error, reason} when is_atom(reason) -> deny(conn, reason)
      _ -> unresolved_workspace(conn)
    end
  end

  @doc """
  `GET /w/:ws/p/:proj/v1/tokens` — the token inventory for this workspace.

  Answers "which credentials can reach my workspace, and are any stale or
  revoked?". Secrets are never returned (only the hash is stored, and it is
  never selected).

  Paged like the roster beside it: `?limit=` (default 100, clamped to
  [1, 1000]) and `?offset=` (clamped to [0, 100_000]), `tokens:` plus
  `count/total/limit/offset/hasMore/nextOffset`. A live instance holding ~100
  credentials is the case this exists for — an unbounded inventory is both a
  slow read and one a client cannot page through.
  """
  def tokens(conn, params) do
    with %{id: ws_id} <- conn.assigns[:current_workspace] do
      {limit, offset} = page_window(params)
      tokens = Members.list_workspace_tokens(ws_id, limit: limit, offset: offset)
      total = Members.count_workspace_tokens(ws_id)

      json(conn, page_envelope(:tokens, tokens, total, limit, offset))
    else
      _ -> unresolved_workspace(conn)
    end
  end

  @doc """
  `DELETE /w/:ws/p/:proj/v1/tokens/:id` — revoke a token that holds a seat here.

  Cross-tenant rail: the token must be a member of THIS workspace or the answer
  is 404 — an admin of A never reaches a credential that only belongs to B.
  Revocation is idempotent; the audit trail is emitted by
  `Barkpark.Auth.revoke_token/1`.
  """
  def revoke_token(conn, %{"id" => token_id}) do
    with %{id: ws_id} <- conn.assigns[:current_workspace],
         true <- Members.token_member?(ws_id, token_id),
         {:ok, token} <- Auth.revoke_token(token_id) do
      json(conn, %{revoked: %{id: token.id, label: token.label, revoked_at: token.revoked_at}})
    else
      false ->
        not_found(conn, "no token with that id holds a seat in this workspace")

      {:error, :not_found} ->
        not_found(conn, "no token with that id holds a seat in this workspace")

      {:error, _} ->
        unprocessable(conn, "could not revoke token")

      _ ->
        unresolved_workspace(conn)
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp principal_type(%{"principal_type" => "api_token"}), do: :api_token
  defp principal_type(_), do: :user

  # The page window, in the spelling and with the clamps query_controller.ex
  # already uses (limit default 100, [1, 1000]; offset [0, 100_000]). Clamping
  # rather than 422ing is deliberate and matches that sibling: `--limit 0` and
  # `--offset -1` answer a page instead of an error, and the echoed limit/offset
  # in the body report what the query ACTUALLY used, so a paginator that reads
  # them back computes the right next page.
  defp page_window(params) do
    limit = params |> Map.get("limit") |> parse_int(100) |> min(1000) |> max(1)
    offset = params |> Map.get("offset") |> parse_int(0) |> max(0) |> min(100_000)
    {limit, offset}
  end

  # `hasMore` is `offset + returned < total`, never `returned == limit`: a last
  # page that is exactly `limit` rows long would otherwise advertise a next page
  # that does not exist, and `nextOffset` would point past the end. The offset
  # is emitted ONLY when a next page genuinely exists, so an exhausted read
  # never leaves a dangling cursor.
  defp page_envelope(key, rows, total, limit, offset) do
    returned = length(rows)
    has_more = offset + returned < total

    envelope = %{
      key => rows,
      count: returned,
      total: total,
      limit: limit,
      offset: offset,
      hasMore: has_more
    }

    if has_more, do: Map.put(envelope, :nextOffset, offset + returned), else: envelope
  end

  defp parse_int(nil, default), do: default

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(value, _default) when is_integer(value), do: value

  # Catch-all: `?limit[]=1` reaches Plug as `["1"]`, and a list (or any other
  # non-scalar) must fall back to the default rather than raise
  # FunctionClauseError — a 500 on a malformed query string is a denial of
  # service the caller controls.
  defp parse_int(_, default), do: default

  # `on_missing` is a STATIC atom supplied by the call site. It used to be
  # derived from the request key at runtime — atoms are never garbage
  # collected, so deriving one from a request-controlled key is an atom-table
  # exhaustion vector (Sobelow DOS.StringToAtom, and it caught this here).
  defp fetch_string(params, key, on_missing) do
    case Map.get(params, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, on_missing}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, on_missing}
    end
  end

  defp deny(conn, :not_found),
    do: not_found(conn, "no such member in this workspace")

  defp deny(conn, :unknown_principal),
    do: not_found(conn, "no account with that e-mail")

  defp deny(conn, :already_member),
    do:
      conflict(
        conn,
        "already_member",
        "that principal already holds a seat — change its role instead of adding it again"
      )

  defp deny(conn, :last_owner),
    do:
      conflict(
        conn,
        "last_owner",
        "refused: this is the workspace's last owner — promote another member to owner first, " <>
          "otherwise the workspace would be left with nobody who can administer it"
      )

  defp deny(conn, :invalid_principal),
    do: unprocessable(conn, "principal must be an e-mail address or a principal id")

  defp deny(conn, :invalid_email),
    do: unprocessable(conn, "email must be a valid address")

  defp deny(conn, %Ecto.Changeset{} = changeset),
    do: unprocessable(conn, changeset_message(changeset))

  defp deny(conn, _other), do: unprocessable(conn, "could not complete the request")

  defp changeset_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc ->
        String.replace(acc, "%{#{k}}", to_string(v))
      end)
    end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end

  defp not_found(conn, message) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{code: "not_found", message: message}})
  end

  defp conflict(conn, code, message) do
    conn
    |> put_status(:conflict)
    |> json(%{error: %{code: code, message: message}})
  end

  defp unprocessable(conn, message) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "unprocessable", message: message}})
  end

  defp unresolved_workspace(conn),
    do: unprocessable(conn, "workspace could not be resolved")
end
