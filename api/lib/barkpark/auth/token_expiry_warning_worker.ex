defmodule Barkpark.Auth.TokenExpiryWarningWorker do
  @moduledoc """
  Emails a warning 14, 7 and 1 days before an API token's `expires_at`, once
  per step. The instance-side port of the Cloud control plane's
  `BarkparkCloud.Workers.TokenExpiryWarningWorker`, so a self-hosted instance
  warns without Cloud.

  Runs daily from the static Oban crontab. Each live token whose `expires_at`
  is within 14 days is due at the smallest step that still covers it: a token
  10 days out is due the 14-day warning, one 5 days out the 7-day warning. A
  token minted 5 days before expiry therefore gets the 7-day and the 1-day
  warnings, not three mails on one day.

  Recipients are the owner and admin users of the token's workspace, plus the
  token's `owner_user` when it has one. These are the people who already see
  the token in `bp token ls`.

  `api_tokens.expiry_warned_days` records the last step sent. It is written
  only after at least one mail was delivered, so a failed send is retried the
  next day. The write is conditional (`IS NULL OR > step`), so two overlapping
  runs send at most one extra mail. Rotation sets 0 on the retiring token, so
  its grace window does not warn.

  SHIPS DISABLED. While `config :barkpark, :token_expiry_warnings,
  enabled: false` (the default; runtime switch
  `BARKPARK_TOKEN_EXPIRY_WARNINGS=on`) a tick reads and sends nothing.
  """
  use Oban.Worker, queue: :default, max_attempts: 3, unique: [period: 3600]

  import Ecto.Query

  require Logger

  alias Barkpark.Accounts.User
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Mailer
  alias Barkpark.Repo
  alias Barkpark.Tenancy.Members

  @steps [1, 7, 14]
  @day 86_400

  @doc "The warning steps, in days before `expires_at`."
  @spec steps() :: [pos_integer()]
  def steps, do: @steps

  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:barkpark, :token_expiry_warnings, []) |> Keyword.get(:enabled, false) ==
      true
  end

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if enabled?(),
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

    from(t in ApiToken,
      where:
        is_nil(t.revoked_at) and not is_nil(t.expires_at) and t.expires_at > ^now and
          t.expires_at <= ^horizon and
          (is_nil(t.expiry_warned_days) or t.expiry_warned_days > ^Enum.min(@steps))
    )
    |> Repo.all()
    |> Enum.reduce(%{warned: 0, failed: 0}, fn token, acc ->
      step = due_step(token.expires_at, now)

      if is_nil(token.expiry_warned_days) or token.expiry_warned_days > step,
        do: warn(acc, token, step),
        else: acc
    end)
  end

  # The smallest step that still covers the time left, in whole days rounded up.
  defp due_step(expires_at, now) do
    days_left = ceil(DateTime.diff(expires_at, now, :second) / @day)
    Enum.find(@steps, &(&1 >= days_left))
  end

  defp warn(acc, token, step) do
    results = for to <- recipients(token), do: Mailer.deliver_checked(mail(to, token, step))

    cond do
      results == [] ->
        acc

      Enum.member?(results, :ok) ->
        claim(token.id, step)
        %{acc | warned: acc.warned + 1}

      true ->
        Logger.warning(
          "token expiry warning for #{token.id} (#{step}d) not delivered: " <>
            inspect(Enum.uniq(results))
        )

        %{acc | failed: acc.failed + 1}
    end
  end

  defp claim(token_id, step) do
    from(t in ApiToken,
      where: t.id == ^token_id and (is_nil(t.expiry_warned_days) or t.expiry_warned_days > ^step)
    )
    |> Repo.update_all(set: [expiry_warned_days: step])
  end

  defp recipients(%ApiToken{} = token) do
    admins =
      if token.workspace_id,
        do:
          for(
            %{principal_type: "user", role: role, identity: email} <-
              Members.list_members(token.workspace_id),
            role in ["owner", "admin"] and is_binary(email),
            do: email
          ),
        else: []

    owner =
      case token.owner_user_id && Repo.get(User, token.owner_user_id) do
        %User{email: email} when is_binary(email) -> [email]
        _ -> []
      end

    Enum.uniq(owner ++ admins)
  end

  defp mail(to, %ApiToken{} = token, step) do
    name = token.name || token.label || token.id
    days = if step == 1, do: "1 day", else: "#{step} days"

    Swoosh.Email.new()
    |> Swoosh.Email.to(to)
    |> Swoosh.Email.from(Mailer.from())
    |> Swoosh.Email.subject("Barkpark API token \"#{name}\" expires in #{days}")
    |> Swoosh.Email.text_body("""
    The Barkpark API token "#{name}" (id #{token.id}) expires at #{DateTime.to_iso8601(token.expires_at)}.

    After that time every request made with it is refused. Before then, mint a
    replacement with `bp token create` and give it to whatever uses this token.

    You receive this because you own the token or administer its workspace.
    """)
  end
end
