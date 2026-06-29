defmodule Mix.Tasks.BarkparkCloud.GrantForever do
  @moduledoc """
  Grant a Team the admin-only `forever` comp licence — a permanent entitlement
  that bypasses Stripe billing. The team can `go-live` and keep managed
  resources without an active paid subscription, indefinitely.

  ## Usage

      mix barkpark_cloud.grant_forever TEAM

  `TEAM` is a team id (UUID), a team slug, or an owner's email — whichever you
  have. Prints the resolved team + the resulting subscription on success.

  ## What it does

  Calls `BarkparkCloud.Billing.grant_forever/1`, which writes (or converts an
  existing live sub into) an `active` `forever` subscription row carrying no
  gateway ids. Idempotent — a team already on `forever` is a loud no-op.

  Caveat: if the team had a REAL paid Stripe subscription, this detaches our row
  only — cancel the Stripe-side subscription separately so they stop being charged.
  """
  @shortdoc "Grant a Team the admin-only `forever` comp licence (permanent entitlement)"

  use Mix.Task

  alias BarkparkCloud.{Accounts, Billing}

  @impl Mix.Task
  def run(args) do
    # Boot the app so the Repo (and its pool) is live — every data-touching task does this.
    Mix.Task.run("app.start")

    case args do
      [team_ref] ->
        do_grant(team_ref)

      _ ->
        Mix.shell().error(
          "Usage: mix barkpark_cloud.grant_forever TEAM   (team id | slug | owner email)"
        )

        exit({:shutdown, 1})
    end
  end

  @doc """
  Resolve `team_ref` (team id | slug | owner email) to a Team and grant it the
  `forever` comp. Public so a test can drive it against the sandbox repo without
  spawning a Mix process.
  """
  @spec grant_forever_for(String.t()) :: {:ok, term()} | {:error, :team_not_found | term()}
  def grant_forever_for(team_ref) when is_binary(team_ref) do
    case resolve_team(team_ref) do
      nil -> {:error, :team_not_found}
      team -> Billing.grant_forever(team)
    end
  end

  defp do_grant(team_ref) do
    case grant_forever_for(team_ref) do
      {:ok, :already_forever} ->
        Mix.shell().info(
          "Team #{inspect(team_ref)} is already on the `forever` comp — nothing to do."
        )

      {:ok, sub} ->
        Mix.shell().info("""
        Granted FOREVER comp licence:
          team_id: #{sub.team_id}
          plan:    #{sub.plan}
          status:  #{sub.status}
        """)

      {:error, :team_not_found} ->
        Mix.shell().error(
          "No team found for #{inspect(team_ref)} " <>
            "(tried email → owner's primary team, then slug, then id)."
        )

        exit({:shutdown, 1})

      {:error, reason} ->
        Mix.shell().error("Could not grant forever: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  # team_ref → Team: an "@" means an owner email (→ their primary team); a UUID
  # is a direct id lookup; anything else is treated as a team slug.
  defp resolve_team(ref) do
    cond do
      String.contains?(ref, "@") ->
        case Accounts.get_user_by_email(ref) do
          nil -> nil
          user -> Accounts.primary_team(user)
        end

      uuid?(ref) ->
        Accounts.get_team(ref)

      true ->
        Accounts.get_team_by_slug(ref)
    end
  end

  @uuid ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/
  defp uuid?(s), do: Regex.match?(@uuid, s)
end
