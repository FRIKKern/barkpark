defmodule BarkparkWeb.SearchChannelDatasetBoundTest do
  @moduledoc """
  The search channel joins `search:<ws>:<proj>:<dataset>`. The socket sits
  below the router, so no token plug runs: the join checked workspace read and
  nothing else, and a token minted with an explicit dataset joined another
  dataset's topic and searched it (task-d94567a744dcc89d). The join now holds
  the binding, as the HTTP fence and `LiveScope` do.
  """
  use Barkpark.DataCase, async: false

  import Phoenix.ChannelTest
  import Barkpark.TenancyFixtures
  import Barkpark.RateLimiterSandbox

  alias Barkpark.{Auth, Content, Tenancy}
  alias Barkpark.Auth.ApiToken
  alias BarkparkWeb.{SearchChannel, UserSocket}

  @endpoint BarkparkWeb.Endpoint
  @own "bound-own"
  @prod "production"
  @reply_timeout 5_000

  setup :reset_rate_limiter!

  setup do
    n = System.unique_integer([:positive])
    ws = create_workspace!("sc-probe-ws-#{n}")
    proj = create_project!(ws, "sc-probe-proj")
    other = create_workspace!("sc-probe-other-#{n}")
    _ = create_project!(other, "sc-probe-proj")

    for ds <- [@own, @prod] do
      {:ok, _} = Tenancy.create_dataset(proj, %{slug: ds, name: ds})
      id = "scprobe-#{ds}"

      {:ok, _} =
        create_document_in!(
          ws,
          proj,
          "post",
          %{"doc_id" => id, "title" => "Scprobemarker #{ds}"},
          ds
        )

      {:ok, _} =
        Content.publish_document(id, "post", ds, workspace_id: ws.id, project_id: proj.id)
    end

    %{ws: ws, proj: proj, other: other}
  end

  defp token!(ws, kind) do
    raw = "sc-probe-#{kind}-" <> Ecto.UUID.generate()
    opts = if kind == :bound, do: [dataset_bound: true], else: []

    {:ok, token} =
      Auth.create_token(raw, "probe #{kind}", @own, ["read", "write", "admin"], ws.id, opts)

    token
  end

  # Join `dataset`'s topic as `token`, run the marker query, return what came back.
  defp attempt(token, ws, proj, dataset) do
    socket =
      socket(UserSocket, "probe-#{System.unique_integer([:positive])}", %{api_token: token})

    case Phoenix.ChannelTest.join(
           socket,
           SearchChannel,
           "search:#{ws.slug}:#{proj.slug}:#{dataset}"
         ) do
      {:ok, _reply, joined} ->
        ref =
          push(joined, "query", %{
            "q" => "scprobemarker",
            "seq" => 1,
            "engine" => "postgres",
            "types" => "post"
          })

        assert_reply ref, status, reply, @reply_timeout

        ids =
          for d <- Map.get(reply, :documents, []), do: d[:_id] || d["_id"] || d[:id] || d["id"]

        Process.unlink(joined.channel_pid)
        close(joined)
        {:joined, status, Map.get(reply, :count), ids, Map.get(reply, :reason)}

      {:error, reason} ->
        {:refused, reason}
    end
  end

  test "a dataset-bound token is refused another dataset's topic, and admitted to its own",
       %{ws: ws, proj: proj} do
    bound = token!(ws, :bound)
    assert ApiToken.bound_dataset(bound) == @own

    assert {:refused, %{reason: "forbidden_dataset"}} = attempt(bound, ws, proj, @prod)
    assert {:joined, :ok, 1, ["scprobe-" <> @own], _} = attempt(bound, ws, proj, @own)
  end

  test "an unbound token still joins both; another workspace's token joins neither (controls)",
       %{ws: ws, proj: proj, other: other} do
    unbound = token!(ws, :unbound)
    foreign = token!(other, :unbound)

    for dataset <- [@prod, @own] do
      assert {:joined, :ok, 1, ["scprobe-" <> ^dataset], _} = attempt(unbound, ws, proj, dataset)
      assert {:refused, %{reason: "unauthorized"}} = attempt(foreign, ws, proj, dataset)
    end
  end
end
