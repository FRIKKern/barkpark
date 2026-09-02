defmodule Barkpark.SharingTest do
  @moduledoc """
  P1a coverage for the scoped-sharing registry.

  The parser is PURE (no env access), but the `shared?` / `access_for` /
  `active?` tests mutate the shared `:barkpark, :shares` Application env (via
  `with_shares/2`, restored on_exit). Some of those tests also assert the
  empty-config default. Because the env is process-global, the whole module
  runs `async: false` so a "shares configured" test can never race a
  "empty-config denies" test.
  """
  use ExUnit.Case, async: false

  alias Barkpark.Sharing
  alias Barkpark.Sharing.Share

  # ── parse/1 ────────────────────────────────────────────────────────────

  describe "parse/1" do
    test "parses a valid multi-entry string" do
      shares =
        Sharing.parse("gyldendal/books/production:papers,docs:read;acme/web/staging:media:edit")

      assert [
               %Share{
                 workspace_slug: "gyldendal",
                 project_slug: "books",
                 dataset: "production",
                 surfaces: [:papers, :docs],
                 access: :read
               },
               %Share{
                 workspace_slug: "acme",
                 project_slug: "web",
                 dataset: "staging",
                 surfaces: [:media],
                 access: :edit
               }
             ] = shares
    end

    test "bare workspace scope defaults project=default and dataset=production" do
      assert [%Share{workspace_slug: "gyldendal", project_slug: "default", dataset: "production"}] =
               Sharing.parse("gyldendal:papers:read")
    end

    test "two-segment scope defaults dataset=production" do
      assert [%Share{workspace_slug: "gyldendal", project_slug: "books", dataset: "production"}] =
               Sharing.parse("gyldendal/books:papers:read")
    end

    test "access defaults to :read when the third segment is omitted" do
      assert [%Share{access: :read}] = Sharing.parse("gyldendal:papers")
    end

    test "parses the full surface set and de-dupes" do
      assert [%Share{surfaces: surfaces}] =
               Sharing.parse("ws:papers,docs,media,papers:edit")

      assert surfaces == [:papers, :docs, :media]
    end

    test "drops unknown surface tokens but keeps the valid ones" do
      assert [%Share{surfaces: [:papers, :docs]}] =
               Sharing.parse("ws:papers,wat,docs:read")
    end

    test "skips an entry whose surfaces are ALL unknown (no grant)" do
      assert [] = Sharing.parse("ws:wat,nope:read")
    end

    test "skips an entry with an unknown access value (no grant)" do
      assert [] = Sharing.parse("ws:papers:superuser")
    end

    test "skips malformed entries without crashing and without granting" do
      # bare scope (no surfaces segment), empty scope, trailing junk — none crash
      shares = Sharing.parse("justscope;:papers:read;gyldendal:papers:read")

      assert [%Share{workspace_slug: "gyldendal", surfaces: [:papers]}] = shares
    end

    test "rejects scope segments containing a glob metacharacter (no wildcard grant)" do
      # Matching is byte-exact, so "*" is inert — but the parser refuses it
      # outright so a share is never written with a wildcard segment.
      assert [] = Sharing.parse("*/default/production:papers:read")
      assert [] = Sharing.parse("gyldendal/*/production:papers:read")
      assert [] = Sharing.parse("gyldendal/default/prod?:papers:read")
    end

    test "trims whitespace around entries, scope, surfaces and access" do
      assert [%Share{workspace_slug: "gyldendal", surfaces: [:papers, :docs], access: :edit}] =
               Sharing.parse("  gyldendal / books / production : papers , docs : edit  ")
    end

    test "returns [] for nil and empty string" do
      assert [] = Sharing.parse(nil)
      assert [] = Sharing.parse("")
      assert [] = Sharing.parse("   ")
    end

    test "tolerates non-binary input" do
      assert [] = Sharing.parse(:not_a_string)
      assert [] = Sharing.parse(123)
    end
  end

  # ── shared?/4 ──────────────────────────────────────────────────────────

  describe "shared?/4 — exact match grants" do
    test "exact (ws, project, dataset, surface) match is true", ctx do
      with_shares("gyldendal/books/production:papers,docs:read", ctx)

      assert Sharing.shared?("gyldendal", "books", "production", :papers)
      assert Sharing.shared?("gyldendal", "books", "production", :docs)
      # string surface is normalized
      assert Sharing.shared?("gyldendal", "books", "production", "papers")
    end
  end

  describe "shared?/4 — DEFAULT-DENY" do
    test "empty config denies everything" do
      refute Sharing.shared?("gyldendal", "books", "production", :papers)
    end

    test "wrong workspace is denied", ctx do
      with_shares("gyldendal/books/production:papers:read", ctx)
      refute Sharing.shared?("acme", "books", "production", :papers)
    end

    test "wrong project is denied", ctx do
      with_shares("gyldendal/books/production:papers:read", ctx)
      refute Sharing.shared?("gyldendal", "default", "production", :papers)
    end

    test "wrong dataset is denied", ctx do
      with_shares("gyldendal/books/production:papers:read", ctx)
      refute Sharing.shared?("gyldendal", "books", "staging", :papers)
    end

    test "surface not listed is denied", ctx do
      with_shares("gyldendal/books/production:papers:read", ctx)
      refute Sharing.shared?("gyldendal", "books", "production", :media)
    end

    test "unknown surface arg is denied", ctx do
      with_shares("gyldendal/books/production:papers:read", ctx)
      refute Sharing.shared?("gyldendal", "books", "production", :nope)
      refute Sharing.shared?("gyldendal", "books", "production", "nope")
    end

    test "non-binary args never raise and deny", ctx do
      with_shares("gyldendal/books/production:papers:read", ctx)
      refute Sharing.shared?(nil, "books", "production", :papers)
      refute Sharing.shared?("gyldendal", nil, "production", :papers)
      refute Sharing.shared?("gyldendal", "books", nil, :papers)
    end
  end

  # ── access_for/3 + active?/0 ───────────────────────────────────────────

  describe "access_for/3" do
    test "returns the configured access for an exact triple match", ctx do
      with_shares("gyldendal/books/production:papers:edit", ctx)
      assert Sharing.access_for("gyldendal", "books", "production") == :edit
    end

    test "defaults to :read access", ctx do
      with_shares("gyldendal:papers", ctx)
      assert Sharing.access_for("gyldendal", "default", "production") == :read
    end

    test "returns nil when no triple matches", ctx do
      with_shares("gyldendal/books/production:papers:edit", ctx)
      assert Sharing.access_for("acme", "books", "production") == nil
    end

    test "returns nil with empty config" do
      assert Sharing.access_for("gyldendal", "books", "production") == nil
    end

    test "non-binary args never raise" do
      assert Sharing.access_for(nil, "books", "production") == nil
    end
  end

  describe "active?/0" do
    # PRECONDITION, not assumption: `Sharing.reload/0` in other files writes
    # `shares_env() ++ stored` into `:barkpark, :shares`, and that app env
    # survives their sandbox rollback. "No shares configured" must be
    # established here, then restored, or this test reds on suite order
    # (main went red on it 2026-09-02 after a merge burst).
    setup ctx do
      prior = Application.get_env(:barkpark, :shares)
      Application.delete_env(:barkpark, :shares)

      ExUnit.Callbacks.on_exit(ctx, fn ->
        if is_nil(prior),
          do: Application.delete_env(:barkpark, :shares),
          else: Application.put_env(:barkpark, :shares, prior)
      end)

      :ok
    end

    test "false with no shares configured" do
      refute Sharing.active?()
    end

    test "true once shares are configured", ctx do
      with_shares("gyldendal:papers:read", ctx)
      assert Sharing.active?()
    end
  end

  # ── surfaces/0 + accesses/0 ────────────────────────────────────────────

  describe "constants" do
    test "surfaces/0 is the closed set" do
      assert Sharing.surfaces() == [:papers, :docs, :media]
    end

    test "accesses/0 is the closed set" do
      assert Sharing.accesses() == [:read, :edit]
    end
  end

  # ── share_urls/0,2 + lan_ip/0 (P1c) ────────────────────────────────────

  describe "share_urls/2" do
    test "builds the /w/<ws>/p/<proj>/papers/ URL for a :papers share", ctx do
      with_shares("gyldendal/books/production:papers,docs:read", ctx)

      assert [{%Share{workspace_slug: "gyldendal", project_slug: "books"}, url}] =
               Sharing.share_urls("10.0.0.5", 4000)

      assert url == "http://10.0.0.5:4000/w/gyldendal/p/books/papers/"
    end

    test "honours a non-default port", ctx do
      with_shares("gyldendal/books/production:papers:read", ctx)

      assert [{_share, "http://192.168.1.2:8080/w/gyldendal/p/books/papers/"}] =
               Sharing.share_urls("192.168.1.2", 8080)
    end

    test "a :docs-only share yields no papers URL", ctx do
      with_shares("gyldendal/books/production:docs:read", ctx)
      assert Sharing.share_urls("10.0.0.5", 4000) == []
    end

    test "only :papers shares contribute, in order, when surfaces are mixed", ctx do
      with_shares(
        "acme/web/staging:media:edit;gyldendal/books/production:papers:read",
        ctx
      )

      assert [{%Share{workspace_slug: "gyldendal"}, url}] =
               Sharing.share_urls("10.0.0.5", 4000)

      assert url == "http://10.0.0.5:4000/w/gyldendal/p/books/papers/"
    end

    test "no shares (Default-OFF) yields no URLs" do
      assert Sharing.share_urls("10.0.0.5", 4000) == []
    end
  end

  describe "lan_ip/0" do
    test "returns a binary IPv4 string or nil (never raises)" do
      result = Sharing.lan_ip()
      assert is_binary(result) or is_nil(result)

      if is_binary(result) do
        # A dotted-quad shape; we do NOT assert any specific address.
        assert Regex.match?(~r/^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/, result)
        refute String.starts_with?(result, "127.")
      end
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp with_shares(env_string, ctx) do
    prior = Application.get_env(:barkpark, :shares)
    Application.put_env(:barkpark, :shares, Sharing.parse(env_string))

    ExUnit.Callbacks.on_exit(ctx, fn ->
      if is_nil(prior),
        do: Application.delete_env(:barkpark, :shares),
        else: Application.put_env(:barkpark, :shares, prior)
    end)

    :ok
  end
end
