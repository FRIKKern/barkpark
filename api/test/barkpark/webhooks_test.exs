defmodule Barkpark.WebhooksTest do
  use Barkpark.DataCase, async: false

  alias Barkpark.Webhooks

  test "create and list webhooks" do
    {:ok, wh} = Webhooks.create_webhook(%{"name" => "Test", "url" => "http://example.com/hook", "dataset" => "test"})
    assert wh.name == "Test"
    assert wh.active == true

    hooks = Webhooks.list_webhooks("test")
    assert length(hooks) == 1
  end

  test "update a webhook" do
    {:ok, wh} = Webhooks.create_webhook(%{"name" => "Test", "url" => "http://example.com/hook", "dataset" => "test"})
    {:ok, updated} = Webhooks.update_webhook(wh, %{"active" => false})
    assert updated.active == false
  end

  test "delete a webhook" do
    {:ok, wh} = Webhooks.create_webhook(%{"name" => "Test", "url" => "http://example.com/hook", "dataset" => "test"})
    {:ok, _} = Webhooks.delete_webhook(wh)
    assert Webhooks.list_webhooks("test") == []
  end

  test "active_webhooks_for matches event and type" do
    Webhooks.create_webhook(%{"name" => "All", "url" => "http://example.com/all", "dataset" => "test", "events" => [], "types" => []})
    Webhooks.create_webhook(%{"name" => "Creates", "url" => "http://example.com/create", "dataset" => "test", "events" => ["create"], "types" => []})
    Webhooks.create_webhook(%{"name" => "Posts", "url" => "http://example.com/post", "dataset" => "test", "events" => [], "types" => ["post"]})
    Webhooks.create_webhook(%{"name" => "Inactive", "url" => "http://example.com/off", "dataset" => "test", "active" => false})

    matches = Webhooks.active_webhooks_for("test", "create", "post")
    names = Enum.map(matches, & &1.name) |> Enum.sort()
    assert names == ["All", "Creates", "Posts"]
  end

  test "validates URL format" do
    {:error, changeset} = Webhooks.create_webhook(%{"name" => "Bad", "url" => "not-a-url"})
    assert errors_on(changeset).url != nil
  end
end
