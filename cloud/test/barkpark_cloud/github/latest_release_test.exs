defmodule BarkparkCloud.GitHub.LatestReleaseTest do
  # async: false — the cache is one :persistent_term entry per node.
  use ExUnit.Case, async: false

  alias BarkparkCloud.GitHub.LatestRelease

  setup do
    LatestRelease.reset()
    on_exit(&LatestRelease.reset/0)
    :ok
  end

  defp tags(names), do: Jason.encode!(Enum.map(names, &%{"name" => &1}))

  # A transport that answers from a list and records each request.
  defp scripted(responses) do
    {:ok, agent} = Agent.start_link(fn -> {responses, []} end)

    fun = fn req ->
      Agent.get_and_update(agent, fn {[r | rest], seen} -> {r, {rest, [req | seen]}} end)
    end

    {fun, fn -> agent |> Agent.get(&elem(&1, 1)) |> Enum.reverse() end}
  end

  defp ok(status, body \\ "", etag \\ nil) do
    headers = if etag, do: [{"etag", etag}], else: []
    {:ok, %{status: status, body: body, headers: headers}}
  end

  test "reads the highest bare vA.B.C tag, as the box does" do
    {http, seen} =
      scripted([ok(200, tags(["cli-v9.9.9", "v0.2.9", "v0.2.34", "v0.2.10"]), ~s("e1"))])

    assert {:ok, %{release: "0.2.34", etag: ~s("e1")}} = LatestRelease.fetch(http_client: http)

    [req] = seen.()
    assert req.url == "https://api.github.com/repos/FRIKKern/barkpark/tags?per_page=100"
    refute List.keymember?(req.headers, "if-none-match", 0)
  end

  test "sends the etag back and reuses the cached answer on 304" do
    {http, seen} = scripted([ok(200, tags(["v0.2.33"]), ~s("e1")), ok(304)])

    {:ok, first} = LatestRelease.fetch(http_client: http)
    assert {:ok, ^first} = LatestRelease.fetch(http_client: http)

    [_, second] = seen.()
    assert {"if-none-match", ~s("e1")} in second.headers
  end

  test "observed_at moves only when the release changes" do
    {http, _seen} =
      scripted([
        ok(200, tags(["v0.2.33"]), ~s("e1")),
        ok(200, tags(["v0.2.33", "cli-v1.0.0"]), ~s("e2")),
        ok(200, tags(["v0.2.34", "v0.2.33"]), ~s("e3"))
      ])

    {:ok, _} = LatestRelease.fetch(http_client: http)

    # Age the cached entry so a reset is visible.
    long_ago = ~U[2026-01-01 00:00:00Z]
    key = {LatestRelease, :cache}
    :persistent_term.put(key, %{:persistent_term.get(key) | observed_at: long_ago})

    {:ok, b} = LatestRelease.fetch(http_client: http)
    assert b.release == "0.2.33"
    assert b.etag == ~s("e2")
    assert b.observed_at == long_ago

    {:ok, c} = LatestRelease.fetch(http_client: http)
    assert c.release == "0.2.34"
    assert DateTime.compare(c.observed_at, long_ago) == :gt
  end

  test "failures are errors, never a release" do
    {http, _} =
      scripted([
        ok(403),
        ok(500),
        ok(200, "not json"),
        ok(200, tags(["cli-v1.0.0"])),
        {:error, :timeout}
      ])

    assert LatestRelease.fetch(http_client: http) == {:error, :rate_limited}
    assert LatestRelease.fetch(http_client: http) == {:error, {:http_status, 500}}
    assert LatestRelease.fetch(http_client: http) == {:error, :unusable_body}
    assert LatestRelease.fetch(http_client: http) == {:error, :no_release_tags}
    assert LatestRelease.fetch(http_client: http) == {:error, :timeout}
  end

  test "an unconfigured transport is an error" do
    assert LatestRelease.fetch() == {:error, :no_http_client}
  end

  test "parse/1 reads A.B.C with or without a v" do
    assert LatestRelease.parse("0.2.34") == {:ok, {0, 2, 34}}
    assert LatestRelease.parse("v0.2.34") == {:ok, {0, 2, 34}}
    assert LatestRelease.parse("0.2.34.5") == :error
    assert LatestRelease.parse(nil) == :error
  end
end
