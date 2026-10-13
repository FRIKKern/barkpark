defmodule BarkparkWeb.Components.DatetimeFieldJsTest do
  @moduledoc """
  Owner ruling #46 (task-6a953e4a9ef729a6): Studio saves a date-time as a UTC
  instant, and shows it in the editor's local time.

  The browser's datetime-local input has no time zone; Studio stored what the
  editor typed (`"2026-10-03T10:30"`), and a site reading it in its own zone
  published an Oslo editor's 10:30 at 12:30. The conversion lives in the shipped
  `priv/static/assets/bp-datetime-field.js`; this test loads that exact file
  into node with `TZ=Europe/Oslo` and checks both directions, plus the markup
  the hook needs.

  Node is a hard dependency of this job (see `SheetGrid.JsHarnessTest`), so a
  missing node is a failure, not a skip.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  @asset Path.expand("../../../priv/static/assets/bp-datetime-field.js", __DIR__)

  defp run_js(expr) do
    node = System.find_executable("node") || flunk("node is required for this test")

    script = """
    const fs = require("fs");
    const vm = require("vm");
    const ctx = { globalThis: {} };
    ctx.globalThis = ctx;
    vm.createContext(ctx);
    vm.runInContext(fs.readFileSync(#{inspect(@asset)}, "utf8"), ctx);
    const D = ctx.BarkparkDatetime;
    process.stdout.write(JSON.stringify(#{expr}));
    """

    {out, 0} =
      System.cmd(node, ["-e", script], env: [{"TZ", "Europe/Oslo"}], stderr_to_stdout: true)

    Jason.decode!(out)
  end

  test "an Oslo editor's 10:30 is saved as the 08:30 UTC instant (summer time)" do
    assert run_js(~s|D.toInstant("2026-10-03T10:30")|) == "2026-10-03T08:30:00Z"
  end

  test "winter time uses the winter offset" do
    assert run_js(~s|D.toInstant("2026-12-03T10:30")|) == "2026-12-03T09:30:00Z"
  end

  test "a stored instant is shown in the editor's local wall time" do
    assert run_js(~s|D.toLocalInput("2026-10-03T08:30:00Z")|) == "2026-10-03T10:30"
    assert run_js(~s|D.toLocalInput("2026-10-03T10:30:00+02:00")|) == "2026-10-03T10:30"
  end

  test "the round trip shows the same wall time the editor entered" do
    assert run_js(~s|D.toLocalInput(D.toInstant("2026-03-29T03:15"))|) == "2026-03-29T03:15"
    assert run_js(~s|D.toLocalInput(D.toInstant("2026-07-01T23:59"))|) == "2026-07-01T23:59"
  end

  test "a value stored before #46 (no zone) is shown as written" do
    assert run_js(~s|D.toLocalInput("2026-10-03T10:30")|) == "2026-10-03T10:30"
    assert run_js(~s|D.toLocalInput("2026-10-03")|) == "2026-10-03T00:00"
  end

  test "empty and unparseable values stay empty" do
    assert run_js(
             ~s|[D.toInstant(""), D.toLocalInput(""), D.toLocalInput("next tuesday"), D.toInstant("x")]|
           ) ==
             ["", "", "", ""]
  end

  test "the field posts only the hidden value; the picker is nameless and hooked" do
    html =
      render_component(&BarkparkWeb.Components.FieldInputs.input/1, %{
        field: %{"type" => "datetime", "name" => "publishedAt"},
        editor_form: %{"publishedAt" => "2026-10-03T08:30:00Z"}
      })

    assert html =~ ~s(phx-hook="BarkparkDatetimeField")

    assert html =~
             ~r/<input[^>]*type="hidden"[^>]*name="doc\[publishedAt\]"[^>]*value="2026-10-03T08:30:00Z"/

    [picker] = Regex.run(~r/<input[^>]*type="datetime-local"[^>]*>/, html)
    refute picker =~ "name="
  end
end
