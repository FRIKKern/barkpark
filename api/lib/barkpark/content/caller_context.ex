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

  @type t :: %__MODULE__{
          principal_type: principal(),
          user_id: binary() | nil,
          token_id: binary() | nil,
          roles: [String.t()],
          is_admin: boolean()
        }

  defstruct principal_type: :anonymous,
            user_id: nil,
            token_id: nil,
            roles: [],
            is_admin: false

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
  """
  @spec from_user(binary(), keyword()) :: t()
  def from_user(user_id, opts \\ []) when is_binary(user_id) do
    roles = Keyword.get(opts, :roles, [])

    %__MODULE__{
      principal_type: :user,
      user_id: user_id,
      roles: roles,
      is_admin: Keyword.get(opts, :is_admin, "admin" in roles or "owner" in roles)
    }
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
end
