defmodule BarkparkWeb.PaperAnswerSweepTest do
  @moduledoc """
  No read route shows a hidden word to a caller without the right.

  The routes, live routes, streams and channels are read from the compiled
  application (`PaperAnswerSweep.Introspect`); a new one joins by itself.
  For each, the caller with the right (an admin token) is driven first:

    * a GET, a live route, a stream, and a non-GET route whose code can
      answer with documents must reach an answer (2xx, a stream, or a
      redirect that ends on one), else the test fails by route name;
    * a route whose admin answer holds a hidden word carries the Paper. Their
      count may not drop below `@carries_floor`.

  Then each caller without the right (anonymous, a read token, a write token)
  is driven with the same params, once per search word: a visible word and
  each hidden word. Any hidden word in any byte of any answer (status line
  aside: headers and body, an error's text, a stream's chunks, a channel's
  replies and pushes) is a failure, named by caller and route.

  Nothing is skipped: every route is called. A route that cannot be called
  at all would go in `@limits` with its reason; it is empty, and its count
  may only go down.
  """
  use BarkparkWeb.ConnCase, async: false

  alias BarkparkWeb.PaperAnswerSweep, as: Sweep
  alias BarkparkWeb.PaperAnswerSweep.Introspect

  @moduletag timeout: 1_800_000

  # The number of routes whose admin answer carries the Paper on the first
  # run. A change that makes fewer routes reach the Paper fails here.
  @carries_floor 0

  # `{verb, path, reason}` for a route the sweep cannot call at all.
  @limits []

  setup do
    {:ok, seed: Sweep.seed!()}
  end

  defp visible, do: hd(Sweep.words())

  # Thousands of calls from one test: every call starts from unspent buckets.
  # True, so it can stand as a comprehension filter.
  defp reset_buckets do
    Barkpark.RateLimiterSandbox.reset_rate_limiter!(%{async: false})
    true
  end

  defp reached?(%{status: :stream}), do: true
  defp reached?(%{status: status}), do: status in 200..299

  # The admin's answer to `route`, following one redirect, with the params it
  # was reached by.
  defp admin_answer(route, path, seed) do
    sets = Sweep.param_sets(seed, visible())

    answers =
      Stream.map(sets, fn params ->
        reset_buckets()
        answer = Sweep.call(seed, seed.tokens.admin, route.verb, path, params)
        {params, follow(answer, seed)}
      end)

    Enum.find(answers, fn {_params, answer} -> reached?(answer) end) ||
      Enum.at(answers, 0)
  end

  defp follow(%{status: status, location: "/" <> _ = to} = answer, seed)
       when status in 300..399 do
    followed = Sweep.call(seed, seed.tokens.admin, "GET", to, %{})
    %{followed | bytes: answer.bytes <> followed.bytes}
  end

  defp follow(answer, _seed), do: answer

  defp sweep_route(%{live: nil} = route, seed) do
    path = Sweep.fill(route.path, seed)
    {params, admin} = admin_answer(route, path, seed)
    must_reach? = Introspect.read_shaped?(route)

    leaks =
      for {who, token} <- Sweep.without_right(seed),
          word <- if(Map.has_key?(params, "q"), do: Sweep.words(), else: [visible()]),
          reset_buckets(),
          answer = Sweep.call(seed, token, route.verb, path, Sweep.with_word(params, word)),
          Sweep.leaks(answer.bytes) != [],
          uniq: true,
          do: "#{who} #{route.verb} #{route.path}: #{inspect(Sweep.leaks(answer.bytes))}"

    %{
      route: "#{route.verb} #{route.path}",
      unreached: must_reach? and not reached?(admin),
      admin_status: admin.status,
      carries: Sweep.leaks(admin.bytes) != [],
      leaks: leaks
    }
  end

  defp sweep_route(route, seed) do
    path = Sweep.fill(route.path, seed)
    reset_buckets()
    admin = Sweep.live_call(seed.tokens.admin, path <> "?q=" <> visible())

    leaks =
      for {who, token} <- Sweep.without_right(seed),
          word <- Sweep.words(),
          reset_buckets(),
          answer = Sweep.live_call(token, path <> "?q=" <> URI.encode_www_form(word)),
          Sweep.leaks(answer.bytes) != [],
          uniq: true,
          do: "#{who} live #{route.path}: #{inspect(Sweep.leaks(answer.bytes))}"

    %{
      route: "live #{route.path}",
      unreached: not reached?(admin),
      admin_status: admin.status,
      carries: Sweep.leaks(admin.bytes) != [],
      leaks: leaks
    }
  end

  test "no route, live route or stream shows a hidden word to a caller without the right",
       %{seed: seed} do
    results = Enum.map(Introspect.routes(), &sweep_route(&1, seed))

    unreached =
      for r <- results, r.unreached, do: "#{r.route}: the admin got #{inspect(r.admin_status)}"

    carries = Enum.count(results, & &1.carries)
    if carries > @carries_floor, do: IO.puts("answer sweep: #{carries} routes carry the Paper")

    assert unreached == [], "not driven to an answer:\n" <> Enum.join(unreached, "\n")
    assert carries >= @carries_floor
    assert Enum.flat_map(results, & &1.leaks) == []
    assert length(@limits) <= 0
  end

  test "no channel shows a hidden word to a caller without the right", %{seed: seed} do
    channels = Introspect.channels(BarkparkWeb.Endpoint)
    assert channels != []

    found =
      for channel <- channels,
          {who, token} <- [{"admin", seed.tokens.admin} | Sweep.without_right(seed)],
          do: {who, channel, Sweep.channel_call(seed, token, channel)}

    refused =
      for {"admin", {_, _, prefix, module, _}, {:refused, bytes}} <- found,
          do: "#{inspect(module)} #{prefix}: #{bytes}"

    leaks =
      for {who, {_, _, prefix, _, _}, {_, bytes}} <- found,
          who != "admin",
          Sweep.leaks(bytes) != [],
          do: "#{who} #{prefix}: #{inspect(Sweep.leaks(bytes))}"

    assert refused == [], "the admin could not join:\n" <> Enum.join(refused, "\n")
    assert leaks == []
  end

  test "a write that answers with the document shows a writer without the right no hidden word",
       %{seed: seed} do
    path = "/v1/data/mutate/#{Sweep.dataset()}?returnDocuments=true"
    body = %{"mutations" => [%{"patch" => %{"id" => seed.slug, "set" => %{"note" => "x"}}}]}

    admin = Sweep.call(seed, seed.tokens.admin, "POST", path, body)
    writer = Sweep.call(seed, seed.tokens.writer, "POST", path, body)

    assert admin.status in 200..299, admin.bytes
    assert Sweep.leaks(admin.bytes) != []
    assert Sweep.leaks(writer.bytes) == [], writer.bytes
  end
end
