defmodule Barkpark.Content.Papers.IdempotencyPortTest do
  @moduledoc """
  The port binding is LIVE, not decorative.

  `block_ops` reaches its dedup store through
  `Barkpark.Content.Papers.IdempotencyPort` so the kernel never names the
  `idempotency` feature. A port nothing actually calls would satisfy the
  Boundary gate and quietly leave the real call hard-wired, so these tests bind
  a recording implementation through application env and prove the write path
  went through IT.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.Papers.IdempotencyPort

  @dataset "production"

  defmodule RecordingPort do
    @moduledoc false
    @behaviour Barkpark.Content.Papers.IdempotencyPort

    # Delegates to the real store so behaviour is unchanged; the send/2 is the
    # witness that the call arrived here and not at a compile-time alias.
    @impl true
    def claim_exact(key_hash, scope) do
      send(self(), {:port_claim_exact, key_hash, scope})
      Barkpark.Idempotency.claim_exact(key_hash, scope)
    end

    @impl true
    def complete_exact(key_hash, scope, receipt) do
      send(self(), {:port_complete_exact, key_hash, scope})
      Barkpark.Idempotency.complete_exact(key_hash, scope, receipt)
    end
  end

  test "the default binding is the idempotency store" do
    assert Application.get_env(:barkpark, IdempotencyPort) == Barkpark.Idempotency
    assert IdempotencyPort.impl() == Barkpark.Idempotency
  end

  test "an unbound port raises rather than falling back" do
    previous = Application.get_env(:barkpark, IdempotencyPort)
    Application.delete_env(:barkpark, IdempotencyPort)
    on_exit(fn -> Application.put_env(:barkpark, IdempotencyPort, previous) end)

    assert_raise ArgumentError, ~r/no .*IdempotencyPort implementation bound/, fn ->
      IdempotencyPort.impl()
    end
  end

  describe "with a recording implementation bound" do
    setup do
      previous = Application.get_env(:barkpark, IdempotencyPort)
      Application.put_env(:barkpark, IdempotencyPort, RecordingPort)
      on_exit(fn -> Application.put_env(:barkpark, IdempotencyPort, previous) end)
      :ok
    end

    test "the block-op write path claims and completes through the bound implementation" do
      {slug, paper} = seed_paper!()
      request_id = Ecto.UUID.generate()
      if_rev = paper.content["rev"] || 0

      ops = [%{"op" => "patch-block", "id" => "anchor", "patch" => %{"text" => "Ported"}}]

      assert {:ok, receipt, :applied} =
               Content.apply_paper_block_ops_once(
                 slug,
                 ops,
                 @dataset,
                 request_id,
                 "user:port",
                 if_rev: if_rev
               )

      assert_received {:port_claim_exact, key_hash, scope}
      assert_received {:port_complete_exact, ^key_hash, ^scope}
      assert String.starts_with?(scope, "paper_ops:v1:")

      stored = Content.get_paper(slug)
      assert stored.content["rev"] == receipt.rev
      assert Enum.find(stored.content["blocks"], &(&1["id"] == "anchor"))["text"] == "Ported"
    end

    test "a replayed retry resolves through the bound implementation too" do
      {slug, paper} = seed_paper!()
      request_id = Ecto.UUID.generate()
      if_rev = paper.content["rev"] || 0
      ops = [%{"op" => "patch-block", "id" => "anchor", "patch" => %{"text" => "Once"}}]

      assert {:ok, receipt, :applied} =
               Content.apply_paper_block_ops_once(
                 slug,
                 ops,
                 @dataset,
                 request_id,
                 "user:port-replay",
                 if_rev: if_rev
               )

      assert_received {:port_claim_exact, _, _}
      assert_received {:port_complete_exact, _, _}

      assert {:ok, ^receipt, :replayed} =
               Content.apply_paper_block_ops_once(
                 slug,
                 ops,
                 @dataset,
                 request_id,
                 "user:port-replay",
                 if_rev: if_rev
               )

      assert_received {:port_claim_exact, _, _}
      refute_received {:port_complete_exact, _, _}
    end
  end

  defp seed_paper!(slug \\ nil) do
    slug = slug || "paper-port-#{System.unique_integer([:positive])}"

    attrs =
      Barkpark.LabelFixtures.paper_attrs(%{
        slug: slug,
        blocks: [%{"id" => "anchor", "type" => "paragraph", "text" => "Seed"}]
      })

    {:ok, paper} = Content.upsert_paper(attrs)
    {slug, paper}
  end
end
