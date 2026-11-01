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

  @pinned_misses %{
    {"canvas/index.js:1083", "an expression it cannot follow"} =>
      "PLACEHOLDER.heading is a function; a heading returns at line 1081, before this line",
    {"canvas/paste-vocabulary.js:182", "a list built at run time"} =>
      "the names a paste left out: DROP_NAMES values and block:<type>, collected while pasting",
    {"slash-menu.js:125", "a parameter of an anonymous function"} =>
      "a chord part PC_WORD has no word for is shown as written",
    {"slash-menu.js:332", "property name: no entry or assignment in this file"} =>
      "an expected field's own label or name from data-expected-fields: schema data",
    {"slash-menu.js:495", "property name: no entry or assignment in this file"} =>
      "an expected field's own label or name from data-expected-fields: schema data"
  }

  @pinned_patterns %{
    {"slash-menu.js:332", "^.+\\ \\(linked\\)$"} =>
      "a master's title (user data) + \" (linked)\", English untranslated: task-0e2edc6dc4f3089f",
    {"slash-menu.js:332", "^linked\\ master.+$"} =>
      "\"linked master\" + a master's tier (user data), English untranslated: task-0e2edc6dc4f3089f",
    {"slash-menu.js:332", "^master.+$"} =>
      "\"master\" + a master's tier (user data), English untranslated: task-0e2edc6dc4f3089f",
    {"slash-menu.js:495", "^.+\\ \\(linked\\)$"} =>
      "a master's title (user data) + \" (linked)\", English untranslated: task-0e2edc6dc4f3089f",
    {"slash-menu.js:500", "^linked\\ master.+$"} =>
      "\"linked master\" + a master's tier (user data), English untranslated: task-0e2edc6dc4f3089f",
    {"slash-menu.js:500", "^master.+$"} =>
      "\"master\" + a master's tier (user data), English untranslated: task-0e2edc6dc4f3089f"
  }

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

  test "every branch a t() call cannot follow is pinned here with its reason", %{scan: scan} do
    misses =
      for site <- scan.sites,
          {_file, _line, why} <- site.misses,
          uniq: true,
          do: {"#{site.file}:#{site.line}", why}

    assert misses -- Map.keys(@pinned_misses) == []
    assert Map.keys(@pinned_misses) -- misses == []
  end

  test "every template key fits a word in component_strings(:paper_canvas), unless pinned as user data",
       %{scan: scan} do
    words = :paper_canvas |> StudioLocale.component_strings() |> Jason.decode!() |> Map.keys()

    unmatched =
      for site <- scan.sites,
          {:pattern, pattern} <- site.keys,
          regex = Regex.compile!(pattern),
          not Enum.any?(words, &Regex.match?(regex, &1)),
          uniq: true,
          do: {"#{site.file}:#{site.line}", pattern}

    assert unmatched -- Map.keys(@pinned_patterns) == []
    assert Map.keys(@pinned_patterns) -- unmatched == []
  end

  test "t is read only where it is called", %{scan: scan} do
    assert scan.escapes == []
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
      import { PLACEHOLDER, PLACEHOLDER as PH } from "../words.js";
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
      export class Menu {
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
          t(PH.body);
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
      import { caption, caption as cap } from "./menu.js";
      import { Menu } from "./menu.js";
      import { t } from "../i18n.js";
      caption("Imported wrapper");
      cap("Renamed wrapper");
      new Menu({ eyebrow: "Constructed eyebrow" });
      class Sub extends Menu {
        constructor() { super({ eyebrow: "Super eyebrow" }); }
      }
      const OTHER = { eyebrow: "Not passed to Menu" };
      new Widget({ eyebrow: "Not a Menu" });
      t(t("Nested call"));
      t(null);
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
                 "Imported body",
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
                 "Listed word",
                 "Renamed wrapper",
                 "Constructed eyebrow",
                 "Super eyebrow",
                 "Nested call"
               ])

      assert scan.patterns == ["^Hello\\ .+$"]
    end

    test "t passed, stored, called through .call or imported whole is an escape", %{dir: dir} do
      File.write!(Path.join(dir, "a.js"), ~S"""
      import { t } from "./i18n.js";
      const tx = t;
      ["Mapped"].map(t);
      t.call(null, "Called");
      settings.t;
      function local() { let t = 1; return t + 1; }
      const pick = (t) => t.name;
      t("Fine");
      """)

      File.write!(Path.join(dir, "b.js"), ~S"""
      import * as i18n from "./i18n.js";
      i18n.t("Whole");
      """)

      assert Enum.map(PaperCanvasTKeys.scan(dir).escapes, &{&1.file, &1.line}) |> Enum.sort() ==
               [{"a.js", 2}, {"a.js", 3}, {"a.js", 4}, {"b.js", 0}]
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
