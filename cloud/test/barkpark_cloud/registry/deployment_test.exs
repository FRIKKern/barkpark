defmodule BarkparkCloud.Registry.DeploymentTest do
  @moduledoc """
  Pure, no-DB unit test over the Deployment status transition graph — the
  from-status legality the fenced writers enforce before `Repo.update`.
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.Registry.Deployment

  describe "legal_transition?/2" do
    test "accepts every edge in the transition graph" do
      for {from, tos} <- Deployment.transitions(), to <- tos do
        assert Deployment.legal_transition?(from, to),
               "expected #{from} → #{to} to be legal"
      end
    end

    test "accepts a same-status write for every status (field-only updates)" do
      for status <- Deployment.statuses() do
        assert Deployment.legal_transition?(status, status)
      end
    end

    test "rejects resurrecting or skipping edges" do
      refute Deployment.legal_transition?("failed", "live")
      refute Deployment.legal_transition?("live", "building")
      refute Deployment.legal_transition?("cancelled", "pushing")
      refute Deployment.legal_transition?("queued", "live")
      refute Deployment.legal_transition?("queued", "pushing")
      refute Deployment.legal_transition?("building", "live")
    end

    test "terminal statuses have no outgoing (non-self) edges" do
      for terminal <- ~w(live failed cancelled) do
        assert Deployment.transitions()[terminal] == []

        for to <- Deployment.statuses(), to != terminal do
          refute Deployment.legal_transition?(terminal, to),
                 "expected terminal #{terminal} → #{to} to be illegal"
        end
      end
    end
  end
end
