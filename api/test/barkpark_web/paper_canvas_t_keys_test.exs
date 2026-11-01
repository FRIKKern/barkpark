defmodule BarkparkWeb.PaperCanvasTKeysTest do
  @moduledoc """
  task-bd639a133641c5c3 (R2.2): a key the paper editor hands `t()` that the
  server's map leaves out reads English in every other language, and nothing
  else shows it. The keys are read from the editor's source on every run
  (`BarkparkWeb.PaperCanvasTKeys`), never from a kept list.
  """
  use ExUnit.Case, async: true

  alias BarkparkWeb.PaperCanvasTKeys
  alias BarkparkWeb.StudioLocale

  setup_all do
    %{scan: PaperCanvasTKeys.scan()}
  end

  test "every key the editor hands t() is in component_strings(:paper_canvas)", %{scan: scan} do
    assert length(scan.sites) > 150,
           "the scan found #{length(scan.sites)} t() calls: it is broken"

    sent = :paper_canvas |> StudioLocale.component_strings() |> Jason.decode!()

    missing =
      for site <- scan.sites,
          key <- site.keys,
          is_binary(key),
          not Map.has_key?(sent, key),
          do: "#{inspect(key)} (src/#{site.file}:#{site.line})"

    assert Enum.uniq(missing) == []
  end

  test "every t() call reaches a key, unless its words come from a list built at run time", %{
    scan: scan
  } do
    blind =
      for %{keys: [], misses: misses} = site <- scan.sites,
          not Enum.all?(misses, fn {_f, _l, why} ->
            why in ["a list built at run time", "a parameter of an anonymous function"]
          end),
          do: "src/#{site.file}:#{site.line} #{inspect(misses)}"

    assert blind == []
  end

  describe "the reading" do
    setup do
      dir = Path.join(System.tmp_dir!(), "t-keys-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "canvas"))
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "follows every way a key reaches t", %{dir: dir} do
      File.write!(Path.join(dir, "words.js"), ~S"""
      export const PLACEHOLDER = { title: "Imported title", body: "Imported body" };
      """)

      File.write!(Path.join(dir, "canvas/menu.js"), ~S"""
      import { t, te, t as tr } from "../i18n.js";
      import { PLACEHOLDER } from "../words.js";
      // t("In a comment") and /t("in a regex")/ are not calls.
      const re = /"t('x')"/g;
      const LABEL = "A const";
      const TONES = { info: "Info tone", warn: "Warn tone" };
      const ITEMS = [{ label: "Item label", desc: "Item desc" }];
      const PAIRS = [["a", "Pair word"]];
      const WORDS = ["Listed word"];
      const NAMES = [{ key: "k", name: "Named row" }];
      function toneLabel(tone) {
        switch (tone) {
          case "x": return "Returned word";
          default: return "Default word";
        }
      }
      export function caption(word) { return te(word); }
      class Menu {
        constructor({ eyebrow } = {}) { this._eyebrow = eyebrow || "Eyebrow fallback"; }
        _mk(name, title) { return t(title); }
        paint(item, kind) {
          const mk = (label) => tr(label);
          t("Double");
          t('Single');
          t(`Template`);
          t(`Hello ${kind}`);
          t("Esc\u2026aped \x41\u{1F600}");
          t(kind ? "Then" : "Else");
          t(kind || "Or fallback");
          t(kind && "And value");
          t(LABEL);
          t(TONES.info);
          t(TONES[kind]);
          t(PLACEHOLDER.title);
          t(toneLabel(kind));
          t(item.label);
          t(this._eyebrow);
          mk("Arrow wrapper");
          this._mk("bold", "Method wrapper");
          for (const [, word] of PAIRS) t(word);
          for (const { name } of NAMES) t(name);
          for (const row of ITEMS) t(row.desc);
          for (const word of WORDS) t(word);
          ITEMS.map(({ label }) => t(label));
        }
      }
      new Menu({ eyebrow: "Passed eyebrow" });
      """)

      File.write!(Path.join(dir, "canvas/user.js"), ~S"""
      import { caption } from "./menu.js";
      caption("Imported wrapper");
      """)

      scan = PaperCanvasTKeys.scan(dir)

      assert scan.keys ==
               MapSet.new([
                 "Double",
                 "Single",
                 "Template",
                 "Esc…aped A😀",
                 "Then",
                 "Else",
                 "Or fallback",
                 "And value",
                 "A const",
                 "Info tone",
                 "Warn tone",
                 "Imported title",
                 "Returned word",
                 "Default word",
                 "Item label",
                 "Eyebrow fallback",
                 "Passed eyebrow",
                 "Arrow wrapper",
                 "Method wrapper",
                 "Imported wrapper",
                 "Pair word",
                 "Named row",
                 "Item desc",
                 "Listed word"
               ])

      assert scan.patterns == ["^Hello\\ .+$"]
    end

    test "a key it cannot follow is a miss, never a guess", %{dir: dir} do
      File.write!(Path.join(dir, "a.js"), ~S"""
      import { t } from "./i18n.js";
      export function paint(dropped, x) {
        t("Left " + x);
        for (const d of dropped) t(d);
        dropped.forEach((w) => t(w));
      }
      """)

      %{keys: keys, sites: sites} = PaperCanvasTKeys.scan(dir)
      assert keys == MapSet.new()
      assert Enum.map(sites, &{&1.line, &1.keys}) == [{3, []}, {4, []}, {5, []}]

      assert Enum.map(sites, fn %{misses: [{_, _, why} | _]} -> why end) == [
               "an expression it cannot follow",
               "a list built at run time",
               "a parameter of an anonymous function"
             ]
    end
  end
end
