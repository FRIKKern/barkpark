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
end
