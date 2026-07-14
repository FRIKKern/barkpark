defmodule BarkparkCloud.Registry.ProviderTest do
  @moduledoc """
  The connected-provider schema is provider-neutral (hetzner + azure) with ONE
  credential home (`encrypted_token`). These tests are pure — no DB — asserting
  the changeset's kind grammar and its per-kind credential-SHAPE gate:

    * both kinds are accepted; an unknown kind is rejected
    * hetzner demands a non-blank token string
    * azure demands the four-field service-principal JSON blob (all present),
      and rejects a missing field or malformed JSON
    * the stored column stays `encrypted_token` — the shape is checked via the
      virtual `:credential` field, so the error attaches to the credential the
      caller sent, never the ciphertext column
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.Registry.Provider

  @team_id "00000000-0000-0000-0000-000000000001"

  defp azure_blob(overrides \\ %{}) do
    %{
      "tenant_id" => "11111111-1111-1111-1111-111111111111",
      "client_id" => "22222222-2222-2222-2222-222222222222",
      "client_secret" => "s3cr3t-value",
      "subscription_id" => "33333333-3333-3333-3333-333333333333"
    }
    |> Map.merge(overrides)
    |> Jason.encode!()
  end

  defp changeset(attrs) do
    Provider.changeset(%Provider{}, Map.merge(%{team_id: @team_id}, attrs))
  end

  describe "kinds/0 + inclusion" do
    test "hetzner, azure, and cloudflare are known kinds" do
      assert "hetzner" in Provider.kinds()
      assert "azure" in Provider.kinds()
      assert "cloudflare" in Provider.kinds()
    end

    test "a hetzner credential is valid" do
      cs = changeset(%{kind: "hetzner", credential: "hz-token", encrypted_token: "ciphertext"})
      assert cs.valid?
    end

    test "an azure credential is valid" do
      cs = changeset(%{kind: "azure", credential: azure_blob(), encrypted_token: "ciphertext"})
      assert cs.valid?
    end

    test "an unknown kind is rejected" do
      cs = changeset(%{kind: "aws", credential: "whatever", encrypted_token: "ciphertext"})
      refute cs.valid?
      assert %{kind: ["is invalid"]} = errors_on(cs)
    end

    test "encrypted_token is required regardless of kind" do
      cs = changeset(%{kind: "hetzner", credential: "hz-token"})
      refute cs.valid?
      assert %{encrypted_token: ["can't be blank"]} = errors_on(cs)
    end
  end

  describe "hetzner credential shape" do
    test "a blank token is rejected on the credential field" do
      cs = changeset(%{kind: "hetzner", credential: "   ", encrypted_token: "ciphertext"})
      refute cs.valid?
      assert Map.has_key?(errors_on(cs), :credential)
      # The error is on the virtual credential, NEVER the stored ciphertext.
      refute Map.has_key?(errors_on(cs), :encrypted_token)
    end
  end

  describe "azure credential shape" do
    test "all four service-principal fields present → valid" do
      assert changeset(%{kind: "azure", credential: azure_blob(), encrypted_token: "ct"}).valid?
    end

    test "a missing field is rejected" do
      blob = azure_blob(%{"client_secret" => ""})
      cs = changeset(%{kind: "azure", credential: blob, encrypted_token: "ct"})
      refute cs.valid?
      assert Map.has_key?(errors_on(cs), :credential)
    end

    test "a field absent from the blob entirely is rejected" do
      blob =
        %{
          "tenant_id" => "t",
          "client_id" => "c",
          "subscription_id" => "s"
        }
        |> Jason.encode!()

      cs = changeset(%{kind: "azure", credential: blob, encrypted_token: "ct"})
      refute cs.valid?
      assert Map.has_key?(errors_on(cs), :credential)
    end

    test "malformed (non-JSON) credential is rejected" do
      cs = changeset(%{kind: "azure", credential: "not-json{", encrypted_token: "ct"})
      refute cs.valid?
      assert Map.has_key?(errors_on(cs), :credential)
    end

    test "azure_fields/0 lists the four required fields" do
      assert Enum.sort(Provider.azure_fields()) ==
               ~w(client_id client_secret subscription_id tenant_id)
    end
  end

  describe "cloudflare credential shape" do
    test "a bare API token string is valid" do
      cs =
        changeset(%{
          kind: "cloudflare",
          credential: "cf-bare-token-abc123",
          encrypted_token: "ct"
        })

      assert cs.valid?
    end

    test "a JSON blob carrying api_token (+ optional account/zone) is valid" do
      blob =
        Jason.encode!(%{
          "api_token" => "cf-blob-token",
          "account_id" => "acc-123",
          "zone_id" => "zone-456"
        })

      assert changeset(%{kind: "cloudflare", credential: blob, encrypted_token: "ct"}).valid?
    end

    test "a JSON blob with only api_token (no optional scope) is valid" do
      blob = Jason.encode!(%{"api_token" => "cf-blob-token"})
      assert changeset(%{kind: "cloudflare", credential: blob, encrypted_token: "ct"}).valid?
    end

    test "a blank credential is rejected on the credential field" do
      cs = changeset(%{kind: "cloudflare", credential: "   ", encrypted_token: "ct"})
      refute cs.valid?
      assert Map.has_key?(errors_on(cs), :credential)
      # The error is on the virtual credential, NEVER the stored ciphertext.
      refute Map.has_key?(errors_on(cs), :encrypted_token)
    end

    test "a JSON blob missing api_token is rejected" do
      blob = Jason.encode!(%{"account_id" => "acc-123", "zone_id" => "zone-456"})
      cs = changeset(%{kind: "cloudflare", credential: blob, encrypted_token: "ct"})
      refute cs.valid?
      assert Map.has_key?(errors_on(cs), :credential)
    end

    test "a JSON blob with a blank api_token is rejected" do
      blob = Jason.encode!(%{"api_token" => ""})
      cs = changeset(%{kind: "cloudflare", credential: blob, encrypted_token: "ct"})
      refute cs.valid?
      assert Map.has_key?(errors_on(cs), :credential)
    end
  end

  describe "credential is never stored / relabel skips the shape gate" do
    test "a changeset without a :credential (e.g. a relabel) skips the shape gate" do
      # A row that already has ciphertext, being relabeled — no plaintext passed.
      cs =
        Provider.changeset(%Provider{kind: "azure", encrypted_token: "ct", team_id: @team_id}, %{
          label: "renamed"
        })

      assert cs.valid?
    end
  end

  # A minimal errors_on (mirrors DataCase's) so this stays a pure, DB-free test.
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
