defmodule BarkparkCloud.Registry.PreviewSlugTest do
  @moduledoc """
  gh-6: pure, no-DB unit test over the preview subdomain derivation —
  `preview_slug_for/3` + `preview_host_for/3`. The slug becomes a public DNS
  label + a Caddy host key, so it MUST be DNS-safe (≤ 63 chars, `[a-z0-9-]`,
  no leading/trailing hyphen) and stable (same branch → same host, so a new push
  replaces the branch's preview in place).
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.Registry

  @site_id "0b7e3c1a-5d2f-4e8b-9a6c-1f2e3d4c5b6a"

  # A syntactically valid single DNS label.
  defp valid_label?(label) do
    String.length(label) in 1..63 and
      Regex.match?(~r/^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/, label)
  end

  describe "preview_slug_for/3" do
    test "basic slug is <site>--<branch>-<hash> and DNS-safe" do
      slug = Registry.preview_slug_for("shop", "dev", @site_id)
      assert String.starts_with?(slug, "shop--dev-")
      assert valid_label?(slug)
    end

    test "special characters are sanitized to hyphens, lowercased" do
      slug = Registry.preview_slug_for("shop", "Feature/Login_Page", @site_id)
      assert valid_label?(slug)
      assert slug =~ "feature-login-page"
      refute slug =~ "/"
      refute slug =~ "_"
    end

    test "deterministic — same inputs yield the same slug" do
      assert Registry.preview_slug_for("shop", "dev", @site_id) ==
               Registry.preview_slug_for("shop", "dev", @site_id)
    end

    test "branches that sanitize alike stay distinct (hash of the raw branch)" do
      a = Registry.preview_slug_for("shop", "feat/x", @site_id)
      b = Registry.preview_slug_for("shop", "feat-x", @site_id)
      refute a == b
      assert valid_label?(a)
      assert valid_label?(b)
    end

    test "a very long branch is clamped to a valid 63-char label" do
      slug =
        Registry.preview_slug_for("shop", String.duplicate("very-long-branch-", 20), @site_id)

      assert valid_label?(slug)
    end

    test "a very long site slug still leaves room for the branch + hash" do
      slug = Registry.preview_slug_for(String.duplicate("a", 60), "dev", @site_id)
      assert valid_label?(slug)
    end

    test "an all-punctuation branch falls back to the hash, still valid" do
      slug = Registry.preview_slug_for("shop", "///___///", @site_id)
      assert valid_label?(slug)
      assert String.starts_with?(slug, "shop--")
    end
  end

  # task-f98ea12880b32251: site slugs are unique per TEAM only, so the label
  # must separate two teams' sites that share a slug.
  describe "team scoping" do
    test "two sites with the SAME slug in different teams get different hosts for one branch" do
      a = Registry.preview_host_for("blog", "dev", "11111111-1111-4111-8111-111111111111")
      b = Registry.preview_host_for("blog", "dev", "22222222-2222-4222-8222-222222222222")
      refute a == b
    end

    test "the hash is 64 bits (16 hex), so a chosen branch name cannot be searched into a collision" do
      hash =
        "shop" |> Registry.preview_slug_for("dev", @site_id) |> String.split("-") |> List.last()

      assert hash =~ ~r/^[0-9a-f]{16}$/
    end
  end

  describe "preview_host_for/3" do
    test "host is <slug>.<base_domain>" do
      host = Registry.preview_host_for("shop", "dev", @site_id)
      assert String.ends_with?(host, ".barkpark.cloud")
      slug = Registry.preview_slug_for("shop", "dev", @site_id)
      assert host == slug <> ".barkpark.cloud"
    end
  end
end
