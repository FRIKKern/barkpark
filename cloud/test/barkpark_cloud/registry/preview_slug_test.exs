defmodule BarkparkCloud.Registry.PreviewSlugTest do
  @moduledoc """
  gh-6: pure, no-DB unit test over the preview subdomain derivation —
  `preview_slug_for/2` + `preview_host_for/2`. The slug becomes a public DNS
  label + a Caddy host key, so it MUST be DNS-safe (≤ 63 chars, `[a-z0-9-]`,
  no leading/trailing hyphen) and stable (same branch → same host, so a new push
  replaces the branch's preview in place).
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.Registry

  # A syntactically valid single DNS label.
  defp valid_label?(label) do
    String.length(label) in 1..63 and
      Regex.match?(~r/^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/, label)
  end

  describe "preview_slug_for/2" do
    test "basic slug is <site>--<branch>-<hash> and DNS-safe" do
      slug = Registry.preview_slug_for("shop", "dev")
      assert String.starts_with?(slug, "shop--dev-")
      assert valid_label?(slug)
    end

    test "special characters are sanitized to hyphens, lowercased" do
      slug = Registry.preview_slug_for("shop", "Feature/Login_Page")
      assert valid_label?(slug)
      assert slug =~ "feature-login-page"
      refute slug =~ "/"
      refute slug =~ "_"
    end

    test "deterministic — same inputs yield the same slug" do
      assert Registry.preview_slug_for("shop", "dev") ==
               Registry.preview_slug_for("shop", "dev")
    end

    test "branches that sanitize alike stay distinct (hash of the raw branch)" do
      a = Registry.preview_slug_for("shop", "feat/x")
      b = Registry.preview_slug_for("shop", "feat-x")
      refute a == b
      assert valid_label?(a)
      assert valid_label?(b)
    end

    test "a very long branch is clamped to a valid 63-char label" do
      slug = Registry.preview_slug_for("shop", String.duplicate("very-long-branch-", 20))
      assert valid_label?(slug)
    end

    test "a very long site slug still leaves room for the branch + hash" do
      slug = Registry.preview_slug_for(String.duplicate("a", 60), "dev")
      assert valid_label?(slug)
    end

    test "an all-punctuation branch falls back to the hash, still valid" do
      slug = Registry.preview_slug_for("shop", "///___///")
      assert valid_label?(slug)
      assert String.starts_with?(slug, "shop--")
    end
  end

  describe "preview_host_for/2" do
    test "host is <slug>.<base_domain>" do
      host = Registry.preview_host_for("shop", "dev")
      assert String.ends_with?(host, ".barkpark.cloud")
      slug = Registry.preview_slug_for("shop", "dev")
      assert host == slug <> ".barkpark.cloud"
    end
  end
end
