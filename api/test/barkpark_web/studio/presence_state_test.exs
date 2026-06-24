defmodule BarkparkWeb.Studio.PresenceStateTest do
  @moduledoc """
  Unit tests for `BarkparkWeb.Studio.PresenceState` — the pure presence
  helper extracted from `StudioLive` in Task #11 WI3.

  All functions are pure (no DB, no PubSub side-effects) so we use
  `ExUnit.Case, async: true`.
  """

  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.PresenceState

  @colors ~w(#3b82f6 #ef4444 #10b981 #f59e0b #8b5cf6 #ec4899 #06b6d4 #f97316)

  describe "topic/1" do
    test "scopes topic to workspace when workspace_id is a binary" do
      assert PresenceState.topic("ws-abc") == "studio:presence:ws:ws-abc"
    end

    test "falls back to global topic when workspace_id is nil" do
      assert PresenceState.topic(nil) == "studio:presence"
    end

    test "falls back to global topic for non-binary values" do
      assert PresenceState.topic(42) == "studio:presence"
    end
  end

  describe "generate_user_id/0" do
    test "returns a 12-character lowercase hex string" do
      id = PresenceState.generate_user_id()
      assert byte_size(id) == 12
      assert id =~ ~r/\A[0-9a-f]{12}\z/
    end

    test "successive calls produce distinct ids" do
      ids = for _ <- 1..20, do: PresenceState.generate_user_id()
      assert Enum.uniq(ids) == ids
    end
  end

  describe "pick_color/1" do
    test "returns a color string from the known palette" do
      color = PresenceState.pick_color("user-1")
      assert color in @colors
    end

    test "is deterministic — same user_id always maps to the same color" do
      assert PresenceState.pick_color("alice") == PresenceState.pick_color("alice")
    end

    test "different user_ids may map to different colors (distribution sanity)" do
      colors =
        for i <- 1..32, do: PresenceState.pick_color("user-#{i}")

      # With 8 colors and 32 users (via phash2) we expect at least 2 distinct values
      assert length(Enum.uniq(colors)) >= 2
    end
  end

  describe "on_doc/3" do
    test "returns only presences matching both doc_id and dataset" do
      presences = [
        %{doc_id: "p1", dataset: "production", user_id: "a"},
        %{doc_id: "p1", dataset: "test", user_id: "b"},
        %{doc_id: "p2", dataset: "production", user_id: "c"}
      ]

      result = PresenceState.on_doc(presences, "p1", "production")
      assert length(result) == 1
      assert hd(result).user_id == "a"
    end

    test "returns empty list when no presence matches" do
      presences = [%{doc_id: "p1", dataset: "production", user_id: "a"}]
      assert PresenceState.on_doc(presences, "p999", "production") == []
    end

    test "filters out stale metas where :dataset key is absent (nil dataset guard)" do
      # Metas from before the :dataset field was added lack the key entirely;
      # Map.get/2 returns nil, so nil ≠ "production" and they are excluded.
      presences = [
        %{doc_id: "p1", user_id: "stale"},
        %{doc_id: "p1", dataset: "production", user_id: "fresh"}
      ]

      result = PresenceState.on_doc(presences, "p1", "production")
      assert length(result) == 1
      assert hd(result).user_id == "fresh"
    end
  end
end
