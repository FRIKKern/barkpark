defmodule BarkparkWeb.SearchChannelArchivedWorkspaceTest do
  @moduledoc """
  Owner ruling #51, RQ10 (task-6132833921b7dc36): archiving a workspace is a
  read cutoff for the live search channel too.

  The HTTP routes answer an archived workspace 409 `workspace_archived`, but
  `SearchChannel` joined one and kept answering queries over an open socket.
  """
  use Barkpark.DataCase, async: false

  import Phoenix.ChannelTest
  import Barkpark.TenancyFixtures
  import Barkpark.RateLimiterSandbox

  alias Barkpark.{Auth, Tenancy}
  alias BarkparkWeb.UserSocket

  @endpoint BarkparkWeb.Endpoint
  @reply_timeout 5_000

  setup :reset_rate_limiter!

  setup do
    ws = create_workspace!("search-arch-ws-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "search-arch-proj")
    {:ok, _} = Tenancy.create_dataset(proj, %{slug: "test", name: "test"})

    raw = "search-arch-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "search-arch", "test", ["read"], ws.id)

    %{ws: ws, proj: proj, token: token, topic: "search:#{ws.slug}:#{proj.slug}:test"}
  end

  defp join_search(ctx) do
    Phoenix.ChannelTest.join(
      socket(UserSocket, "arch-id", %{api_token: ctx.token}),
      BarkparkWeb.SearchChannel,
      ctx.topic
    )
  end

  test "joining an archived workspace is refused, naming the archive", ctx do
    {:ok, _} = Tenancy.archive_workspace(ctx.ws)
    assert {:error, %{reason: "workspace_archived"}} = join_search(ctx)
  end

  test "a socket joined before the archive gets no more answers", ctx do
    {:ok, _reply, joined} = join_search(ctx)
    Process.unlink(joined.channel_pid)

    ref = push(joined, "query", %{"q" => "probe", "seq" => 1, "engine" => "postgres"})
    assert_reply ref, :ok, _before, @reply_timeout

    {:ok, _} = Tenancy.archive_workspace(ctx.ws)

    ref = push(joined, "query", %{"q" => "probe", "seq" => 2, "engine" => "postgres"})
    assert_reply ref, :error, %{reason: "workspace_archived"}, @reply_timeout
  end

  test "a live workspace joins and answers (control)", ctx do
    {:ok, _reply, joined} = join_search(ctx)
    ref = push(joined, "query", %{"q" => "probe", "seq" => 1, "engine" => "postgres"})
    assert_reply ref, :ok, _reply2, @reply_timeout
  end
end
