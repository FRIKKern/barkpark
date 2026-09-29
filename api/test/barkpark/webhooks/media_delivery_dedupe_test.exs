defmodule Barkpark.Webhooks.MediaDeliveryDedupeTest do
  @moduledoc """
  asm-bl-media-delivery-event-id-dedup — media deliveries are deduped on a
  STABLE key derived from the media event's own identity, under the partial
  UNIQUE (dedupe_key) WHERE source_kind = 'media'.

  Every dedup assertion here is paired with a CONTROL that proves the key
  DISCRIMINATES: a guard that refuses everything is not a dedup.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Repo
  alias Barkpark.Webhooks
  alias Barkpark.Webhooks.Delivery

  @url "https://cdn.example.test/hook"

  # The body as `Media.Delivery.Events.build_payload/5` encodes it: note the
  # `timestamp`, which is re-stamped on every encode. A key derived from the body
  # BYTES would therefore never repeat — which is why the derivation reads the
  # three identity fields instead.
  defp body(opts \\ []) do
    Jason.encode!(%{
      "event" => Keyword.get(opts, :event, "media.processed"),
      "dataset" => Keyword.get(opts, :dataset, "production"),
      "media_file_id" => Keyword.get(opts, :file_id, "file-abc"),
      "filename" => "cat.png",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  defp snapshot(opts \\ []) do
    %{
      "url" => Keyword.get(opts, :url, @url),
      "secret" => "sek",
      "body" => body(opts)
    }
  end

  describe "key derivation is STABLE" do
    test "a re-encode of the same logical event derives the SAME key" do
      a = Webhooks.media_dedupe_key(snapshot())
      # Different wall-clock stamp inside the body, same logical event.
      b = Webhooks.media_dedupe_key(snapshot())

      assert is_binary(a)
      assert a == b
      # The proof that it is not a body hash: the bodies DIFFER.
      refute snapshot()["body"] == snapshot()["body"]
    end

    test "it discriminates on event, dataset, file and endpoint url" do
      base = Webhooks.media_dedupe_key(snapshot())

      refute base == Webhooks.media_dedupe_key(snapshot(event: "media.deleted"))
      refute base == Webhooks.media_dedupe_key(snapshot(dataset: "staging"))
      refute base == Webhooks.media_dedupe_key(snapshot(file_id: "file-zzz"))
      refute base == Webhooks.media_dedupe_key(snapshot(url: "https://other.test/h"))
    end

    test "an un-keyable snapshot derives NIL rather than an invented key" do
      assert Webhooks.media_dedupe_key(%{"url" => @url, "body" => "not json"}) == nil
      assert Webhooks.media_dedupe_key(%{"url" => @url, "body" => ~s({"event":"m"})}) == nil
      assert Webhooks.media_dedupe_key(%{"body" => body()}) == nil
      assert Webhooks.media_dedupe_key(%{}) == nil
    end
  end

  describe "the UNIQUE index refuses a repeat" do
    test "the SECOND delivery of the same logical event is refused" do
      assert {:ok, first} = Webhooks.create_media_delivery(snapshot())
      assert is_binary(first.dedupe_key)

      # The re-drive: same file, same event, same endpoint, fresh encode.
      assert {:error, :already_delivered} = Webhooks.create_media_delivery(snapshot())

      assert Repo.aggregate(
               from(d in Delivery, where: d.dedupe_key == ^first.dedupe_key),
               :count
             ) == 1
    end

    test "CONTROL — two DIFFERENT events both land" do
      assert {:ok, a} = Webhooks.create_media_delivery(snapshot(file_id: "f1"))
      assert {:ok, b} = Webhooks.create_media_delivery(snapshot(file_id: "f2"))
      assert {:ok, c} = Webhooks.create_media_delivery(snapshot(event: "media.deleted"))
      assert {:ok, d} = Webhooks.create_media_delivery(snapshot(url: "https://two.test/h"))

      ids = Enum.map([a, b, c, d], & &1.id)
      assert length(Enum.uniq(ids)) == 4
      refute Enum.any?(ids, &is_nil/1)
      assert length(Enum.uniq(Enum.map([a, b, c, d], & &1.dedupe_key))) == 4
    end

    test "CONTROL — NULL keys never collide (legacy / un-keyable snapshots)" do
      snap = %{"url" => @url, "secret" => "s", "body" => ~s({"e":"m"})}

      assert {:ok, a} = Webhooks.create_media_delivery(snap)
      assert {:ok, b} = Webhooks.create_media_delivery(snap)

      assert a.dedupe_key == nil
      assert b.dedupe_key == nil
      refute a.id == b.id
    end

    test "CONTROL — the index is scoped to media; another source_kind is untouched" do
      # The SAME dedupe_key text on a NON-media row inserts freely: the partial
      # index predicate (source_kind = 'media') is what keeps the axes separate.
      # A "test" row is used because it, like media, carries a NULL endpoint_id
      # (no `webhooks` FK to satisfy) — so this measures the PREDICATE only.
      {:ok, media} = Webhooks.create_media_delivery(snapshot())

      {:ok, other} =
        %Delivery{}
        |> Delivery.changeset(%{
          source_kind: "test",
          dedupe_key: media.dedupe_key,
          payload_snapshot: %{"body" => "{}"}
        })
        |> Repo.insert()

      assert other.dedupe_key == media.dedupe_key
      refute other.id == media.id
    end
  end
end
