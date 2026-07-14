defmodule Barkpark.Connectors.ConnectTicketTest do
  @moduledoc """
  The connect-ticket signer (Connectors D50).

  THE GOLDEN VECTOR is the point of this file. The bridge
  (`connectors/src/connect/ticket.ts`) pins the SAME literal. If Elixir and Node
  disagree about a single byte of the payload — key order, a space, base64
  padding, whether the HMAC covers the raw JSON or its base64 — then EVERY
  connect attempt 401s, both test suites stay green, and nothing else in the
  system would catch it. That is exactly the class of failure this wave's review
  called out (three incompatible webhook contracts, each green in isolation).
  """
  use ExUnit.Case, async: true

  alias Barkpark.Connectors.ConnectTicket

  @golden "eyJ3IjoiMTExMTExMTEtMjIyMi0zMzMzLTQ0NDQtNTU1NTU1NTU1NTU1IiwicCI6InRlbGVncmFtIiwibiI6IjAxMjM0NTY3ODlhYmNkZWYiLCJ0IjoxNzUyNDgwMDAwMDAwfQ.lKEgXtxTstQoQlBxCdvvPhY23Cq0reI9BHzzPzpdxO0"

  @secret "golden-connect-secret"
  @ws "11111111-2222-3333-4444-555555555555"

  describe "the golden vector (cross-language contract)" do
    test "sign/3 reproduces the charter's vector byte-for-byte" do
      assert {:ok, @golden} =
               ConnectTicket.sign(@ws, "telegram",
                 secret: @secret,
                 nonce: "0123456789abcdef",
                 issued_at_ms: 1_752_480_000_000
               )
    end

    test "the payload half decodes to the EXACT key order w,p,n,t with no spaces" do
      {:ok, ticket} =
        ConnectTicket.sign(@ws, "telegram",
          secret: @secret,
          nonce: "0123456789abcdef",
          issued_at_ms: 1_752_480_000_000
        )

      [body, sig] = String.split(ticket, ".")

      assert {:ok, json} = Base.url_decode64(body, padding: false)

      assert json ==
               ~s({"w":"11111111-2222-3333-4444-555555555555","p":"telegram","n":"0123456789abcdef","t":1752480000000})

      # The MAC covers the BASE64 body, not the raw JSON — the bridge's
      # verifyOAuthState lineage does the same. Getting this backwards produces a
      # perfectly valid-looking ticket that never verifies.
      assert sig ==
               :crypto.mac(:hmac, :sha256, @secret, body) |> Base.url_encode64(padding: false)

      refute String.contains?(ticket, "=")
    end

    test "a different secret produces a different signature (the MAC is live)" do
      opts = [nonce: "0123456789abcdef", issued_at_ms: 1_752_480_000_000]

      {:ok, a} = ConnectTicket.sign(@ws, "telegram", [secret: @secret] ++ opts)
      {:ok, b} = ConnectTicket.sign(@ws, "telegram", [secret: "other-secret"] ++ opts)

      refute a == b
      assert hd(String.split(a, ".")) == hd(String.split(b, "."))
    end
  end

  describe "fail-closed" do
    test "no configured secret => {:error, :not_configured}, never a crash" do
      # The default test config carries no connect secret — an instance without
      # connectors is a normal instance.
      assert {:error, :not_configured} = ConnectTicket.sign(@ws, "telegram")
    end

    test "a non-UUID workspace id is refused (the payload is hand-assembled — no JSON escaping exists)" do
      assert {:error, :invalid_workspace} =
               ConnectTicket.sign(~s(not-a-uuid","p":"evil), "telegram", secret: @secret)
    end

    test "a provider id outside [a-z0-9_-] is refused" do
      assert {:error, :invalid_provider} =
               ConnectTicket.sign(@ws, ~s(telegram","x":"y), secret: @secret)
    end
  end

  test "the nonce is random per call" do
    {:ok, a} = ConnectTicket.sign(@ws, "telegram", secret: @secret)
    {:ok, b} = ConnectTicket.sign(@ws, "telegram", secret: @secret)
    refute a == b
  end
end
