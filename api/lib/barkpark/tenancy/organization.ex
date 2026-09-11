defmodule Barkpark.Tenancy.Organization do
  @moduledoc """
  A thin tier ABOVE the Workspace. An Organization groups one or more
  Workspaces so a single enterprise identity connection (SSO/SCIM, later
  waves) maps to a customer that may span several workspaces.

  The tier is additive: a Workspace's `organization_id` is nullable and no
  authorization path reads it yet. Organizations are the anchor future waves
  hang per-org SSO/SCIM connections and policies on.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @slug_format ~r/^[a-z0-9][a-z0-9-]*$/

  # era-bl-allowed-auth-methods: the CLOSED vocabulary of authentication
  # methods an org policy may name. One string per door a user can walk
  # through to mint a session, and the vocabulary is DERIVED FROM THE DOORS —
  # every term here has an enforcement point, and every local session-mint
  # site answers to exactly one term. An allow-list that named a door nobody
  # gated would be inert while reading as enforced.
  #
  #   password    POST /v1/auth/login, POST /login/account
  #   magic_link  POST /v1/auth/magic-login, GET /auth/magic/:token
  #   passkey     POST /v1/auth/webauthn/login
  #   sso         the ENTERPRISE identity callbacks: OIDC + SAML, each bound
  #               to a per-org connection (`c.organization_id`)
  #   social      consumer OAuth (Google / GitHub / Microsoft)
  #
  # `social` is DELIBERATELY not folded into `sso`, and the distinction is
  # load-bearing rather than cosmetic. `Sso.Social.handle_callback/3`
  # find-or-LINKS by email against a consumer provider with no org binding at
  # all — the social controller's own comment says "social login is
  # app-level, no org of its own". If social counted as `sso`, a member of an
  # `["sso"]` org could sign in with a personal Google account whose address
  # matches theirs and be treated as having satisfied the enterprise identity
  # policy. That is precisely the bypass this feature exists to close, so the
  # doors get separate names and an org that wants both writes both.
  #
  # A value outside this list is rejected at write time, so the column can
  # never hold a method no enforcement point knows about — a typo
  # ("passwrod") would otherwise silently disable a door nobody named.
  @auth_methods ~w(password magic_link passkey sso social)

  @doc "The closed vocabulary of `allowed_auth_methods` values."
  @spec auth_methods() :: [String.t()]
  def auth_methods, do: @auth_methods

  schema "organizations" do
    field :slug, :string
    field :name, :string

    # era-w2-org-require-mfa: when true, every user who is a member (via any
    # of this org's workspaces) must have an MFA factor enrolled before the
    # session-auth surface serves them. Opt-in; default false = no behaviour
    # change. Governing rule across orgs: ANY-org-requires → enforce.
    field :require_mfa, :boolean, default: false

    # era-w8-org-session-policy: org-wide session lifetime governance, in
    # seconds. NULL on either axis = no bound → byte-identical to the hardcoded
    # 30-day / no-idle default. `session_idle_timeout_seconds` logs out a session
    # idle past the window (measured from last activity); `session_absolute_
    # lifetime_seconds` logs one out once its age from birth reaches the bound.
    # Strictest-wins across a user's orgs (`Tenancy.org_session_policy_for_user/1`).
    field :session_idle_timeout_seconds, :integer
    field :session_absolute_lifetime_seconds, :integer

    # era-bl-allowed-auth-methods: org policy naming EXHAUSTIVELY which login
    # doors this org's members may use (values from `auth_methods/0`). NULL —
    # the default — means "no policy": every method stays open and the auth
    # surface is byte-identical to before the column existed. A non-NULL list
    # is an allow-list: a method absent from it is refused at the session-mint
    # chokepoint with `auth_method_not_allowed`. SSO-only is expressed as
    # `["sso"]` — which also closes the consumer-OAuth door, since `social` is
    # a separate term (see `@auth_methods`). Strictest-wins across a user's orgs = the INTERSECTION of the
    # non-NULL policies (`Tenancy.org_allowed_auth_methods_for_user/1`).
    field :allowed_auth_methods, {:array, :string}

    has_many :workspaces, Barkpark.Tenancy.Workspace

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def changeset(org, attrs) do
    org
    |> cast(attrs, [
      :slug,
      :name,
      :require_mfa,
      :session_idle_timeout_seconds,
      :session_absolute_lifetime_seconds,
      :allowed_auth_methods
    ])
    |> validate_required([:slug, :name])
    |> validate_length(:slug, min: 1, max: 63)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_format(:slug, @slug_format,
      message: "must be lowercase alphanumeric with hyphens"
    )
    |> validate_number(:session_idle_timeout_seconds, greater_than: 0)
    |> validate_number(:session_absolute_lifetime_seconds, greater_than: 0)
    |> validate_allowed_auth_methods()
    |> unique_constraint(:slug)
  end

  # NULL is the no-policy default and always valid. A present list must be
  # NON-EMPTY (an empty allow-list would lock every member out of every door
  # while reading as "policy set") and every member must come from the closed
  # vocabulary.
  defp validate_allowed_auth_methods(changeset) do
    case get_field(changeset, :allowed_auth_methods) do
      nil ->
        changeset

      [] ->
        add_error(changeset, :allowed_auth_methods, "must name at least one method")

      methods when is_list(methods) ->
        case Enum.reject(methods, &(&1 in @auth_methods)) do
          [] ->
            changeset

          unknown ->
            add_error(
              changeset,
              :allowed_auth_methods,
              "contains unknown method(s): #{Enum.join(unknown, ", ")}"
            )
        end

      _ ->
        add_error(changeset, :allowed_auth_methods, "must be a list of method names")
    end
  end
end
