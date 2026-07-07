defmodule Barkpark.Plugins.Github.SignatureTest do
  @moduledoc """
  Wave-1 slice-5: the pure `X-Hub-Signature-256` verifier. No route, no plug —
  just HMAC-SHA256 sign + constant-time verify, asserting byte-exactness and
  fail-closed on tamper / wrong secret / malformed header / blank secret.
  """

  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Github.Signature

  @secret "s3cr3t-webhook-key"
  @body ~s({"action":"opened","issue":{"number":42,"title":"Bug"}})

  describe "sign/2" do
    test "produces GitHub's sha256=<lower-hex> shape" do
      sig = Signature.sign(@body, @secret)
      assert String.starts_with?(sig, "sha256=")
      hex = String.replace_prefix(sig, "sha256=", "")
      # HMAC-SHA256 → 32 bytes → 64 lower-hex chars.
      assert String.length(hex) == 64
      assert hex == String.downcase(hex)
      assert hex =~ ~r/\A[0-9a-f]{64}\z/
    end

    test "is deterministic for the same body + secret" do
      assert Signature.sign(@body, @secret) == Signature.sign(@body, @secret)
    end
  end

  describe "verify/3" do
    test "a body signed with the secret verifies :ok" do
      header = Signature.sign(@body, @secret)
      assert Signature.verify(@body, header, @secret) == :ok
    end

    test "a tampered body fails" do
      header = Signature.sign(@body, @secret)
      tampered = @body <> "!"
      assert Signature.verify(tampered, header, @secret) == {:error, :bad_signature}
    end

    test "a wrong secret fails" do
      header = Signature.sign(@body, @secret)
      assert Signature.verify(@body, header, "not-the-secret") == {:error, :bad_signature}
    end

    test "verification is byte-exact — a whitespace change fails" do
      header = Signature.sign(@body, @secret)
      whitespaced = @body <> "\n"
      assert Signature.verify(whitespaced, header, @secret) == {:error, :bad_signature}

      # And a whitespace change INSIDE the body (re-encode drift) also fails.
      reencoded = String.replace(@body, "\"action\":", "\"action\": ")
      refute reencoded == @body
      assert Signature.verify(reencoded, header, @secret) == {:error, :bad_signature}
    end

    test "a malformed header fails closed (never raises)" do
      assert Signature.verify(@body, "", @secret) == {:error, :bad_signature}
      assert Signature.verify(@body, "sha256=", @secret) == {:error, :bad_signature}
      assert Signature.verify(@body, "garbage", @secret) == {:error, :bad_signature}
      assert Signature.verify(@body, "sha1=deadbeef", @secret) == {:error, :bad_signature}
    end

    test "a blank/nil secret fails closed (no empty-key forge)" do
      # An attacker who knows the empty-key HMAC could otherwise forge a match.
      forged = Signature.sign(@body, "x")
      assert Signature.verify(@body, forged, "") == {:error, :bad_signature}
      assert Signature.verify(@body, forged, nil) == {:error, :bad_signature}
    end

    test "a non-binary body fails closed" do
      header = Signature.sign(@body, @secret)
      assert Signature.verify(nil, header, @secret) == {:error, :bad_signature}
      assert Signature.verify(%{}, header, @secret) == {:error, :bad_signature}
    end
  end
end
