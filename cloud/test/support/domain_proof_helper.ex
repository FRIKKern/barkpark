defmodule BarkparkCloud.DomainProofHelper do
  @moduledoc """
  Owner ruling #29 test seams for the `_barkpark-verify` TXT proof.

  `prove_every_domain/0` makes DNS (for THIS test process) publish every team's
  token for every domain — the state a real owner reaches once the record is
  live. Suites whose subject is NOT the proof (collision, ask-gate, format cap,
  audit) install it so their claims proceed exactly as before the ruling.

  `publish/2` publishes exactly the given values at one domain's record name;
  the proof suite uses it to drive each outcome.
  """
  import Ecto.Query

  alias BarkparkCloud.DomainOwnership
  alias BarkparkCloud.Registry.DomainVerification
  alias BarkparkCloud.Repo

  def prove_every_domain do
    DomainOwnership.put_txt_dns(fn name ->
      domain = name |> to_string() |> String.replace_prefix("_barkpark-verify.", "")

      {:ok,
       Repo.all(from v in DomainVerification, where: v.domain == ^domain, select: v.token)
       |> Enum.map(&DomainVerification.record_value/1)}
    end)
  end

  @doc "Publish exactly `values` at `_barkpark-verify.<domain>`; other names answer nothing."
  def publish(domain, values) when is_list(values) do
    DomainOwnership.put_txt_dns(fn name ->
      if to_string(name) == DomainVerification.record_name(domain),
        do: {:ok, values},
        else: {:ok, []}
    end)
  end

  @doc "The value that proves `team_id`'s claim on `domain` (minting its row if needed)."
  def value_for(team_id, domain) do
    {:ok, row} = BarkparkCloud.Registry.domain_verification(team_id, domain)
    DomainVerification.record_value(row.token)
  end
end
