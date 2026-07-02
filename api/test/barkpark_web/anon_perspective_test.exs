defmodule BarkparkWeb.AnonPerspectiveTest do
  # Pure, DB-free: verifies the anonymous-perspective invariant at the
  # resolution layer (where the search-controller leak lived). The end-to-end
  # HTTP behaviour (anon GET /v1/search?perspective=drafts returns no drafts)
  # still wants a DB-backed controller test — see the PR notes.
  use ExUnit.Case, async: true

  alias BarkparkWeb.AnonPerspective

  defp conn(assigns), do: %Plug.Conn{assigns: Map.new(assigns)}

  test "anonymous caller is pinned to :published even with ?perspective=drafts|raw" do
    c = conn(%{})
    assert AnonPerspective.anon_pinned?(c)
    assert AnonPerspective.resolve(c, %{"perspective" => "drafts"}) == :published
    assert AnonPerspective.resolve(c, %{"perspective" => "raw"}) == :published
    assert AnonPerspective.resolve(c, %{}) == :published
  end

  test "authenticated caller (api_token) honours the requested perspective" do
    c = conn(%{api_token: %{tier: :member}})
    refute AnonPerspective.anon_pinned?(c)
    assert AnonPerspective.resolve(c, %{"perspective" => "drafts"}) == :drafts
    assert AnonPerspective.resolve(c, %{"perspective" => "raw"}) == :raw
    assert AnonPerspective.resolve(c, %{}) == :published
  end

  test "preview caller (forced_perspective) is not anon-pinned" do
    c = conn(%{forced_perspective: "drafts"})
    refute AnonPerspective.anon_pinned?(c)
    # forced_perspective wins over the param
    assert AnonPerspective.resolve(c, %{"perspective" => "published"}) == :drafts
  end

  test ":edit public share is exempt (anonymous editing surface honours param)" do
    c = conn(%{share_public: true, share_access: :edit})
    refute AnonPerspective.anon_pinned?(c)
    assert AnonPerspective.resolve(c, %{"perspective" => "drafts"}) == :drafts
  end

  test "read-only (:view) public share is STILL pinned to :published" do
    c = conn(%{share_public: true, share_access: :view})
    assert AnonPerspective.anon_pinned?(c)
    assert AnonPerspective.resolve(c, %{"perspective" => "drafts"}) == :published
  end

  test "parse/1 always yields an atom (never a string that would defeat the filter)" do
    assert AnonPerspective.parse("drafts") == :drafts
    assert AnonPerspective.parse("raw") == :raw
    assert AnonPerspective.parse("published") == :published
    assert AnonPerspective.parse("garbage") == :published
    assert AnonPerspective.parse(nil) == :published
  end
end
