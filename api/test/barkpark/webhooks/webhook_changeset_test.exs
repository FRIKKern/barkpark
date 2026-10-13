defmodule Barkpark.Webhooks.WebhookChangesetTest do
  use ExUnit.Case, async: true

  alias Barkpark.Webhooks.Webhook

  defp cs(url), do: Webhook.changeset(%Webhook{}, %{"name" => "n", "url" => url})

  test "accepts a well-formed http(s) URL" do
    assert cs("https://ok.example").valid?
    assert cs("http://ok.example/path").valid?
  end

  test "rejects a URL with no host" do
    refute cs("http:///").valid?
    refute cs("http://:9000").valid?
  end

  test "rejects userinfo (credential-in-URL)" do
    changeset = cs("https://user:pw@host.example")
    refute changeset.valid?
    assert {"must not contain userinfo", _} = changeset.errors[:url]
  end

  test "rejects a non-http scheme" do
    refute cs("ftp://host.example").valid?
    refute cs("javascript:alert(1)").valid?
  end

  describe "events" do
    defp events_cs(events) do
      Webhook.changeset(%Webhook{}, %{
        "name" => "n",
        "url" => "https://ok.example",
        "events" => events
      })
    end

    test "accepts every event the dispatcher can actually emit" do
      assert events_cs(~w(create update publish unpublish delete discardDraft)).valid?
    end

    # task-2195336df2daf576: the dispatcher never emits "patch" — a patch
    # mutation lands in Content.Writer exactly like any other save and is
    # reported with the storage-shaped action it actually took ("update" for
    # an existing draft, "create" for a fresh fork; see
    # active_webhooks_for/4's exact `events @> ARRAY[event]` match). A hook
    # subscribed to "patch" was accepted and could never fire; this must be
    # refused at creation instead of silently swallowing deliveries forever.
    test "refuses patch — no dispatch call ever emits it" do
      changeset = events_cs(["patch"])
      refute changeset.valid?
      assert {"has an invalid entry", _} = changeset.errors[:events]
    end

    test "a patch subscription mixed with a real event is still refused" do
      refute events_cs(["update", "patch"]).valid?
    end
  end
end
