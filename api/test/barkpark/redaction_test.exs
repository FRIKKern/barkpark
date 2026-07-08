defmodule Barkpark.RedactionTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Guards the extracted `Barkpark.Redaction` engine AND the three plugin error
  modules that now delegate to it.

  The load-bearing invariant is DISTINCTNESS: the shared engine takes each
  module's allowlists as PARAMETERS, never a union. Each module must redact ONLY
  its own sensitive keys — a key that belongs to a sibling module's allowlist
  must pass through untouched. If the fold ever unions the lists, the
  "redacts only its own keys" tests below go RED. See the module `Github` /
  `Indx` allowlists vs `Bokbasen`'s:

    * github  json: token, access_token
    * indx    json: token, authorization, password, userPassWord, UserPassWord
    * bokbasen json: access_token, client_secret, client_id
  """

  alias Barkpark.Plugins.Github.Errors, as: GithubErrors
  alias Barkpark.Plugins.Indx.Errors, as: IndxErrors
  alias Barkpark.Plugins.OnixEdit.Bokbasen.Errors, as: BokbasenErrors

  describe "shared engine — Barkpark.Redaction.redact/3" do
    test "redacts the values under the given header + json keys, recursively" do
      input = %{
        "headers" => %{"Authorization" => "Bearer t1"},
        "json" => %{"secret_key" => "t2"},
        "safe" => "keep"
      }

      result = Barkpark.Redaction.redact(input, ["Authorization"], ["secret_key"])

      assert result == %{
               "headers" => %{"Authorization" => "[REDACTED]"},
               "json" => %{"secret_key" => "[REDACTED]"},
               "safe" => "keep"
             }
    end

    test "redact_binary uses json_keys ONLY (header keys never scrub raw strings)" do
      body = ~s({"authorization":"raw-header-in-body","secret_key":"shh"})

      # "authorization" passed as a HEADER key, NOT a json key → must NOT scrub
      # the JSON-string occurrence; only "secret_key" (a json key) is scrubbed.
      out = Barkpark.Redaction.redact(body, ["authorization"], ["secret_key"])

      assert out =~ "raw-header-in-body"
      refute out =~ "shh"
      assert out =~ "[REDACTED]"
    end
  end

  describe "Github.Errors.redact/1 — scrubs its OWN keys" do
    test "redacts access_token + authorization header, keeps non-sensitive keys" do
      input = %{
        "headers" => %{"authorization" => "Bearer leaked_gh"},
        "json" => %{"access_token" => "gh_token", "other" => "safe"}
      }

      result = GithubErrors.redact(input)

      assert result["headers"]["authorization"] == "[REDACTED]"
      assert result["json"]["access_token"] == "[REDACTED]"
      assert result["json"]["other"] == "safe"
    end

    test "scrubs access_token in a JSON body string" do
      out = GithubErrors.redact(~s({"access_token":"gh_secret","other":"safe"}))
      refute out =~ "gh_secret"
      assert out =~ "[REDACTED]"
      assert out =~ "safe"
    end
  end

  describe "Indx.Errors.redact/1 — scrubs its OWN keys" do
    test "redacts password + userPassWord, keeps non-sensitive keys" do
      input = %{"password" => "indx_pw", "userPassWord" => "indx_pw2", "other" => "safe"}

      result = IndxErrors.redact(input)

      assert result["password"] == "[REDACTED]"
      assert result["userPassWord"] == "[REDACTED]"
      assert result["other"] == "safe"
    end
  end

  # ── The load-bearing DISTINCTNESS guard ───────────────────────────────────
  # Each module must redact ONLY its own allowlist. A key belonging to a sibling
  # module must pass through. Wiring any delegate to a UNIONED allowlist turns
  # these assertions RED — that is the both-directions proof the lists stay
  # separate through the fold.
  describe "per-module allowlists stay DISTINCT (no union)" do
    test "github redacts access_token but NOT client_secret (bokbasen-only) or password (indx-only)" do
      input = %{
        "access_token" => "gh_own",
        "client_secret" => "bokbasen_only",
        "password" => "indx_only",
        "safe" => "keep"
      }

      result = GithubErrors.redact(input)

      assert result["access_token"] == "[REDACTED]"
      # If github ever unioned in the sibling lists, these two go RED:
      assert result["client_secret"] == "bokbasen_only"
      assert result["password"] == "indx_only"
      assert result["safe"] == "keep"
    end

    test "indx redacts password but NOT access_token (github/bokbasen) or client_secret (bokbasen-only)" do
      input = %{
        "password" => "indx_own",
        "access_token" => "gh_bok_only",
        "client_secret" => "bokbasen_only",
        "safe" => "keep"
      }

      result = IndxErrors.redact(input)

      assert result["password"] == "[REDACTED]"
      # If indx ever unioned in the sibling lists, these two go RED:
      assert result["access_token"] == "gh_bok_only"
      assert result["client_secret"] == "bokbasen_only"
      assert result["safe"] == "keep"
    end

    test "bokbasen redacts client_secret but NOT password (indx-only)" do
      input = %{
        "client_secret" => "bok_own",
        "password" => "indx_only",
        "safe" => "keep"
      }

      result = BokbasenErrors.redact(input)

      assert result["client_secret"] == "[REDACTED]"
      assert result["password"] == "indx_only"
      assert result["safe"] == "keep"
    end
  end
end
