defmodule BarkparkWeb.SearchChannelTokenLivenessTest do
  @moduledoc """
  Realtime authz sweep (r4a): an open search socket outlived its token.

  `UserSocket.connect/3` verifies the bearer once. Revocation reaches an open
  socket only through the teardown broadcast in `Auth.revoke_token/1`, and the
  channel's per-frame `reauthorize/1` asked membership only. Two paths revoke
  or end a token WITHOUT that broadcast and WITHOUT removing the token's own
  membership row:

    * `Barkpark.Scim` deprovision bulk-revokes the user's tokens with
      `Repo.update_all`;
    * a token simply EXPIRES.

  In both cases HTTP refused the token while the open socket kept answering
  `"query"` frames and pushing live results. The channel now re-checks the
  token row each frame, and the SCIM bulk revoke sends the teardown.
  """
  use Barkpark.DataCase, async: false

  import Phoenix.ChannelTest
  import Ecto.Query, only: [from: 2]
  import Barkpark.TenancyFixtures
  import Barkpark.RateLimiterSandbox

  alias Barkpark.{Auth, Repo, Tenancy}
  alias Barkpark.Auth.ApiToken
  alias BarkparkWeb.UserSocket

  @endpoint BarkparkWeb.Endpoint
  @reply_timeout 5_000

  setup :reset_rate_limiter!

  setup do
    ws = create_workspace!("search-live-ws-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "search-live-proj")
    {:ok, _} = Tenancy.create_dataset(proj, %{slug: "test", name: "test"})

    raw = "search-live-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "search-live", "test", ["read"], ws.id)

    {:ok, _reply, joined} =
      join(
        socket(UserSocket, "live-id", %{api_token: token}),
        BarkparkWeb.SearchChannel,
        "search:#{ws.slug}:#{proj.slug}:test"
      )

    Process.unlink(joined.channel_pid)

    ref = push(joined, "query", %{"q" => "liveprobe", "seq" => 1, "engine" => "postgres"})
    assert_reply ref, :ok, _before, @reply_timeout

    %{token: token, joined: joined}
  end

  defp refused?(joined, seq) do
    ref = push(joined, "query", %{"q" => "liveprobe", "seq" => seq, "engine" => "postgres"})

    receive do
      %Phoenix.Socket.Reply{ref: ^ref, status: :error} -> true
      %Phoenix.Socket.Reply{ref: ^ref, status: :ok} -> false
    after
      @reply_timeout -> true
    end
  end

  test "a token revoked by a bulk update (no teardown broadcast) gets no more answers", %{
    token: token,
    joined: joined
  } do
    # What Scim.revoke_owner_tokens/2 did: set revoked_at in bulk.
    Repo.update_all(from(t in ApiToken, where: t.id == ^token.id),
      set: [revoked_at: DateTime.utc_now() |> DateTime.truncate(:second)]
    )

    assert refused?(joined, 2), "a revoked token kept getting search answers over the socket"
  end

  test "an EXPIRED token gets no more answers", %{token: token, joined: joined} do
    Repo.update_all(from(t in ApiToken, where: t.id == ^token.id),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -60, :second)]
    )

    assert refused?(joined, 3), "an expired token kept getting search answers over the socket"
  end

  test "a live token keeps working (control)", %{joined: joined} do
    refute refused?(joined, 4)
  end

  test "SCIM deprovision broadcasts the socket teardown for the user's personal token" do
    {:ok, org} =
      Tenancy.create_organization(%{
        slug: "scim-td-#{System.unique_integer([:positive])}",
        name: "o"
      })

    {:ok, ws} =
      Tenancy.create_workspace(%{
        slug: "scim-td-ws-#{System.unique_integer([:positive])}",
        name: "w"
      })

    {:ok, ws} = Tenancy.assign_workspace_to_organization(ws, org.id)

    email = "scim-td-#{System.unique_integer([:positive])}@example.com"

    {:ok, user} =
      Barkpark.Accounts.register_user(%{email: email, password: "correct-horse-battery"})

    {:ok, _} = Tenancy.Auth.create_membership(ws.id, user.id, "member", "user")

    {:ok, {_raw, pat}} =
      Auth.create_personal_access_token("device", ["read"],
        role: "member",
        workspace_id: ws.id,
        owner_user_id: user.id
      )

    topic = UserSocket.disconnect_topic(pat.id)
    Phoenix.PubSub.subscribe(Barkpark.PubSub, topic)

    Barkpark.Scim.deprovision_user(org, user)

    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, @reply_timeout
  end
end
