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
  alias BarkparkWeb.ErrorResponse

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

  @doc "`GET /w/:ws/p/:proj/v1/invitations` — pending invitations (owner ruling #7)."
  def invitations(conn, _params) do
    case conn.assigns[:current_workspace] do
      %{id: ws_id} -> json(conn, %{invitations: Members.list_invitations(ws_id)})
      _ -> unresolved_workspace(conn)
    end
  end

  @doc "`DELETE /w/:ws/p/:proj/v1/invitations/:id` — withdraw a pending invitation."
  def cancel_invitation(conn, %{"id" => id}) do
    with %{id: ws_id} <- conn.assigns[:current_workspace],
         {:ok, invitation} <- Members.cancel_invitation(ws_id, id) do
      json(conn, %{withdrawn: invitation})
    else
      {:error, :not_found} -> not_found(conn, "no such invitation in this workspace")
      _ -> unresolved_workspace(conn)
    end
  end

  @doc """
  `POST /w/:ws/p/:proj/v1/members` — seat a human.

  Body: `{"email": "person@example.com", "role": "member|admin|owner|<custom>"}`.
  `role` defaults to `member`; the membership changeset validates it against
  the built-ins plus this workspace's custom roles.

  An EXISTING, confirmed account is not seated at once (owner ruling #7): the
  answer is `202 {"invitation": …}` and the seat appears when the user
  accepts (`POST /v1/auth/invitations/:id/accept`). A new e-mail is seated
  directly (`201 {"member": …}`), as before.
  """
  def create(conn, params) do
    with %{id: ws_id} <- conn.assigns[:current_workspace],
         {:ok, email} <- fetch_string(params, "email", :missing_email),
         role <- Map.get(params, "role", @default_role) do
      case Members.add_user_member(ws_id, email, to_string(role), actor: caller(conn)) do
        {:ok, {:invited, invitation}} ->
          conn |> put_status(:accepted) |> json(%{invitation: invitation})

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
      case Members.update_role(ws_id, principal, role, actor: caller(conn)) do
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
  # ANCHORED DELETE/REVOKE ROW — EDITING THIS BODY REDS A GATE IN scripts/.
  # This action is a NARROW row in @exclusion_anchors
  # (scripts/pds-elixir-receipt-census.exs). Any edit inside these clauses, a
  # `mix format` reflow included, moves its def fingerprint and fails
  # EXCLUSION-ANCHORS-FRESH. Re-derive IN THE SAME COMMIT, READING the three
  # values out of the STDOUT of
  #   elixir scripts/pds-elixir-receipt-census.exs --exclusion-keys
  # and never typing them from a log. Editing that register is a DECLARED
  # allowed cross-fence edit for the lane that moved it — the ruling, its
  # limits and the steps: docs/ops/exclusion-anchor-rederive.md
  def delete(conn, %{"principal_ref" => ref} = params) do
    with %{id: ws_id} <- conn.assigns[:current_workspace],
         {:ok, principal} <- Members.resolve_principal(ref, principal_type(params)) do
      case Members.remove_member(ws_id, principal, actor: caller(conn)) do
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
      now = DateTime.utc_now()

      tokens =
        ws_id
        |> Members.list_workspace_tokens(limit: limit, offset: offset)
        |> Enum.map(&put_rotation_facts(&1, now))

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
  # ANCHORED DELETE/REVOKE ROW — EDITING THIS BODY REDS A GATE IN scripts/.
  # This action is a NARROW row in @exclusion_anchors
  # (scripts/pds-elixir-receipt-census.exs). Any edit inside these clauses, a
  # `mix format` reflow included, moves its def fingerprint and fails
  # EXCLUSION-ANCHORS-FRESH. Re-derive IN THE SAME COMMIT, READING the three
  # values out of the STDOUT of
  #   elixir scripts/pds-elixir-receipt-census.exs --exclusion-keys
  # and never typing them from a log. Editing that register is a DECLARED
  # allowed cross-fence edit for the lane that moved it — the ruling, its
  # limits and the steps: docs/ops/exclusion-anchor-rederive.md
  def revoke_token(conn, %{"id" => token_id}) do
    with %{id: ws_id} <- conn.assigns[:current_workspace],
         true <- Members.token_member?(ws_id, token_id),
         :ok <-
           Auth.revoke_within_ceiling(
             token_id,
             conn.assigns[:api_token] || conn.assigns[:current_user]
           ),
         {:ok, token} <- Auth.revoke_token(token_id) do
      json(conn, %{revoked: %{id: token.id, label: token.label, revoked_at: token.revoked_at}})
    else
      false ->
        not_found(conn, "no token with that id holds a seat in this workspace")

      {:error, :not_found} ->
        not_found(conn, "no token with that id holds a seat in this workspace")

      {:error, :forbidden} ->
        conn
        |> ErrorResponse.emit_fields(:forbidden, %{
          code: "forbidden",
          message:
            "this token also holds a seat in a workspace you do not administer, and a " <>
              "revoke kills it everywhere; remove its seat here instead"
        })

      {:error, _} ->
        unprocessable(conn, "could not revoke token")

      _ ->
        unresolved_workspace(conn)
    end
  end

  @doc """
  `POST /w/:ws/p/:proj/v1/tokens/:id/rotate` — mint a successor for a token
  that holds a seat here and put the old one on a grace clock.

  Body/query: `grace_seconds` (default #{Auth.rotation_default_grace()}; `0`
  revokes the old token now; max #{Auth.rotation_max_grace()}). Nothing else
  is read — the successor copies the old token, so no permission or scope can
  be requested.

  Same gate as `revoke_token/2`: the `:scoped_admin` pipeline, then the token
  must hold a seat in THIS workspace (404 otherwise). `Auth.rotate_token/3`
  adds the ceilings a secret-returning verb needs (403). 409 for a revoked,
  expired or non-api token. 201 carries the new secret ONCE, in the same shape
  as the mint (`TokenController.create/2`).
  """
  def rotate_token(conn, %{"id" => token_id} = params) do
    with %{id: ws_id, slug: ws_slug} <- conn.assigns[:current_workspace],
         {:ok, grace} <- fetch_grace(params),
         true <- Members.token_member?(ws_id, token_id),
         {:ok, {raw, successor, old}} <-
           Auth.rotate_token(token_id, conn.assigns.api_token,
             grace_seconds: grace,
             workspace_id: ws_id,
             force: Map.get(params, "force") in [true, "true", "1"]
           ) do
      conn
      |> put_status(:created)
      |> json(%{
        token: raw,
        id: successor.id,
        inserted_at: successor.inserted_at,
        label: successor.label,
        name: successor.name,
        kind: successor.kind,
        permissions: successor.permissions,
        dataset: successor.dataset,
        expires_at: successor.expires_at,
        workspace: ws_slug,
        rotated_from: %{id: old.id, expires_at: old.expires_at, revoked_at: old.revoked_at}
      })
    else
      false ->
        not_found(conn, "no token with that id holds a seat in this workspace")

      {:error, :not_found} ->
        not_found(conn, "no token with that id holds a seat in this workspace")

      {:error, :invalid_grace} ->
        unprocessable(
          conn,
          "give ONE of grace_seconds (integer), grace (90s / 30m / 24h / 7d) or now=true; " <>
            "the grace must be from 0 to #{Auth.rotation_max_grace()} seconds"
        )

      {:error, :not_rotatable} ->
        conflict(conn, "conflict", "token is revoked, expired, or not an api token")

      {:error, :cloud_held_credential} ->
        ErrorResponse.emit_fields(conn, :conflict, %{
          code: "conflict",
          reason: "cloud_held_credential",
          message:
            "this token is the admin credential Barkpark Cloud stores for this instance " <>
              "(label \"#{Auth.cloud_admin_label()}\"); rotating it leaves Cloud with a " <>
              "secret that stops working when the grace window ends",
          hint:
            "Mint a separate admin token instead: `bp instance admin-token <instance-id> " <>
              "--install` (or `bp token create --permissions read,write,admin` with an admin " <>
              "token). To rotate this one anyway, pass --force."
        })

      {:error, :forbidden} ->
        conn
        |> ErrorResponse.emit_fields(:forbidden, %{
          code: "forbidden",
          message:
            "rotating would hand you a secret wider than your own: the token carries a " <>
              "permission your token lacks, or a seat in a workspace you do not administer"
        })

      {:error, _} ->
        unprocessable(conn, "could not rotate token")

      _ ->
        unresolved_workspace(conn)
    end
  end

  # Three spellings of ONE knob, and at most one may be given
  # (task-eaaf13ab768f34f6 criterion 1 — `bp token rotate --grace 2h` / `--now`):
  #
  #   * `grace_seconds` — the original integer (kept: scripts already send it);
  #   * `grace` — a duration with a unit, `90s` / `30m` / `24h` / `7d`, or a bare
  #     integer read as seconds;
  #   * `now=true` — revoke the old token immediately (grace 0).
  #
  # Two of them together is a 422 rather than a silent precedence: `--now
  # --grace 24h` is a contradiction, and picking either answer would rotate a
  # credential on a guess. The range check (0..max) stays in `Auth.rotate_token/3`.
  defp fetch_grace(params) do
    given =
      [
        {"grace_seconds", Map.get(params, "grace_seconds")},
        {"grace", Map.get(params, "grace")},
        {"now", Map.get(params, "now")}
      ]
      |> Enum.reject(fn {_k, v} -> v in [nil, "", false, "false"] end)

    case given do
      [] -> {:ok, Auth.rotation_default_grace()}
      [{"grace_seconds", n}] when is_integer(n) -> {:ok, n}
      [{"grace_seconds", s}] when is_binary(s) -> parse_grace(Integer.parse(s))
      [{"grace", d}] when is_binary(d) -> parse_duration(String.trim(d))
      [{"grace", n}] when is_integer(n) -> {:ok, n}
      [{"now", v}] when v in [true, "true", "1"] -> {:ok, 0}
      _ -> {:error, :invalid_grace}
    end
  end

  defp parse_grace({n, ""}), do: {:ok, n}
  defp parse_grace(_), do: {:error, :invalid_grace}

  @duration_units %{"s" => 1, "m" => 60, "h" => 3600, "d" => 86_400}

  defp parse_duration(d) do
    case Regex.run(~r/\A(\d+)([smhd]?)\z/, d) do
      [_, n, ""] -> {:ok, String.to_integer(n)}
      [_, n, unit] -> {:ok, String.to_integer(n) * Map.fetch!(@duration_units, unit)}
      _ -> {:error, :invalid_grace}
    end
  end

  # The rotation facts `bp token ls` shows (task-eaaf13ab768f34f6 criterion 1).
  # DERIVED here from columns the row already carries, never stored:
  #
  #   * `age_days` — whole days since the token was minted;
  #   * `rotation_due_at` — when it must be rotated: its own `expires_at` when it
  #     has one, else mint time + its class's max age
  #     (`Auth.TokenExpiry.max_age_days/1`, 365d for api and share tokens), else
  #     nil (a class with no max). Most live tokens predate per-kind expiry and
  #     carry no `expires_at`; for them this is the policy date, not a deadline
  #     the server enforces — that is what makes it a DUE date;
  #   * `rotation_overdue` — `rotation_due_at` is in the past.
  #
  # `last_used_at` is already on the row. A revoked token is not due for anything.
  defp put_rotation_facts(%{inserted_at: %{} = minted} = t, now) do
    due = rotation_due_at(t, minted)

    Map.merge(t, %{
      age_days: div(max(DateTime.diff(now, to_utc(minted), :second), 0), 86_400),
      rotation_due_at: due,
      rotation_overdue: not is_nil(due) and DateTime.compare(due, now) == :lt
    })
  end

  defp put_rotation_facts(t, _now), do: t

  defp rotation_due_at(%{revoked_at: %{}}, _minted), do: nil
  defp rotation_due_at(%{expires_at: %{} = exp}, _minted), do: to_utc(exp)

  defp rotation_due_at(t, minted) do
    class = Barkpark.Auth.TokenExpiry.class_for_permissions(Map.get(t, :permissions))

    case Barkpark.Auth.TokenExpiry.max_age_days(class) do
      nil -> nil
      days -> DateTime.add(to_utc(minted), days * 86_400, :second)
    end
  end

  defp to_utc(%DateTime{} = dt), do: dt
  defp to_utc(%NaiveDateTime{} = n), do: DateTime.from_naive!(n, "Etc/UTC")

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

  defp deny(conn, :already_invited),
    do:
      conflict(
        conn,
        "already_invited",
        "that person already has a pending invitation to this workspace"
      )

  # Owner ruling #5 (2026-10-03): the role ceiling.
  defp deny(conn, :owner_required),
    do:
      forbidden(
        conn,
        "owner_required",
        "only an owner of this workspace can grant, change or remove the owner role"
      )

  defp deny(conn, :role_exceeds_token),
    do:
      forbidden(
        conn,
        "role_exceeds_token",
        "this token lacks the admin permission, so its seat cannot hold a role with admin " <>
          "authority — mint a token with admin instead"
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
    |> ErrorResponse.emit_fields(:not_found, %{code: "not_found", message: message})
  end

  defp forbidden(conn, code, message) do
    conn
    |> ErrorResponse.emit_fields(:forbidden, %{code: code, message: message})
  end

  # The roster's caller: the bearer `:scoped_admin` proved holds an admin seat.
  defp caller(conn), do: conn.assigns[:api_token]

  defp conflict(conn, code, message) do
    conn
    |> ErrorResponse.emit_fields(:conflict, %{code: code, message: message})
  end

  defp unprocessable(conn, message) do
    conn
    |> ErrorResponse.emit_fields(:unprocessable_entity, %{code: "unprocessable", message: message})
  end

  defp unresolved_workspace(conn),
    do: unprocessable(conn, "workspace could not be resolved")
end
