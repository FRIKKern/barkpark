defmodule Barkpark.Tasks.JudgeTest do
  @moduledoc "Unit tests for the tier-2 judge — mocked HTTP adapter, no network."
  use ExUnit.Case, async: false

  alias Barkpark.Tasks.Judge

  # A fake adapter that returns whatever the test parked in Application env.
  defmodule FakeAdapter do
    def post(_url, _body, _headers) do
      case Application.get_env(:barkpark, :judge_fake) do
        {:ok, text} -> {:ok, 200, %{"content" => [%{"type" => "text", "text" => text}]}}
        {:status, s} -> {:ok, s, %{}}
        {:error, r} -> {:error, r}
        other -> other
      end
    end
  end

  setup do
    prev = {
      Application.get_env(:barkpark, :judge_http_adapter),
      Application.get_env(:barkpark, :anthropic_api_key),
      Application.get_env(:barkpark, :judge_fake)
    }

    Application.put_env(:barkpark, :judge_http_adapter, FakeAdapter)

    on_exit(fn ->
      {a, k, f} = prev
      restore(:judge_http_adapter, a)
      restore(:anthropic_api_key, k)
      restore(:judge_fake, f)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:barkpark, key)
  defp restore(key, val), do: Application.put_env(:barkpark, key, val)

  defp with_key, do: Application.put_env(:barkpark, :anthropic_api_key, "sk-test")

  defp a,
    do: %{
      title: "add rate limiting",
      description: "throttle mutate writes",
      parent: "e1",
      lifecycle: "open"
    }

  defp b,
    do: %{
      title: "add rate limiting",
      description: "throttle mutate writes",
      parent: "e2",
      lifecycle: "open"
    }

  test "configured?/0 tracks the key" do
    refute Judge.configured?()
    with_key()
    assert Judge.configured?()
  end

  test "no key → {:error, :not_configured}, no HTTP call" do
    assert Judge.judge(a(), b()) == {:error, :not_configured}
  end

  test "parses a structured verdict from a 200" do
    with_key()

    Application.put_env(
      :barkpark,
      :judge_fake,
      {:ok, ~s({"relation":"duplicate","confidence":0.9,"reason":"same change"})}
    )

    assert {:ok, %{relation: "duplicate", confidence: conf, reason: "same change"}} =
             Judge.judge(a(), b())

    assert_in_delta conf, 0.9, 0.0001
  end

  test "a distinct verdict parses too" do
    with_key()

    Application.put_env(
      :barkpark,
      :judge_fake,
      {:ok, ~s({"relation":"distinct","confidence":0.8,"reason":"different"})}
    )

    assert {:ok, %{relation: "distinct"}} = Judge.judge(a(), b())
  end

  test "non-200 → error (caller falls back to tier-1)" do
    with_key()
    Application.put_env(:barkpark, :judge_fake, {:status, 429})
    assert {:error, {:http_status, 429}} = Judge.judge(a(), b())
  end

  test "transport error → error" do
    with_key()
    Application.put_env(:barkpark, :judge_fake, {:error, :timeout})
    assert {:error, :timeout} = Judge.judge(a(), b())
  end

  test "unparseable body → error" do
    with_key()
    Application.put_env(:barkpark, :judge_fake, {:ok, "not json at all"})
    assert {:error, :unparseable} = Judge.judge(a(), b())
  end
end
