defmodule BarkparkCloud.Notifications.ChannelUrlSsrfFenceTest do
  @moduledoc """
  THE SSRF FENCE COVERS EVERY URL-BEARING CHANNEL TYPE, NOT THE LITERAL "webhook".

  `discord`, `slack` and `webhook` all carry the same plaintext credential map —
  `%{"url" => "https://…"}` — per `ChannelConfig`'s own moduledoc. Both fences
  used to be spelled for the string "webhook" alone, so a team admin could seal
  `http://169.254.169.254/latest/meta-data/` under `type: "slack"` and the control
  plane would POST to the cloud metadata endpoint on every routed event.

  THE SET IS DERIVED, NOT HAND-LISTED. The fences key on the credential SHAPE (a
  map carrying a binary `"url"`), so a sixth url-bearing channel type is covered
  the day it lands. This file proves that by iterating `ChannelConfig.types()` —
  add a type to that list and the save-fence case below runs against it with no
  edit here.

  NO DNS. Every URL in this file is an IP literal (`SafeUrl.check/1`
  short-circuits `:inet.parse_address/1` before it ever resolves), so this file
  never asks a third party's nameservers whether the repo may merge — the rule
  `safe_url_resolver_ratchet_test.exs` exists to protect. 203.0.113.0/24 is
  TEST-NET-3: a public range, so it is the BENIGN address here.
  """
  use BarkparkCloud.DataCase, async: true
  use Oban.Testing, repo: BarkparkCloud.Repo

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Notifications
  alias BarkparkCloud.Notifications.ChannelConfig
  alias BarkparkCloud.Notifications.FakeHttpClient
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.Workers.ChatNotificationWorker

  # The cloud metadata endpoint — SafeUrl names 169.254.0.0/16 explicitly.
  @metadata "http://169.254.169.254/latest/meta-data/"
  @benign "https://203.0.113.10/services/T0/B0/xxx"

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  describe "SAVE fence — put_channel/4" do
    test "a slack channel pointed at the cloud metadata endpoint is refused" do
      assert {:error, changeset} =
               Notifications.put_channel(team_fixture(), "slack", true, %{"url" => @metadata})

      assert ssrf_error?(changeset)
    end

    test "a discord channel pointed at the cloud metadata endpoint is refused" do
      assert {:error, changeset} =
               Notifications.put_channel(team_fixture(), "discord", true, %{"url" => @metadata})

      assert ssrf_error?(changeset)
    end

    test "the pre-existing webhook refusal still holds" do
      assert {:error, changeset} =
               Notifications.put_channel(team_fixture(), "webhook", true, %{"url" => @metadata})

      assert ssrf_error?(changeset)
    end

    test "the refusal names the TYPE the operator typed, not always \"webhook\"" do
      for type <- ~w(slack discord webhook) do
        {:error, changeset} =
          Notifications.put_channel(team_fixture(), type, true, %{"url" => @metadata})

        assert [channels: {message, _}] = changeset.errors
        assert message =~ type, "expected the #{type} refusal to name #{type}, got: #{message}"
      end
    end

    test "a benign public url still saves and still seals its plaintext" do
      team = team_fixture()

      assert {:ok, settings} =
               Notifications.put_channel(team, "slack", true, %{"url" => @benign})

      assert [chan] = settings.channels
      assert chan.enabled
      refute chan.credentials_encrypted =~ "203.0.113.10"
      assert {:ok, json} = Vault.decrypt(chan.credentials_encrypted)
      assert Jason.decode!(json) == %{"url" => @benign}
    end

    # THE DERIVATION. No hand list: whatever ChannelConfig declares, a credential
    # map carrying a metadata "url" must be refused for it. A NEW url-bearing type
    # cannot be added without a fence, because this case will red the day it lands
    # unfenced.
    test "EVERY type ChannelConfig declares refuses a metadata url credential" do
      for type <- ChannelConfig.types() do
        assert {:error, changeset} =
                 Notifications.put_channel(team_fixture(), type, true, %{"url" => @metadata}),
               "type #{type} accepted a %{\"url\" => metadata} credential"

        assert ssrf_error?(changeset), "type #{type} refused for the wrong reason"
      end
    end

    test "a credential map with no url is untouched by the fence" do
      team = team_fixture()

      assert {:ok, _} =
               Notifications.put_channel(team, "pushover", true, %{
                 "user_key" => "u",
                 "api_token" => "t"
               })
    end
  end

  describe "SEND fence — the DNS-rebind re-check" do
    for type <- ~w(slack discord webhook) do
      test "a saved-then-poisoned #{type} url is refused at send time" do
        type = unquote(type)
        team = team_fixture()
        {:ok, _} = Notifications.put_channel(team, type, true, %{"url" => @benign})
        poison_channel!(team, @metadata)

        FakeHttpClient.program([{:ok, %{status: 204}}])

        assert {:cancel, :ssrf_blocked} =
                 perform_job(ChatNotificationWorker, %{
                   "team_id" => team.id,
                   "channel_type" => type,
                   "event" => "provision_failed",
                   "payload" => %{"name" => "acme"}
                 })

        # The decisive assertion: NOTHING left the control plane.
        assert FakeHttpClient.requests() == []
      end
    end

    test "a benign saved url still delivers" do
      team = team_fixture()
      {:ok, _} = Notifications.put_channel(team, "slack", true, %{"url" => @benign})
      FakeHttpClient.program([{:ok, %{status: 204}}])

      assert :ok =
               perform_job(ChatNotificationWorker, %{
                 "team_id" => team.id,
                 "channel_type" => "slack",
                 "event" => "provision_failed",
                 "payload" => %{"name" => "acme"}
               })

      assert [req] = FakeHttpClient.requests()
      assert req.url == @benign
    end
  end

  # Rewrite the sealed credential straight on the row, bypassing put_channel — the
  # DNS-rebind analog: a url that passed the save fence now points somewhere else.
  defp poison_channel!(team, url) do
    settings = Notifications.get_or_create_settings(team)
    [chan] = settings.channels
    sealed = Vault.encrypt(Jason.encode!(%{"url" => url}))

    settings
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_embed(:channels, [
      Ecto.Changeset.change(chan, credentials_encrypted: sealed)
    ])
    |> Repo.update!()
  end

  defp ssrf_error?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {:channels, {_msg, opts}} ->
      Keyword.get(opts, :reason) == :ssrf_blocked
    end)
  end
end
