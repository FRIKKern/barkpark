defmodule Barkpark.PortableDoc.HtmlSanitizerCacheTest do
  @moduledoc """
  task-13c9d34562701725: the scrub of a legacy `body_html` ran on every
  read of the Paper. Its output is kept, keyed by the body's hash, and
  served only under the sanitizer's current policy version.
  """
  # The app env (`:max_passes`) and the shared table.
  use ExUnit.Case, async: false

  alias Barkpark.PortableDoc.HtmlSanitizer
  alias Barkpark.PortableDoc.HtmlSanitizer.Cache

  setup do
    Cache.enable_for_process()
    Cache.invalidate()
    :ok
  end

  # How many times the scrub parsed a body while `fun` ran in this process:
  # each pass parses once. A tracer process counts, and every trace message
  # is delivered before the count is read.
  defp parses(fun) do
    me = self()
    counter = spawn_link(fn -> count(0) end)
    :erlang.trace(me, true, [:call, {:tracer, counter}])
    :erlang.trace_pattern({LazyHTML, :from_fragment, 1}, true, [])

    try do
      out = fun.()
      ref = :erlang.trace_delivered(me)
      receive do: ({:trace_delivered, ^me, ^ref} -> :ok)
      send(counter, {:count, me})
      receive do: ({:count, n} -> {out, n})
    after
      :erlang.trace(me, false, [:call])
      :erlang.trace_pattern({LazyHTML, :from_fragment, 1}, false, [])
    end
  end

  defp count(n) do
    receive do
      {:trace, _pid, :call, _mfa} -> count(n + 1)
      {:count, to} -> send(to, {:count, n})
    end
  end

  @body ~s{<h2 id="a">Title</h2><p>Some <a href="#a">words</a> <script>x()</script></p>}

  test "a second read of the same body does not scrub it again" do
    {first, n1} = parses(fn -> HtmlSanitizer.sanitize(@body, id: "p1") end)
    {again, n2} = parses(fn -> HtmlSanitizer.sanitize(@body, id: "p1") end)

    assert n1 > 0
    assert n2 == 0
    assert again == first
    refute first =~ "script"
  end

  test "a changed body is scrubbed" do
    HtmlSanitizer.sanitize(@body, id: "p1")
    {out, n} = parses(fn -> HtmlSanitizer.sanitize(@body <> "<p>more</p>", id: "p1") end)

    assert n > 0
    assert out =~ "more"
  end

  test "another Paper's id is another entry: it decides a same-page link" do
    HtmlSanitizer.sanitize(@body, id: "p1")
    {_out, n} = parses(fn -> HtmlSanitizer.sanitize(@body, id: "p2") end)
    assert n > 0
  end

  test "a changed rule is a changed version, and the body is scrubbed again" do
    HtmlSanitizer.sanitize(@body, id: "p1")
    before = Cache.version()
    old = Application.get_env(:barkpark, HtmlSanitizer)

    try do
      Application.put_env(:barkpark, HtmlSanitizer, max_passes: 1)
      refute Cache.version() == before
      {_out, n} = parses(fn -> HtmlSanitizer.sanitize(@body, id: "p1") end)
      assert n > 0
    after
      if old,
        do: Application.put_env(:barkpark, HtmlSanitizer, old),
        else: Application.delete_env(:barkpark, HtmlSanitizer)
    end
  end

  test "the version is a function of the rule tables: one more kept element moves it" do
    tables = %{kept: ~w(p h2 a), style: %{"color" => :any}}

    assert Cache.version(tables) == Cache.version(tables)
    refute Cache.version(%{tables | kept: ["div" | tables.kept]}) == Cache.version(tables)
  end

  test "the editor's scrub and a call with its own pass cap are never cached" do
    HtmlSanitizer.sanitize(@body, editor: true)
    {_out, n} = parses(fn -> HtmlSanitizer.sanitize(@body, editor: true) end)
    assert n > 0

    HtmlSanitizer.sanitize(@body, max_passes: 1)
    {_out, n} = parses(fn -> HtmlSanitizer.sanitize(@body, max_passes: 1) end)
    assert n > 0
  end
end
