defmodule Barkpark.Sso.OidcSecretExpiryWarningWorker do
  @moduledoc """
  Emails a warning 30, 14 and 7 days before an OIDC connection's recorded
  `client_secret_expires_at`, once per step. Sign-ins through the connection
  stop on that date, so the operator rotates the secret before it.

  Runs daily from the static Oban crontab, next to
  `Barkpark.Auth.TokenExpiryWarningWorker`, and follows its rules. A connection
  is due at the smallest step that still covers the time left, so a date
  recorded 10 days out gets the 14-day and the 7-day warnings.

  Recipients are the instance operators on `BARKPARK_OPERATOR_EMAILS`, who run
  `bp org oidc-rotate-secret`, plus the owner and admin users of the
  organization's workspaces.

  `oidc_connections.client_secret_expiry_warned_days` records the last step
  sent. It is written only after at least one mail was delivered, so a failed
  send is retried the next day. A new expiry date clears it
  (`Barkpark.Sso.OidcConnection.changeset/2`).

  SHIPS DISABLED, behind the same switch as the token warnings: while
  `config :barkpark, :token_expiry_warnings, enabled: false` (the default;
  runtime switch `BARKPARK_TOKEN_EXPIRY_WARNINGS=on`) a tick reads and sends
  nothing.
  """
  use Oban.Worker, queue: :default, max_attempts: 3, unique: [period: 3600]

  import Ecto.Query

  require Logger

  alias Barkpark.Auth.TokenExpiryWarningWorker
  alias Barkpark.Mailer
  alias Barkpark.Repo
  alias Barkpark.Sso.OidcConnection
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Members

  @steps [7, 14, 30]
  @day 86_400

  @doc "The warning steps, in days before `client_secret_expires_at`."
  @spec steps() :: [pos_integer()]
  def steps, do: @steps

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if TokenExpiryWarningWorker.enabled?(),
      do: {:ok, run(DateTime.utc_now())},
      else: {:ok, %{skipped: :disabled}}
  end

  @doc """
  Scan once against `now` and return `%{warned: n, failed: n}`. Public so tests
  can drive it with a fixed clock.
  """
  @spec run(DateTime.t()) :: %{warned: non_neg_integer(), failed: non_neg_integer()}
  def run(%DateTime{} = now) do
    horizon = DateTime.add(now, Enum.max(@steps) * @day, :second)
    smallest = Enum.min(@steps)

    from(c in OidcConnection,
      where:
        c.active and not is_nil(c.client_secret_expires_at) and
          c.client_secret_expires_at > ^now and c.client_secret_expires_at <= ^horizon and
          (is_nil(c.client_secret_expiry_warned_days) or
             c.client_secret_expiry_warned_days > ^smallest),
      preload: [:organization]
    )
    |> Repo.all()
    |> Enum.reduce(%{warned: 0, failed: 0}, fn c, acc ->
      step = due_step(c.client_secret_expires_at, now)

      if is_nil(c.client_secret_expiry_warned_days) or c.client_secret_expiry_warned_days > step,
        do: warn(acc, c, step),
        else: acc
    end)
  end

  # The smallest step that still covers the time left, in whole days rounded up.
  defp due_step(expires_at, now) do
    days_left = ceil(DateTime.diff(expires_at, now, :second) / @day)
    Enum.find(@steps, &(&1 >= days_left))
  end

  defp warn(acc, c, step) do
    results = for to <- recipients(c), do: Mailer.deliver_checked(mail(to, c, step))

    cond do
      results == [] ->
        acc

      Enum.member?(results, :ok) ->
        claim(c.id, step)
        %{acc | warned: acc.warned + 1}

      true ->
        Logger.warning(
          "OIDC client secret expiry warning for #{c.organization.slug} (#{step}d) not delivered: " <>
            inspect(Enum.uniq(results))
        )

        %{acc | failed: acc.failed + 1}
    end
  end

  defp claim(id, step) do
    from(c in OidcConnection,
      where:
        c.id == ^id and
          (is_nil(c.client_secret_expiry_warned_days) or
             c.client_secret_expiry_warned_days > ^step)
    )
    |> Repo.update_all(set: [client_secret_expiry_warned_days: step])
  end

  defp recipients(%OidcConnection{organization_id: org_id}) do
    # The list `BarkparkWeb.Plugs.RequirePlatformOperator` reads.
    operators =
      for e <- List.wrap(Application.get_env(:barkpark, :operator_emails, [])),
          is_binary(e),
          e = e |> String.trim() |> String.downcase(),
          e != "",
          do: e

    admins =
      for ws <- Tenancy.workspaces_for_organization(org_id),
          %{principal_type: "user", role: role, identity: email} <- Members.list_members(ws.id),
          role in ["owner", "admin"] and is_binary(email),
          do: String.downcase(email)

    Enum.uniq(operators ++ admins)
  end

  defp mail(to, %OidcConnection{} = c, step) do
    slug = c.organization.slug

    Swoosh.Email.new()
    |> Swoosh.Email.to(to)
    |> Swoosh.Email.from(Mailer.from())
    |> Swoosh.Email.subject(
      "Barkpark sign-in for \"#{slug}\": the OIDC client secret expires in #{step} days"
    )
    |> Swoosh.Email.text_body("""
    The OIDC client secret of the organization "#{slug}" (client id #{c.client_id}) expires at #{DateTime.to_iso8601(c.client_secret_expires_at)}.

    After that time nobody can sign in through #{c.issuer}. Before then, create a
    new secret at the identity provider, keep the old one until the new one is
    stored, and store it with:

    bp org oidc-rotate-secret #{slug} "<new secret>" --client_secret_expires_at <new expiry>

    You receive this because you operate this Barkpark instance or administer a
    workspace of the organization.
    """)
  end
end
