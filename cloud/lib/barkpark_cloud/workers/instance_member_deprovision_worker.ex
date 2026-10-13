defmodule BarkparkCloud.Workers.InstanceMemberDeprovisionWorker do
  @moduledoc """
  Owner ruling #26 (2026-10-03, "Match role, revoke"): removing a person from a
  team takes them OFF every instance that team owns.

  `Accounts.remove_member/2` evicts Cloud sessions and PATs inside its own
  transaction, and enqueues THIS job in the same transaction (so the job exists
  exactly when the removal committed). The job then asks each live box, with
  the stored admin token, to sign the person out, drop their workspace seats and
  revoke the tokens they own there (`Registry.deprovision_instance_user/2` →
  `POST /v1/auth/cloud-users/deprovision`). A box that predates that route gets
  the app-token revoke at least (`DELETE /v1/auth/app-tokens {email}`), and the
  outcome says so.

  Args: `%{"team_id" => id, "email" => email}`. Idempotent per box (an unknown
  email is a no-op answer), so a retry re-asks every box safely. A box that did
  not ANSWER (transport error) makes the job return an error, and Oban retries
  with backoff; a box that answered with a refusal is logged and not retried
  into — the answer will not change.
  """
  use Oban.Worker, queue: :default, max_attempts: 8

  require Logger

  alias BarkparkCloud.{Accounts, Registry}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"team_id" => team_id, "email" => email}})
      when is_binary(team_id) and is_binary(email) do
    case Accounts.get_team(team_id) do
      nil ->
        :ok

      team ->
        results =
          team
          |> Registry.list_barkparks()
          |> Enum.filter(&(is_binary(&1.url) and &1.url != ""))
          |> Enum.map(fn bp -> {bp, Registry.deprovision_instance_user(bp, email)} end)

        Enum.each(results, fn {bp, result} ->
          Logger.info("member-deprovision: #{bp.slug} → #{inspect(redact(result))}")
        end)

        unreachable =
          for {bp, {:error, :instance_error}} <- results, do: bp.slug

        if unreachable == [],
          do: :ok,
          else: {:error, {:unreachable, unreachable}}
    end
  end

  def perform(%Oban.Job{}), do: {:discard, :bad_args}

  # Never log an email beside a result shape that could carry more than counts.
  defp redact({:ok, map}) when is_map(map), do: {:ok, Map.drop(map, ["email", :email])}
  defp redact(other), do: other
end
