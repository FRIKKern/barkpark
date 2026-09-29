defmodule BarkparkCloud.RegistryHostnameClaimsTableTest do
  @moduledoc """
  dr-w24-bl-hostname-claims-table-backstop — the `hostname_claims` table, in
  the sandbox. Proves the claim is written by BOTH doors (provisioning insert,
  custom_host attach), that the unique index refuses a url/custom_host
  collision with the SAME error shape each door's pre-check / url index already
  gives, that the ghost carve-out still reclaims, that deleting a barkpark
  releases its claims, and that the backfill SKIPS a pre-existing collision
  instead of raising.

  The real two-connection race lives in
  `registry_hostname_claims_race_test.exs`; the "pre-check bypassed" case below
  is its sandbox twin: a claim committed by a racer whose barkparks row the
  pre-check never saw.
  """
  use BarkparkCloud.DataCase, async: true

  import ExUnit.CaptureLog

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Registry.{Barkpark, HostnameClaim}

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp barkpark_fixture(team, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, bp} =
      Registry.register_barkpark(team, Enum.into(attrs, %{name: "BP #{n}", slug: "bp-#{n}"}))

    bp
  end

  defp claim(host), do: Repo.get_by(HostnameClaim, host: host)

  defp host(label), do: "#{label}-#{System.unique_integer([:positive])}.example.com"

  describe "both doors write the claim" do
    test "provisioning claims the url host, normalised; attach claims the custom host" do
      h = host("prov")
      bp = barkpark_fixture(team_fixture(), %{url: "  HTTPS://#{String.upcase(h)}/ "})

      assert %HostnameClaim{barkpark_id: id, kind: "url"} = claim(h)
      assert id == bp.id

      ch = host("attach")
      assert {:ok, _} = Registry.set_custom_host(bp, ch)
      assert %HostnameClaim{barkpark_id: ^id, kind: "custom_host"} = claim(ch)
    end

    test "deleting the barkpark releases every claim it held (same statement: FK cascade)" do
      h = host("gone")
      ch = host("gone-ch")
      bp = barkpark_fixture(team_fixture(), %{url: "https://" <> h})
      {:ok, bp} = Registry.set_custom_host(bp, ch)

      assert claim(h) && claim(ch)
      assert {:ok, _} = Registry.delete_barkpark(bp)
      refute claim(h)
      refute claim(ch)

      # and the name is free again for the next door
      other = barkpark_fixture(team_fixture())
      assert {:ok, %Barkpark{custom_host: ^h}} = Registry.set_custom_host(other, h)
    end

    test "attaching the host the row already serves as its url is still allowed" do
      h = host("self")
      bp = barkpark_fixture(team_fixture(), %{url: "https://" <> h})

      assert {:ok, %Barkpark{custom_host: ^h}} = Registry.set_custom_host(bp, h)
      assert {:ok, %Barkpark{custom_host: ^h}} = Registry.set_custom_host(bp, h)
      assert %HostnameClaim{kind: "custom_host"} = claim(h)
    end
  end

  describe "the database refuses the collision" do
    test "attach: a claim the pre-check cannot see (lost race) answers the SAME {:error, :taken}" do
      h = host("raced")
      racer = barkpark_fixture(team_fixture())
      attacher = barkpark_fixture(team_fixture())

      # The state a concurrent provisioner leaves between the attacher's
      # pre-check and its write: its url-host claim is committed, but no
      # barkparks column the pre-check walks names `h`. So the friendly
      # pre-check answers "free", and only the claims table can refuse.
      Repo.insert!(%HostnameClaim{host: h, barkpark_id: racer.id, kind: "url"})
      refute Registry.provisioning_fqdn_claim(h) != :free

      assert {:error, :taken} = Registry.set_custom_host(attacher, h)
      assert Repo.get!(Barkpark, attacher.id).custom_host == nil
      assert %HostnameClaim{barkpark_id: holder} = claim(h)
      assert holder == racer.id
    end

    test "provisioning: a url host another row serves as custom_host is refused with the url-index error" do
      h = host("taken-ch")
      holder = barkpark_fixture(team_fixture())
      {:ok, _} = Registry.set_custom_host(holder, h)

      team = team_fixture()

      assert {:error, %Ecto.Changeset{} = cs} =
               Registry.register_barkpark(team, %{
                 name: "X",
                 slug: "x-#{System.unique_integer([:positive])}",
                 url: "https://" <> h
               })

      assert {"is already provisioned", opts} = cs.errors[:url]
      assert opts[:constraint] == :unique
      # the refused row was not left behind
      refute Repo.exists?(from(b in Barkpark, where: b.team_id == ^team.id))
    end

    test "go-live: a clean label someone serves as custom_host falls back to the suffixed FQDN" do
      slug = "clean#{System.unique_integer([:positive])}"
      clean = slug <> "." <> Barkpark.base_domain()
      holder = barkpark_fixture(team_fixture())
      {:ok, _} = Registry.set_custom_host(holder, clean)

      team = team_fixture()
      assert {:ok, bp} = Registry.register_managed_barkpark(team, "Clean", slug)
      assert bp.url != "https://" <> clean
      assert bp.url == Barkpark.provisioning_url({slug, team.id})
      assert %HostnameClaim{kind: "custom_host", barkpark_id: hid} = claim(clean)
      assert hid == holder.id
    end
  end

  describe "the abandoned-row carve-out still reclaims" do
    test "a ghost's url claim is taken over by an attach the pre-check allows" do
      h = host("ghost")
      ghost = barkpark_fixture(team_fixture(), %{url: "https://" <> h})

      ghost
      |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(), -30, :day))
      |> Repo.update!()

      assert :free = Registry.provisioning_fqdn_claim(h)

      claimer = barkpark_fixture(team_fixture())
      assert {:ok, %Barkpark{custom_host: ^h}} = Registry.set_custom_host(claimer, h)
      assert %HostnameClaim{kind: "custom_host", barkpark_id: id} = claim(h)
      assert id == claimer.id
    end

    test "a YOUNG row's url claim is not taken over" do
      h = host("young")
      _young = barkpark_fixture(team_fixture(), %{url: "https://" <> h})
      claimer = barkpark_fixture(team_fixture())
      assert {:error, :taken} = Registry.set_custom_host(claimer, h)
    end
  end

  describe "backfill_hostname_claims/1" do
    test "a pre-existing url/custom_host duplicate is SKIPPED and reported, never raised" do
      h = host("dup")
      team = team_fixture()
      ghost = barkpark_fixture(team)
      live = barkpark_fixture(team)

      # Pre-table state: both columns written around the claims (as every row
      # written before this migration was), colliding across rows.
      ghost |> Ecto.Changeset.change(url: "https://#{h}.") |> Repo.update!()
      live |> Ecto.Changeset.change(custom_host: h) |> Repo.update!()
      Repo.delete_all(HostnameClaim)

      log =
        capture_log(fn ->
          assert %{skipped: skipped} = Registry.backfill_hostname_claims(Repo)
          send(self(), {:skipped, skipped})
        end)

      assert_received {:skipped, skipped}
      ghost_id = ghost.id
      live_id = live.id

      assert [
               %{
                 host: ^h,
                 kind: "url",
                 barkpark_id: ^ghost_id,
                 held_by: ^live_id,
                 held_as: "custom_host"
               }
             ] =
               Enum.filter(skipped, &(&1.host == h))

      assert log =~ "SKIPPED pre-existing collision on #{h}"
      # the customer's custom_host holds the name; the rows are untouched
      assert %HostnameClaim{barkpark_id: ^live_id, kind: "custom_host"} = claim(h)
      assert Repo.get!(Barkpark, ghost.id).url == "https://#{h}."

      # idempotent: a second run claims nothing new and re-reports the skip
      capture_log(fn ->
        assert %{claimed: 0, skipped: again} = Registry.backfill_hostname_claims(Repo)
        assert Enum.any?(again, &(&1.host == h))
      end)
    end
  end
end
