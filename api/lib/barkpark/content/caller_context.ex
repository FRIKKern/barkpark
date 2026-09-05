defmodule Barkpark.Content.CallerContext do
  @moduledoc """
  Who is asking — the principal behind a content read or write.

  Threaded from the auth plugs (`conn.assigns`) into `Content` read/write opts
  and into `Barkpark.Content.Envelope.render/3`. It is the single source of
  truth for the two access decisions added in later phases:

    * **field-level visibility** (Phase 3) — may this caller see a `private` /
      `readable_by` field? (`Envelope.render`)
    * **row/ownership scoping** (Phase 4) — which documents may this caller read
      on an `owner_scoped` type? (`Content.Scope.scope_to_owner`)

  Defaults are deliberately the *most restrictive* safe baseline: an anonymous,
  non-admin principal with no user identity. The existing token-only world maps
  cleanly onto it — an admin token yields `is_admin: true` (and thus bypasses
  ownership scoping and sees private fields), a read/write token yields a
  non-admin context, and no token yields anonymous. So adopting this struct is a
  behavioural no-op until a schema opts into the new attributes.
  """

  @type principal :: :anonymous | :api_token | :user

  @typedoc """
  The ATTRIBUTION stamp — who to name on a record this caller writes.

  Deliberately separate from `:principal_type`. That field drives ACCESS
  decisions and its value set is closed (`:anonymous | :api_token | :user`);
  widening it would change how every existing matcher grades a caller. The
  attribution vocabulary is open and reader-shaped: a share-link visitor is
  `%{kind: "share"}` for the purpose of naming them on a revision while staying
  `:anonymous` for the purpose of deciding what they may see.
  """
  @type actor :: %{kind: String.t(), id: binary() | nil, label: String.t() | nil}

  @type t :: %__MODULE__{
          principal_type: principal(),
          user_id: binary() | nil,
          token_id: binary() | nil,
          roles: [String.t()],
          is_admin: boolean(),
          grants: [Barkpark.Access.Grant.t()],
          actor: actor() | nil
        }

  defstruct principal_type: :anonymous,
            user_id: nil,
            token_id: nil,
            roles: [],
            is_admin: false,
            grants: [],
            # Attribution only. Nil means "derive it from the principal" —
            # see `actor_stamp/1`. Nothing in the access path reads it.
            actor: nil

  @doc "The anonymous baseline — no principal, sees only public/unowned content."
  @spec anonymous() :: t()
  def anonymous, do: %__MODULE__{}

  @doc """
  Build a context from a verified `Barkpark.Auth.ApiToken`. An `admin`
  permission grants `is_admin: true` (full visibility + ownership bypass),
  preserving today's behaviour for admin tokens.
  """
  @spec from_token(map()) :: t()
  def from_token(%{id: id, permissions: perms}) when is_list(perms) do
    %__MODULE__{
      principal_type: :api_token,
      token_id: id,
      roles: perms,
      is_admin: "admin" in perms
    }
  end

  @doc """
  Build a context from a verified user session. `roles` are the user's
  workspace roles; an `owner`/`admin` workspace role (or a global flag) sets
  `is_admin`.

  ALSO folds in the user's ACTIVE access-grants
  (`Barkpark.Access.list_active_grants_for_grantee/1` — already active-filtered
  in-query: not revoked, not expired, single-use not spent). The grants ride
  into `Content` scope opts so the tenancy gate + row narrowing can honour each
  grant's `(scope, capabilities)`. Grants load ONCE per request here, which is
  the "expired grant → zero access mid-session" granularity: a grant that
  expires mid-session is gone on the next request's rebuild. Pass
  `grants: [...]` to override (used by tests); pass `load_grants: false` to skip
  the query entirely.
  """
  @spec from_user(binary(), keyword()) :: t()
  def from_user(user_id, opts \\ []) when is_binary(user_id) do
    roles = Keyword.get(opts, :roles, [])

    %__MODULE__{
      principal_type: :user,
      user_id: user_id,
      roles: roles,
      is_admin: Keyword.get(opts, :is_admin, "admin" in roles or "owner" in roles),
      grants: resolve_grants(user_id, opts)
    }
  end

  defp resolve_grants(user_id, opts) do
    cond do
      Keyword.has_key?(opts, :grants) ->
        Keyword.fetch!(opts, :grants)

      Keyword.get(opts, :load_grants, true) ->
        Barkpark.Access.list_active_grants_for_grantee(user_id)

      true ->
        []
    end
  end

  @doc """
  Pull a `CallerContext` from `conn.assigns` (works for a `Plug.Conn` or a
  `Phoenix.Socket` — anything carrying `:assigns`).

  Resolution order, most-to-least specific:

    1. a `:caller_context` already assigned (set by `RequireUserSession` for
       authenticated users) — used verbatim;
    2. otherwise an `:api_token` assigned by `OptionalToken`/`RequireToken` —
       derived via `from_token/1` so an **admin token yields `is_admin: true`**
       (the "admins see all" law);
    3. otherwise the anonymous baseline.
  """
  @spec from_conn(%{assigns: map()}) :: t()
  def from_conn(%{assigns: assigns}) do
    case {Map.get(assigns, :caller_context), Map.get(assigns, :api_token)} do
      {%__MODULE__{} = ctx, _} -> ctx
      {_, %{id: _, permissions: perms} = token} when is_list(perms) -> from_token(token)
      _ -> anonymous()
    end
  end

  @doc "Keyword opts for threading into `Content` read/write calls."
  @spec to_opts(t()) :: keyword()
  def to_opts(%__MODULE__{} = ctx) do
    [caller_context: ctx, user_id: ctx.user_id]
  end

  # ── attribution (edit-on-the-link slice 4) ──────────────────────────────────

  @doc """
  Attach an explicit attribution stamp. Purely additive: nothing in the access
  path reads `:actor`, so a context carrying one grades identically to the same
  context without one.

  Used by the paper reader, whose share-link visitor has a NAME to record
  (the share link's id) but must keep the anonymous access posture.
  """
  @spec with_actor(t(), actor() | nil) :: t()
  def with_actor(%__MODULE__{} = ctx, %{kind: kind} = actor) when is_binary(kind) do
    %{
      ctx
      | actor: %{
          kind: kind,
          id: Map.get(actor, :id),
          label: Map.get(actor, :label)
        }
    }
  end

  def with_actor(%__MODULE__{} = ctx, _actor), do: ctx

  @doc """
  The `(actor_kind, actor_id, actor_label)` triple to stamp on a record this
  caller writes.

  Prefers an explicit `:actor` (see `with_actor/2`); otherwise derives the
  triple from the principal, so a caller that never learned about attribution
  still records something honest. An anonymous principal yields
  `%{actor_kind: "anonymous", actor_id: nil, actor_label: nil}` — the log says
  "somebody unidentified", never nothing at all.
  """
  @spec actor_stamp(t() | nil) :: %{
          actor_kind: String.t(),
          actor_id: binary() | nil,
          actor_label: String.t() | nil
        }
  def actor_stamp(%__MODULE__{actor: %{kind: kind} = actor}) when is_binary(kind) do
    %{
      actor_kind: kind,
      actor_id: Map.get(actor, :id),
      actor_label: Map.get(actor, :label)
    }
  end

  def actor_stamp(%__MODULE__{principal_type: :user, user_id: id}),
    do: %{actor_kind: "user", actor_id: id, actor_label: nil}

  def actor_stamp(%__MODULE__{principal_type: :api_token, token_id: id}),
    do: %{actor_kind: "api_token", actor_id: id, actor_label: nil}

  def actor_stamp(%__MODULE__{}),
    do: %{actor_kind: "anonymous", actor_id: nil, actor_label: nil}

  def actor_stamp(_other),
    do: %{actor_kind: "anonymous", actor_id: nil, actor_label: nil}

  @doc """
  `actor_stamp/1` read off a keyword list that may carry a `:caller_context`.
  The shape every `Content` write path already receives.
  """
  @spec actor_stamp_from_opts(keyword()) :: %{
          actor_kind: String.t(),
          actor_id: binary() | nil,
          actor_label: String.t() | nil
        }
  def actor_stamp_from_opts(opts) when is_list(opts),
    do: opts |> Keyword.get(:caller_context) |> actor_stamp()
end
