defmodule BarkparkCloud.RegistryCustomHostTest do
  @moduledoc """
  A custom host cannot steal a hostname another row already serves.

  A `url`-held provisioning FQDN and an attached `custom_host` occupy ONE
  hostname namespace, but the database cannot see across them: the two partial
  unique indexes (`barkparks_url_unique_idx`, `barkparks_custom_host_unique_idx`)
  are disjoint. `custom_host_taken?/2`'s url leg is therefore the only guard,
  and these tests pin its two halves:

    * ANOTHER row's url host is `:taken` — including when the stored origin is
      spelled differently (scheme, port, path, trailing dot, case) than the
      normalised candidate, which an exact `url == "https://" <> norm` match
      would read straight past.
    * a row may still attach a custom host matching its OWN url — the
      legitimate re-attach (re-running the DNS upsert after a repair) that the
      self-exclusion keeps working.

  Measured motivation (prod, 2026-08-08): `gyldendal.barkpark.cloud` is held by
  one team's row as its `url` AND by a different team's row as its
  `custom_host`, and the control plane has been posting the first team's
  decrypted admin bearer to the second team's server every ~15 minutes. This
  pre-check stops the NEXT one; it does not heal that row (see
  `dr-w24-bl-gyldendal-live-cross-tenant-escalation`).
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Registry.Barkpark

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp barkpark_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    bp
  end

  # A row that is live (phoned home) so the abandoned-ghost carve-out cannot
  # release its name claim, holding `host` as its provisioning FQDN.
  defp live_row_holding_url(url) do
    bp = barkpark_fixture(team_fixture())

    {:ok, bp} =
      bp
      |> Ecto.Changeset.change(url: url, last_seen_at: DateTime.utc_now())
      |> Repo.update()

    bp
  end

  describe "set_custom_host/2 vs a url-held FQDN" do
    test "a domain held as ANOTHER row's url is :taken" do
      _victim = live_row_holding_url("https://gyldendal.barkpark.cloud")

      thief = barkpark_fixture(team_fixture())

      assert {:error, :taken} = Registry.set_custom_host(thief, "gyldendal.barkpark.cloud")

      # And nothing was written: the pre-check refuses before Repo.update/1.
      assert Registry.get_barkpark(thief.id).custom_host == nil
    end

    test "the url host is matched NORMALISED, not string-equal to https://<host>" do
      # Every one of these stored origins means the same hostname. An exact
      # `url == "https://" <> norm` comparison sees only the first.
      #
      # EACH SPELLING GETS ITS OWN HOSTNAME, deliberately: reusing one host
      # would leave the plain `https://<host>` victim from the first iteration
      # standing, so every later assertion would pass on THAT row's claim even
      # if its own spelling normalised to nothing. Isolated, each variant has to
      # hold the name by itself.
      variants = [
        {"plain https", fn h -> "https://" <> h end},
        {"http scheme", fn h -> "http://" <> h end},
        {"mixed case", fn h -> "https://" <> String.upcase(h) end},
        {"trailing dot", fn h -> "https://" <> h <> "." end},
        {"explicit port", fn h -> "https://" <> h <> ":4000" end},
        {"path suffix", fn h -> "https://" <> h <> "/studio" end}
      ]

      for {{label, spell}, i} <- Enum.with_index(variants) do
        host = "occupied#{i}.barkpark.cloud"
        stored = spell.(host)
        _victim = live_row_holding_url(stored)
        thief = barkpark_fixture(team_fixture())

        assert {:error, :taken} = Registry.set_custom_host(thief, host),
               "#{label}: stored url #{stored} did not hold #{host}"
      end
    end

    test "a row may still attach a custom host matching its OWN url (legitimate re-attach)" do
      mine = live_row_holding_url("https://mine.barkpark.cloud")

      assert {:ok, %Barkpark{custom_host: "mine.barkpark.cloud"}} =
               Registry.set_custom_host(mine, "mine.barkpark.cloud")

      assert Registry.get_barkpark(mine.id).custom_host == "mine.barkpark.cloud"

      # Re-running it (the DNS-repair re-attach) stays a no-op, not a conflict.
      assert {:ok, %Barkpark{custom_host: "mine.barkpark.cloud"}} =
               Registry.set_custom_host(mine, "mine.barkpark.cloud")
    end

    test "an unrelated hostname is still attachable" do
      _victim = live_row_holding_url("https://taken-host.barkpark.cloud")
      bp = barkpark_fixture(team_fixture())

      assert {:ok, %Barkpark{custom_host: "free-host.barkpark.cloud"}} =
               Registry.set_custom_host(bp, "free-host.barkpark.cloud")
    end
  end
end
