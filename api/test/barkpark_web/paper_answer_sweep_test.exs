defmodule BarkparkWeb.PaperAnswerSweepTest do
  @moduledoc """
  No read route shows a hidden word to a caller without the right.

  The routes, live routes, streams and channels are read from the compiled
  application (`PaperAnswerSweep.Introspect`); a new one joins by itself.
  Every route is called, and the read-shaped ones (every GET and live route,
  and each non-GET route whose code can answer with documents) are split
  into two, with nothing left over:

    * a CARRIER: the caller with the right (an admin token) gets a 2xx or a
      stream holding a hidden word;
    * a route on `@no_paper_fields`, each with its reason: it cannot answer
      with a Paper's fields, so its admin answer never holds a hidden word.

  A read-shaped route in neither fails by name, and so does a listed route
  whose admin answer holds a hidden word. Carriers plus listed routes must
  equal the read-shaped routes introspection finds.

  Each caller without the right (anonymous, a read token, a write token) is
  then driven on every route with the admin's params, once per search word:
  a visible word and each hidden word. Any hidden word in any byte it is
  answered (headers and body of any status, an error's text, a stream's
  chunks, a channel's replies and pushes) fails, named by caller and route.

  A route that cannot be called at all would go in `@limits` with its
  reason; it is empty, and its count may only go down.
  """
  use BarkparkWeb.ConnCase, async: false

  alias BarkparkWeb.PaperAnswerSweep, as: Sweep
  alias BarkparkWeb.PaperAnswerSweep.Introspect

  @moduletag timeout: 1_800_000

  # `{verb, path, reason}`: read-shaped routes that cannot answer with a
  # Paper's fields. Each row's controller is read by the reviewer.
  @no_paper_fields []

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

  # The admin's answer to `route`, following one redirect, and the params it
  # came from: the first param set that carries the Paper, else the first
  # that is answered 2xx, else the first.
  defp admin_answer(route, path, seed) do
    sets = Sweep.param_sets(seed, visible())

    answers =
      Stream.map(sets, fn params ->
        reset_buckets()
        answer = Sweep.call(seed, seed.tokens.admin, route.verb, path, params)
        {params, follow(answer, seed)}
      end)

    answers = Enum.to_list(answers)

    Enum.find(answers, fn {_, a} -> reached?(a) and Sweep.leaks(a.bytes) != [] end) ||
      Enum.find(answers, fn {_, a} -> reached?(a) end) || hd(answers)
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

    leaks =
      for {who, token} <- Sweep.without_right(seed),
          word <- if(Map.has_key?(params, "q"), do: Sweep.words(), else: [visible()]),
          reset_buckets(),
          answer = Sweep.call(seed, token, route.verb, path, Sweep.with_word(params, word)),
          Sweep.leaks(answer.bytes) != [],
          uniq: true,
          do: "#{who} #{route.verb} #{route.path}: #{inspect(Sweep.leaks(answer.bytes))}"

    %{
      key: {route.verb, route.path},
      read_shaped: Introspect.read_shaped?(route),
      admin_status: admin.status,
      carrier: reached?(admin) and Sweep.leaks(admin.bytes) != [],
      admin_holds: Sweep.leaks(admin.bytes) != [],
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
      key: {route.verb, route.path},
      read_shaped: true,
      admin_status: admin.status,
      carrier: reached?(admin) and Sweep.leaks(admin.bytes) != [],
      admin_holds: Sweep.leaks(admin.bytes) != [],
      leaks: leaks
    }
  end

  test "no route, live route or stream shows a hidden word to a caller without the right",
       %{seed: seed} do
    results = Enum.map(Introspect.routes(), &sweep_route(&1, seed))
    listed = Map.new(@no_paper_fields, fn {verb, path, reason} -> {{verb, path}, reason} end)
    name = fn {verb, path} -> "#{verb} #{path}" end

    neither =
      for r <- results,
          r.read_shaped,
          not r.carrier,
          not Map.has_key?(listed, r.key),
          do: "#{name.(r.key)}: the admin got #{inspect(r.admin_status)} without the Paper"

    listed_but_carries =
      for r <- results,
          Map.has_key?(listed, r.key),
          r.admin_holds,
          do: "#{name.(r.key)} is listed (#{listed[r.key]}) but answers with Paper fields"

    read_shaped = Enum.count(results, & &1.read_shaped)
    carriers = Enum.count(results, &(&1.read_shaped and &1.carrier))

    no_debug_info =
      for %{verb: verb, live: nil, plug: plug} <- Introspect.routes(),
          verb != "GET",
          Introspect.definitions(plug) == nil,
          do: plug

    IO.puts(
      "answer sweep: #{length(results)} routes, #{read_shaped} read-shaped " <>
        "(#{length(no_debug_info)} for lack of debug info), #{carriers} carriers, " <>
        "#{map_size(listed)} listed, #{Sweep.requests()} requests"
    )

    assert neither == [], "read-shaped, neither carrier nor listed:\n" <> Enum.join(neither, "\n")
    assert listed_but_carries == [], Enum.join(listed_but_carries, "\n")
    assert carriers + map_size(listed) == read_shaped
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
