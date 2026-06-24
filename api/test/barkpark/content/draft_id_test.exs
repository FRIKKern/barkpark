defmodule Barkpark.Content.DraftIdTest do
  use ExUnit.Case, async: true
  alias Barkpark.Content.DraftId

  test "drafts_prefix/0 returns the canonical prefix string" do
    assert DraftId.drafts_prefix() == "drafts."
  end

  test "draft_id/1 prepends prefix to a plain published id" do
    assert DraftId.draft_id("abc123") == "drafts.abc123"
  end

  test "draft_id/1 is idempotent — already-prefixed id is returned unchanged" do
    assert DraftId.draft_id("drafts.abc123") == "drafts.abc123"
  end

  test "published_id/1 strips prefix from a draft id" do
    assert DraftId.published_id("drafts.abc123") == "abc123"
  end

  test "published_id/1 is idempotent — already-published id is returned unchanged" do
    assert DraftId.published_id("abc123") == "abc123"
  end

  test "draft?/1 returns true for a draft id" do
    assert DraftId.draft?("drafts.something") == true
  end

  test "draft?/1 returns false for a published id" do
    assert DraftId.draft?("something") == false
  end
end
