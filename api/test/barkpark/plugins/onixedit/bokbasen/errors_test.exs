defmodule Barkpark.Plugins.OnixEdit.Bokbasen.ErrorsTest do
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.OnixEdit.Bokbasen.Errors

  alias Barkpark.Plugins.OnixEdit.Bokbasen.Errors.{
    AuthError,
    HTTPError,
    NetworkError,
    RateLimitError,
    SchemaRejectionError
  }

  describe "struct enforcement" do
    test "HTTPError requires :status and :endpoint" do
      assert %HTTPError{status: 500, endpoint: "https://x"} = %HTTPError{
               status: 500,
               endpoint: "https://x"
             }

      assert_raise ArgumentError, fn ->
        struct!(HTTPError, %{})
      end
    end

    test "AuthError requires :status" do
      assert %AuthError{status: 401} = %AuthError{status: 401}

      assert_raise ArgumentError, fn ->
        struct!(AuthError, %{})
      end
    end

    test "SchemaRejectionError requires :rejection_details" do
      assert %SchemaRejectionError{rejection_details: %{}} = %SchemaRejectionError{
               rejection_details: %{}
             }

      assert_raise ArgumentError, fn ->
        struct!(SchemaRejectionError, %{})
      end
    end

    test "NetworkError requires :reason" do
      assert %NetworkError{reason: :timeout} = %NetworkError{reason: :timeout}

      assert_raise ArgumentError, fn ->
        struct!(NetworkError, %{})
      end
    end

    test "RateLimitError requires :retry_after_seconds" do
      assert %RateLimitError{retry_after_seconds: 30} = %RateLimitError{retry_after_seconds: 30}

      assert_raise ArgumentError, fn ->
        struct!(RateLimitError, %{})
      end
    end
  end

  describe "Inspect redaction" do
    test "HTTPError redacts authorization headers" do
      err = %HTTPError{
        status: 500,
        endpoint: "https://api.example.com/x",
        headers: %{"authorization" => "Bearer leaked_token_xyz"},
        body: "ok"
      }

      out = inspect(err)
      refute out =~ "leaked_token_xyz"
      assert out =~ "[REDACTED]"
    end

    test "HTTPError redacts capitalised Authorization header" do
      err = %HTTPError{
        status: 500,
        endpoint: "https://api.example.com/x",
        headers: %{"Authorization" => "Bearer leaked_other"},
        body: "ok"
      }

      out = inspect(err)
      refute out =~ "leaked_other"
      assert out =~ "[REDACTED]"
    end

    test "HTTPError redacts JSON access_token in body string" do
      err = %HTTPError{
        status: 500,
        endpoint: "https://x",
        body: ~s({"access_token":"shh","other":"safe"}),
        headers: %{}
      }

      out = inspect(err)
      refute out =~ "shh"
      assert out =~ "[REDACTED]"
      assert out =~ "safe"
    end

    test "HTTPError redacts JSON client_secret in body string" do
      err = %HTTPError{
        status: 500,
        endpoint: "https://x",
        body: ~s({"client_secret":"super_secret_42"}),
        headers: %{}
      }

      out = inspect(err)
      refute out =~ "super_secret_42"
    end

    test "HTTPError redacts client_secret/client_id in map body" do
      err = %HTTPError{
        status: 500,
        endpoint: "https://x",
        body: %{"client_id" => "leak_id", "client_secret" => "leak_secret"},
        headers: %{}
      }

      out = inspect(err)
      refute out =~ "leak_id"
      refute out =~ "leak_secret"
    end

    test "redact/1 helper redacts nested maps" do
      input = %{
        "headers" => %{"Authorization" => "Bearer t1"},
        "json" => %{"access_token" => "t2"}
      }

      result = Errors.redact(input)

      assert result == %{
               "headers" => %{"Authorization" => "[REDACTED]"},
               "json" => %{"access_token" => "[REDACTED]"}
             }
    end
  end
end
