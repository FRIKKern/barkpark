defmodule Barkpark.PreviewTokenTest do
  use Barkpark.DataCase, async: true

  alias Barkpark.PreviewToken

  @secret "test-preview-secret-1234567890abcdef"

  describe "sign/2 and verify/2" do
    test "round-trips claims successfully" do
      {jwt, claims} = PreviewToken.sign(%{dataset: "production", doc_ids: ["p1"]}, @secret)
      {:ok, _} = PreviewToken.record_jti(stringify(claims))

      assert {:ok, decoded} = PreviewToken.verify(jwt, @secret)
      assert decoded["dataset"] == "production"
      assert decoded["doc_ids"] == ["p1"]
      assert decoded["iss"] == "barkpark"
      assert is_binary(decoded["jti"])
    end

    test "verify/2 alone does not reject a never-recorded jti" do
      {jwt, _claims} = PreviewToken.sign(%{dataset: "production"}, @secret)
      assert {:ok, _} = PreviewToken.verify(jwt, @secret)
    end

    test "detects tampered payload" do
      {jwt, claims} = PreviewToken.sign(%{dataset: "production"}, @secret)
      {:ok, _} = PreviewToken.record_jti(stringify(claims))

      [header, _payload, sig] = String.split(jwt, ".")
      tampered_payload = Base.url_encode64(~s({"dataset":"leaked","exp":99999999999}), padding: false)
      tampered = header <> "." <> tampered_payload <> "." <> sig

      assert {:error, :bad_signature} = PreviewToken.verify(tampered, @secret)
    end

    test "detects expired claim" do
      past = System.system_time(:second) - 100

      claims = %{
        iss: "barkpark",
        iat: past - 1000,
        exp: past,
        dataset: "production",
        doc_ids: [],
        jti: Ecto.UUID.generate()
      }

      {jwt, full} = PreviewToken.sign(claims, @secret)
      {:ok, _} = PreviewToken.record_jti(stringify(full))

      assert {:error, :expired} = PreviewToken.verify(jwt, @secret)
    end

    test "returns :invalid on malformed input" do
      assert {:error, :invalid} = PreviewToken.verify("not-a-jwt", @secret)
    end
  end

  describe "record_jti, revoke, revoked?" do
    test "cycle: record → not revoked → revoke → revoked" do
      {_, claims} = PreviewToken.sign(%{dataset: "production"}, @secret)
      string_claims = stringify(claims)
      jti = string_claims["jti"]

      {:ok, _} = PreviewToken.record_jti(string_claims)
      refute PreviewToken.revoked?(jti)

      :ok = PreviewToken.revoke(jti)
      assert PreviewToken.revoked?(jti)
    end

    test "revoked? is false for unknown jti (never recorded)" do
      refute PreviewToken.revoked?(Ecto.UUID.generate())
    end

    test "record_jti second call returns {:error, :already_used} (replay)" do
      {_, claims} = PreviewToken.sign(%{dataset: "production"}, @secret)
      string_claims = stringify(claims)

      assert {:ok, _} = PreviewToken.record_jti(string_claims)
      assert {:error, :already_used} = PreviewToken.record_jti(string_claims)
    end

    test "verify returns :revoked after revocation" do
      {jwt, claims} = PreviewToken.sign(%{dataset: "production"}, @secret)
      string_claims = stringify(claims)
      {:ok, _} = PreviewToken.record_jti(string_claims)
      :ok = PreviewToken.revoke(string_claims["jti"])

      assert {:error, :revoked} = PreviewToken.verify(jwt, @secret)
    end
  end

  describe "verify_and_record/2" do
    test "first call returns {:ok, claims}; replay returns {:error, :already_used}" do
      {jwt, _} = PreviewToken.sign(%{dataset: "production", doc_ids: ["p1"]}, @secret)

      assert {:ok, claims} = PreviewToken.verify_and_record(jwt, @secret)
      assert claims["dataset"] == "production"

      assert {:error, :already_used} = PreviewToken.verify_and_record(jwt, @secret)
    end

    test "propagates verify errors untouched" do
      assert {:error, :invalid} = PreviewToken.verify_and_record("not-a-jwt", @secret)
    end
  end

  describe "sweep/1" do
    test "removes rows past grace period" do
      {_, claims} = PreviewToken.sign(%{dataset: "production"}, @secret)
      string_claims = stringify(claims)
      {:ok, _} = PreviewToken.record_jti(string_claims)

      far_future = DateTime.add(DateTime.utc_now(), 10_000, :second)
      assert {:ok, n} = PreviewToken.sweep(far_future)
      assert n >= 1
      refute PreviewToken.revoked?(string_claims["jti"])
    end

    test "keeps rows within grace period" do
      {_, claims} = PreviewToken.sign(%{dataset: "production"}, @secret)
      string_claims = stringify(claims)
      {:ok, _} = PreviewToken.record_jti(string_claims)

      assert {:ok, 0} = PreviewToken.sweep(DateTime.utc_now())
    end
  end

  defp stringify(claims), do: Map.new(claims, fn {k, v} -> {to_string(k), v} end)
end
