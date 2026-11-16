defmodule BarkparkWeb.Plugs.RefuseDatasetBound do
  @moduledoc """
  Refuses a dataset-bound token on the workspace-level admin reads: the audit
  log, the member roster and its invitations, the token inventory, and run
  secrets (list, reveal and a secret's audit trail, on the flat and the scoped
  mount).

  A token minted with an explicit `dataset` (`ApiToken.dataset_bound?/1`) is
  held to that dataset for everything (docs/auth.md). These reads name no
  dataset: they answer for the whole workspace, or the whole instance, so a
  bound token has no business reading them. It gets 403 with the binding
  refusal every other surface gives (`code: "forbidden"`,
  `reason: "dataset_not_bound"`), and a hint that names the remedy.

  Controllers plug it per action, after the router's own gates, so a caller
  without the admin seat gets the answer it got before. Unbound tokens, user
  sessions and anonymous callers pass untouched.

  `refused?/1` is the predicate itself; the Studio Activity page asks it too,
  because it reads the same `Barkpark.Audit.Feed`.
  """

  @behaviour Plug

  alias Barkpark.Auth.ApiToken
  alias BarkparkWeb.ErrorResponse

  @message "this token is bound to one dataset and cannot read workspace admin lists"
  @hint "Audit, members, tokens and secrets answer for the whole workspace. Use a token minted without `dataset` (`bp token create --permissions admin` with no -d), or your account. `GET /v1/auth/token` shows the binding. Write and admin tokens minted by bp before 2026-11-13 are bound to production: mint a new one."

  @doc "True when this principal is a dataset-bound token, which these reads refuse."
  @spec refused?(term()) :: boolean()
  def refused?(principal), do: ApiToken.dataset_bound?(principal)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if refused?(conn.assigns[:api_token]),
      do: ErrorResponse.emit(conn, {:error, :forbidden_dataset}, @message, @hint),
      else: conn
  end
end
