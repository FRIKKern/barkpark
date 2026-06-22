defmodule Barkpark.Media.Storage.AccessTest do
  @moduledoc """
  Unit tests for Barkpark.Media.Storage.Access — pure logic, no DB calls.

  Every test builds minimal structs (Plug.Conn, Document, MediaFile) inline so
  the suite is async-safe and runs without a sandbox.
  """

  use ExUnit.Case, async: true

  alias Barkpark.Auth.ApiToken
  alias Barkpark.Content.Document
  alias Barkpark.Media.Storage.Access
  alias Barkpark.Media.Storage.MediaFile

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # An unauthenticated conn — no :api_token assign.
  defp anon_conn(path \\ "/media/files/sample.png") do
    %Plug.Conn{request_path: path, query_params: %{}}
  end

  # An authenticated conn with the given permissions and optional label.
  defp authed_conn(permissions, opts \\ []) do
    label = Keyword.get(opts, :label, "test-token")
    path = Keyword.get(opts, :path, "/media/files/sample.png")

    token = %ApiToken{
      label: label,
      permissions: permissions
    }

    %Plug.Conn{
      request_path: path,
      query_params: %{},
      assigns: %{api_token: token}
    }
  end

  # A MediaFile with a fresh UUID id — signed-url checks use this id.
  defp file(id \\ Ecto.UUID.generate()) do
    %MediaFile{id: id}
  end

  # Build a Document with the given content map.
  defp doc(content) do
    %Document{content: content}
  end

  # ---------------------------------------------------------------------------
  # visibility/1
  # ---------------------------------------------------------------------------

  describe "visibility/1" do
    test "nil document returns 'public'" do
      assert Access.visibility(nil) == "public"
    end

    test "document without bp_visibility key returns 'public'" do
      assert Access.visibility(doc(%{"title" => "foo"})) == "public"
    end

    test "document with bp_visibility 'token' returns 'token'" do
      assert Access.visibility(doc(%{"bp_visibility" => "token"})) == "token"
    end

    test "document with bp_visibility 'private' returns 'private'" do
      assert Access.visibility(doc(%{"bp_visibility" => "private"})) == "private"
    end

    test "document with nil bp_visibility falls back to 'public'" do
      # Map.get returns nil → `|| "public"` kicks in
      assert Access.visibility(doc(%{"bp_visibility" => nil})) == "public"
    end

    test "non-Document value (plain map, atom) returns 'public'" do
      assert Access.visibility(%{}) == "public"
      assert Access.visibility(:bad) == "public"
    end
  end

  # ---------------------------------------------------------------------------
  # watermark_profile/1
  # ---------------------------------------------------------------------------

  describe "watermark_profile/1" do
    test "nil document returns 'none'" do
      assert Access.watermark_profile(nil) == "none"
    end

    test "document without rights key returns 'none'" do
      assert Access.watermark_profile(doc(%{})) == "none"
    end

    test "document with watermarkProfile 'editorial' returns 'editorial'" do
      assert Access.watermark_profile(doc(%{"rights" => %{"watermarkProfile" => "editorial"}})) ==
               "editorial"
    end

    test "document with watermarkProfile 'draft' returns 'draft'" do
      assert Access.watermark_profile(doc(%{"rights" => %{"watermarkProfile" => "draft"}})) ==
               "draft"
    end

    test "empty-string watermarkProfile normalises to 'none'" do
      assert Access.watermark_profile(doc(%{"rights" => %{"watermarkProfile" => ""}})) == "none"
    end

    test "missing watermarkProfile inside rights returns 'none'" do
      assert Access.watermark_profile(doc(%{"rights" => %{}})) == "none"
    end

    test "non-Document value returns 'none'" do
      assert Access.watermark_profile("bad") == "none"
    end
  end

  # ---------------------------------------------------------------------------
  # allowed?/4  — :view / :preview
  # ---------------------------------------------------------------------------

  describe "allowed?/4 — :view" do
    test "public doc, anon user, view — allowed" do
      assert Access.allowed?(anon_conn(), file(), nil, :view)
    end

    test "public doc, anon user, preview — allowed" do
      assert Access.allowed?(anon_conn(), file(), nil, :preview)
    end

    test "private doc, anon user, view — denied" do
      refute Access.allowed?(anon_conn(), file(), doc(%{"bp_visibility" => "private"}), :view)
    end

    test "private doc, authenticated user, view — allowed" do
      # auth grants 'view' permission and delivery_ok? for private
      conn = authed_conn(["view", "preview", "use_original"])
      assert Access.allowed?(conn, file(), doc(%{"bp_visibility" => "private"}), :view)
    end

    test "token doc, anon user without signed url — denied" do
      # No signed-url params, no auth → delivery_ok? = false
      token_doc = doc(%{"bp_visibility" => "token"})
      refute Access.allowed?(anon_conn(), file(), token_doc, :view)
    end
  end

  # ---------------------------------------------------------------------------
  # allowed?/4  — :original
  # ---------------------------------------------------------------------------

  describe "allowed?/4 — :original" do
    test "public doc, authenticated user with use_original — allowed" do
      conn = authed_conn(["view", "preview", "use_original"])
      assert Access.allowed?(conn, file(), nil, :original)
    end

    test "public doc, anon user — allowed (public delivery, use_original in perms)" do
      # anon on public doc gets ["view", "preview", "use_original"] from permission_set
      assert Access.allowed?(anon_conn(), file(), nil, :original)
    end

    test "private doc, anon user — denied" do
      priv = doc(%{"bp_visibility" => "private"})
      refute Access.allowed?(anon_conn(), file(), priv, :original)
    end
  end

  # ---------------------------------------------------------------------------
  # allowed?/4  — :edit_metadata
  # ---------------------------------------------------------------------------

  describe "allowed?/4 — :edit_metadata" do
    test "authenticated admin can edit_metadata on any doc" do
      conn = authed_conn(["admin", "view", "preview", "use_original", "edit_metadata"])
      assert Access.allowed?(conn, file(), nil, :edit_metadata)
    end

    test "unauthenticated user cannot edit_metadata" do
      refute Access.allowed?(anon_conn(), file(), nil, :edit_metadata)
    end

    test "authenticated non-admin can edit_metadata when no checkout" do
      conn = authed_conn(["view", "preview", "use_original"])
      # doc has no checkedOutBy — edit_metadata should be granted
      assert Access.allowed?(conn, file(), doc(%{}), :edit_metadata)
    end

    test "authenticated non-admin cannot edit_metadata when checked out by another actor" do
      conn = authed_conn(["view"], label: "alice")
      locked_doc = doc(%{"checkedOutBy" => "bob"})
      refute Access.allowed?(conn, file(), locked_doc, :edit_metadata)
    end

    test "actor who holds checkout can still edit_metadata" do
      conn = authed_conn(["view"], label: "alice")
      alice_doc = doc(%{"checkedOutBy" => "alice"})
      assert Access.allowed?(conn, file(), alice_doc, :edit_metadata)
    end
  end

  # ---------------------------------------------------------------------------
  # allowed?/4  — unknown level
  # ---------------------------------------------------------------------------

  describe "allowed?/4 — unknown level" do
    test "an unrecognised level always returns false" do
      conn = authed_conn(["admin", "view", "use_original", "edit_metadata"])
      refute Access.allowed?(conn, file(), nil, :delete_forever)
    end
  end

  # ---------------------------------------------------------------------------
  # permissions/3  — WoodWing-style list
  # ---------------------------------------------------------------------------

  describe "permissions/3" do
    test "anon user on public doc gets view, preview, use_original" do
      perms = Access.permissions(anon_conn(), file(), nil)
      assert "view" in perms
      assert "preview" in perms
      assert "use_original" in perms
      refute "edit_metadata" in perms
    end

    test "anon user on private doc gets empty list" do
      priv = doc(%{"bp_visibility" => "private"})
      perms = Access.permissions(anon_conn(), file(), priv)
      assert perms == []
    end

    test "authenticated user on public doc (no checkout) gets all four permissions" do
      conn = authed_conn(["view", "preview", "use_original", "edit_metadata"])
      perms = Access.permissions(conn, file(), doc(%{}))
      assert "view" in perms
      assert "preview" in perms
      assert "use_original" in perms
      assert "edit_metadata" in perms
    end

    test "authenticated user locked out by another actor loses edit_metadata and use_original" do
      conn = authed_conn(["view"], label: "carol")
      locked_doc = doc(%{"checkedOutBy" => "dave"})
      perms = Access.permissions(conn, file(), locked_doc)
      refute "edit_metadata" in perms
      refute "use_original" in perms
    end

    test "admin user always gets edit_metadata regardless of checkout" do
      # Admin check: has_permission?(token, "admin") → permissions list contains "admin"
      conn = authed_conn(["admin", "view", "preview", "use_original", "edit_metadata"])
      locked_doc = doc(%{"checkedOutBy" => "someone-else"})
      perms = Access.permissions(conn, file(), locked_doc)
      assert "edit_metadata" in perms
    end

    test "token-visibility doc with anon user returns no delivery-gated perms" do
      token_doc = doc(%{"bp_visibility" => "token"})
      perms = Access.permissions(anon_conn(), file(), token_doc)

      # Without auth or signed URL, delivery_ok? is false → view/preview/use_original filtered out
      refute "view" in perms
      refute "use_original" in perms
    end

    test "result list contains no duplicates" do
      conn = authed_conn(["view", "preview", "use_original", "edit_metadata"])
      perms = Access.permissions(conn, file(), doc(%{}))
      assert perms == Enum.uniq(perms)
    end
  end

  # ---------------------------------------------------------------------------
  # Checkout / actor_label edge cases
  # ---------------------------------------------------------------------------

  describe "checkout + actor_label edge cases" do
    test "empty-string checkedOutBy is treated as no checkout (not locked)" do
      conn = authed_conn(["view"], label: "eve")
      unlocked = doc(%{"checkedOutBy" => ""})
      # empty string → checked_out_by is "" → treated as nil/empty → edit_metadata granted
      perms = Access.permissions(conn, file(), unlocked)
      assert "edit_metadata" in perms
    end

    test "token without label defaults actor_label to 'api'" do
      # A token with no label; actor_label falls back to "api"
      token = %ApiToken{label: nil, permissions: ["view"]}
      conn = %Plug.Conn{request_path: "/m", query_params: %{}, assigns: %{api_token: token}}

      # checkedOutBy "api" should match the actor, so edit_metadata granted
      api_doc = doc(%{"checkedOutBy" => "api"})
      perms = Access.permissions(conn, file(), api_doc)
      assert "edit_metadata" in perms
    end

    test "token with empty-string label defaults actor_label to 'api'" do
      token = %ApiToken{label: "", permissions: ["view"]}
      conn = %Plug.Conn{request_path: "/m", query_params: %{}, assigns: %{api_token: token}}

      api_doc = doc(%{"checkedOutBy" => "api"})
      perms = Access.permissions(conn, file(), api_doc)
      assert "edit_metadata" in perms
    end
  end
end
