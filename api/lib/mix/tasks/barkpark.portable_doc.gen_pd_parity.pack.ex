defmodule Mix.Tasks.Barkpark.PortableDoc.GenPdParity.Pack do
  @moduledoc """
  The PortableDoc **golden pack**: one directory holding everything a renderer or
  editor outside Barkpark proves itself against, written by
  `MIX_ENV=test mix barkpark.portable_doc.gen_pd_parity` into
  `api/priv/portable_doc/goldens/`:

      stamp.json                       render version, CSS, gettext and input hashes, file hashes
      blocks/<type>.golden.json        the 80 per-type goldens (GenPdParity.build/1)
      locales/<locale>.locale-golden.json   one per known locale (GenPdParity.build_locale/1)
      pages/<theme>-<locale>.html      a full /papers reader page holding every in-scope type
      fragments.json                   type → the reader HTML the canvas paints into its fleet hole
      email.html                       the :email golden (GenGoldenEmail.render/0)
      css/paper-surface.css            the served (comment-stripped) surface stylesheet
      css/code-tokens.css              the served code-token rules
      ops/<verb>.json                  before + op + after for each of the 9 edit verbs
      nested-list-carriers.json        the nested-list carrier fixture, verbatim
      canvas-forbidden-classes.json    reader literals the canvas JS must never write
      i18n/paper-canvas.<locale>.json  StudioLocale.component_strings(:paper_canvas)

  `build/0` is pure over the repo, so `golden_pack_test.exs` regenerates it in
  memory and compares bytes, `stamp.json` included. The stamp names only what
  decides the bytes, never a commit: Barkpark squash-merges, so a branch sha
  would dangle, and R1.5's sync records the merged sha in the public copy. The pack
  syncs to a public repo: every input is synthetic, and the freshness test refuses
  owner names and internal hostnames in any file.
  """

  alias Barkpark.Content.Papers.BlockOps
  alias Barkpark.PortableDoc.Patch
  alias Barkpark.PortableDoc.Render
  alias Barkpark.PortableDoc.Render.Stylesheet
  alias BarkparkWeb.StudioLocale
  alias Mix.Tasks.Barkpark.PortableDoc.GenGoldenEmail
  alias Mix.Tasks.Barkpark.PortableDoc.GenPdParity

  @api Path.expand("../../..", __DIR__)
  @dir Path.join(@api, "priv/portable_doc/goldens")
  @surface Path.join(@api, "assets/paper-surface")
  @carriers Path.join(@api, "test/support/fixtures/nested-list-carriers.json")

  @inputs Enum.sort([
            "lib/mix/tasks/barkpark.portable_doc.gen_golden_email.ex",
            "lib/mix/tasks/barkpark.portable_doc.gen_pd_parity.ex",
            "lib/mix/tasks/barkpark.portable_doc.gen_pd_parity.pack.ex",
            "test/support/fixtures/nested-list-carriers.json"
          ])

  @themes ~w(light dark)
  @nonce "parity-nonce"
  @csrf "pack-csrf-token"
  @origin "https://example.com"

  # Kept equal to canvas_reader_parity_gate_test.exs §3 (asserted there): the
  # painted-fleet and chip-carry signatures plus its explicit inner families.
  @canvas_forbidden ~w(bp-asciicast bp-bcard bp-board bp-board__ bp-card__ bp-cards bp-chart
                       bp-dataviz bp-diff bp-filetree bp-form bp-heat bp-legend bp-momentum
                       bp-note__ bp-notes bp-pipe bp-pnode bp-rm__ bp-roadmap bp-sheet__td
                       bp-stat bp-stats bp-tasks bp-tdetail paper-embed) ++ [~s(class="mermaid")]

  @doc "Every known locale, sorted: each gets a locale golden, two reader pages and an i18n map."
  def locales, do: Enum.sort(Barkpark.Tenancy.known_locales())

  @doc "The pack directory."
  def dir, do: @dir

  @doc "The 9 edit verbs: the six Patch ops and the three editor intents lowered to `patch-block`."
  def verbs, do: Enum.map(op_cases(), fn {verb, _before, _op} -> verb end)

  @doc "The reader literals the canvas JS must never write (canvas_reader_parity_gate_test.exs §3)."
  def canvas_forbidden, do: Enum.sort(@canvas_forbidden)

  @doc "Apply one op the way a block-op write does: lower it, then `Patch.apply_patch/2`."
  def apply_op(%{"blocks" => blocks} = before, op) do
    with {:ok, lowered} <- BlockOps.lower_editor_op(blocks, op),
         do: Patch.apply_patch(before, lowered)
  end

  @doc "Every pack file as `%{relative path => bytes}`, `stamp.json` included."
  def build do
    files = files()
    Map.put(files, "stamp.json", json(stamp(files)))
  end

  @doc "Replace the pack directory's contents with `build/0`."
  def write! do
    start_endpoint()
    files = build()
    File.rm_rf!(@dir)

    for {path, bytes} <- files do
      target = Path.join(@dir, path)
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, bytes)
    end

    Mix.shell().info("gen_pd_parity: golden pack — #{map_size(files)} file(s) in #{@dir}")
  end

  # The reader layout reads the endpoint's URL config; a test run has it started.
  defp start_endpoint do
    unless Process.whereis(BarkparkWeb.Endpoint) do
      Mix.Task.run("app.config")
      {:ok, _} = Application.ensure_all_started(:phoenix)
      {:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: Barkpark.PubSub)
      {:ok, _} = BarkparkWeb.Endpoint.start_link()
    end
  end

  @doc """
  The files whose bytes, beyond the render source, the Stylesheet and the gettext
  catalogues, decide the pack: the generators holding the corpus and the op
  fixtures, and the carrier fixture. Relative to `api/`, in hash order.
  """
  def inputs, do: @inputs

  @doc "The stamp for a set of pack files (stamp.json excluded)."
  def stamp(files) do
    %{
      "render_version" => Render.body_html_render_version(),
      "stylesheet_sha256" => sha256(Stylesheet.css()),
      "gettext_sha256" => gettext_sha256(),
      "inputs" => @inputs,
      "inputs_sha256" => inputs_sha256(),
      "files" => Map.new(files, fn {path, bytes} -> {path, sha256(bytes)} end)
    }
  end

  defp files do
    Map.new(
      Enum.concat([
        Enum.map(
          GenPdParity.types(),
          &{"blocks/#{GenPdParity.filename(&1)}", json(GenPdParity.build(&1))}
        ),
        Enum.map(
          locales(),
          &{"locales/#{GenPdParity.locale_filename(&1)}", json(GenPdParity.build_locale(&1))}
        ),
        for(
          locale <- locales(),
          theme <- @themes,
          do: {"pages/#{theme}-#{locale}.html", page(theme, locale)}
        ),
        Enum.map(locales(), &{"i18n/paper-canvas.#{&1}.json", canvas_strings(&1)}),
        Enum.map(op_cases(), fn {verb, before, op} ->
          {"ops/#{verb}.json", json(op_fixture(before, op))}
        end),
        [
          {"fragments.json", json(fragments())},
          {"email.html", GenGoldenEmail.render()},
          {"css/paper-surface.css", served_css("paper-surface.css")},
          {"css/code-tokens.css", served_css("code-tokens.css")},
          {"nested-list-carriers.json", File.read!(@carriers)},
          {"canvas-forbidden-classes.json", json(canvas_forbidden())}
        ]
      ])
    )
  end

  # The /papers reader page the view-edit parity matrix measures
  # (paper-editor/src/__view_edit_parity_matrix.mjs): the Bulldocs layout, every
  # in-scope type wrapped in its block id, a pinned nonce and CSRF token, the
  # theme on <html>, and <html lang> from the locale the page renders in. The
  # endpoint origin (PORT-dependent) is pinned to @origin.
  defp page(theme, locale) do
    Gettext.with_locale(BarkparkWeb.Gettext, StudioLocale.gettext_locale(locale), fn ->
      body =
        Enum.map_join(GenPdParity.types(), fn type ->
          html = Render.render_block(GenPdParity.input(type), %{style: :article, locale: locale})
          ~s(<div id="#{type}" data-block-id="#{type}">) <> html <> "</div>"
        end)

      inner =
        ~s(<main class="bp-paper-shell bp-paper-surface bp-paper-article"><article id="paper-body">) <>
          body <> "</article></main>"

      assigns = %{
        inner_content: Phoenix.HTML.raw(inner),
        page_title: "PortableDoc golden",
        preview: nil,
        csp_nonce: @nonce,
        bp_theme: "evergreen"
      }

      assigns
      |> with_csrf()
      |> String.replace(BarkparkWeb.Endpoint.url(), @origin)
      |> String.replace("<html", ~s(<html data-theme="#{theme}" data-bp-theme="evergreen"),
        global: false
      )
    end)
  end

  defp with_csrf(assigns) do
    previous = Process.put(:plug_masked_csrf_token, @csrf)

    try do
      assigns
      |> BarkparkWeb.Layouts.bulldocs()
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()
    after
      Process.put(:plug_masked_csrf_token, previous)
    end
  end

  # What the canvas paints into each fleet hole: the reader HTML, or for a
  # figure its child's (the matrix's `fragments`).
  defp fragments do
    Map.new(GenPdParity.types(), fn type ->
      block =
        case GenPdParity.input(type) do
          %{"type" => "figure", "child" => child} -> child
          input -> input
        end

      {type, Render.render_block(block, %{style: :article})}
    end)
  end

  defp canvas_strings(locale) do
    Gettext.with_locale(BarkparkWeb.Gettext, StudioLocale.gettext_locale(locale), fn ->
      :paper_canvas |> StudioLocale.component_strings() |> Jason.decode!() |> json()
    end)
  end

  defp served_css(name),
    do: @surface |> Path.join(name) |> File.read!() |> Stylesheet.Comments.strip()

  defp op_fixture(before, op) do
    {:ok, after_doc} = apply_op(before, op)
    fixture = %{"before" => before, "op" => op, "after" => after_doc}

    if op["op"] in ["patch-table-cells", "patch-table-structure"] do
      Map.put(fixture, "tableProjections", %{
        "before" => table_projection(before, op["id"]),
        "after" => table_projection(after_doc, op["id"])
      })
    else
      fixture
    end
  end

  defp table_projection(%{"blocks" => blocks}, id),
    do:
      blocks
      |> BlockOps.table_editor_projections()
      |> Map.fetch!(id)
      |> Jason.encode!()
      |> Jason.decode!()

  defp gettext_sha256 do
    root = Path.join(@api, "priv/gettext")

    root
    |> Path.join("**/*.po")
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.sort()
    |> Enum.reduce(:crypto.hash_init(:sha256), fn name, acc ->
      :crypto.hash_update(acc, name <> "\0" <> File.read!(Path.join(root, name)))
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp inputs_sha256 do
    @inputs
    |> Enum.reduce(:crypto.hash_init(:sha256), fn name, acc ->
      :crypto.hash_update(acc, name <> "\0" <> File.read!(Path.join(@api, name)))
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  # Erlang orders a map of more than 32 keys by hash, which can move between OTP
  # releases, so every map the pack encodes gets its keys sorted, nested maps
  # included. A map inside a list is left as it comes: the pack holds none large
  # enough to matter.
  defp json(term), do: Jason.encode!(ordered(term), pretty: true) <> "\n"

  defp ordered(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _} -> to_string(key) end)
    |> Enum.map(fn {key, value} -> {key, ordered(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp ordered(other), do: other

  defp text(value), do: [%{"type" => "text", "value" => value}]

  defp op_cases do
    [
      {"append-block",
       %{
         "version" => 1,
         "title" => "Release notes",
         "preview" => "What shipped this week.",
         "blocks" => [
           %{"id" => "rn-heading", "type" => "heading", "level" => 1, "text" => "Release notes"},
           %{
             "id" => "rn-body",
             "type" => "section",
             "title" => "Highlights",
             "blocks" => [
               %{
                 "id" => "rn-intro",
                 "type" => "paragraph",
                 "content" => text("Two changes landed.")
               },
               %{
                 "id" => "rn-cta",
                 "type" => "action",
                 "label" => "Read more",
                 "href" => "https://example.com/notes",
                 "priority" => "primary"
               }
             ]
           }
         ]
       }, %{"op" => "append-block", "block" => %{"id" => "rn-divider", "type" => "divider"}}},
      {"insert-after",
       %{
         "version" => 1,
         "title" => "Onboarding",
         "preview" => "Get set up in three steps.",
         "blocks" => [
           %{"id" => "ob-heading", "type" => "heading", "level" => 1, "text" => "Onboarding"},
           %{
             "id" => "ob-steps",
             "type" => "section",
             "title" => "Steps",
             "blocks" => [
               %{
                 "id" => "ob-intro",
                 "type" => "paragraph",
                 "content" => text("Follow these to begin.")
               },
               %{
                 "id" => "ob-list",
                 "type" => "list",
                 "ordered" => true,
                 "items" => [text("Create an account"), text("Invite your team")]
               }
             ]
           }
         ]
       },
       %{
         "op" => "insert-after",
         "afterId" => "ob-intro",
         "block" => %{
           "id" => "ob-note",
           "type" => "callout",
           "tone" => "info",
           "title" => "Heads up",
           "content" => text("This takes about five minutes.")
         }
       }},
      {"patch-block",
       %{
         "version" => 1,
         "title" => "Status",
         "preview" => "Current system status.",
         "blocks" => [
           %{"id" => "st-heading", "type" => "heading", "level" => 2, "text" => "Status"},
           %{
             "id" => "st-body",
             "type" => "section",
             "title" => "Services",
             "blocks" => [
               %{
                 "id" => "st-callout",
                 "type" => "callout",
                 "tone" => "warning",
                 "title" => "Degraded",
                 "content" => text("API latency is elevated.")
               },
               %{
                 "id" => "st-code",
                 "type" => "code",
                 "lang" => "sh",
                 "value" => "curl https://example.com/health"
               }
             ]
           }
         ]
       },
       %{
         "op" => "patch-block",
         "id" => "st-callout",
         "ifRev" => "7",
         "patch" => %{"tone" => "success", "content" => text("All systems operational.")}
       }},
      {"replace-block",
       %{
         "version" => 1,
         "title" => "Guide",
         "preview" => "How to deploy.",
         "blocks" => [
           %{"id" => "g-heading", "type" => "heading", "level" => 1, "text" => "Guide"},
           %{
             "id" => "g-old",
             "type" => "paragraph",
             "content" => text("Run the deploy steps below.")
           },
           %{
             "id" => "g-detail",
             "type" => "section",
             "title" => "Details",
             "blocks" => [
               %{
                 "id" => "g-detail-p",
                 "type" => "paragraph",
                 "content" => text("Each step is idempotent.")
               }
             ]
           }
         ]
       },
       %{
         "op" => "replace-block",
         "id" => "g-old",
         "block" => %{
           "id" => "g-steps",
           "type" => "list",
           "ordered" => true,
           "items" => [
             text("Build the artifact"),
             text("Push to staging"),
             text("Promote to production")
           ]
         }
       }},
      {"remove-block",
       %{
         "version" => 1,
         "title" => "Changelog",
         "preview" => "Recent changes.",
         "blocks" => [
           %{"id" => "cl-heading", "type" => "heading", "level" => 1, "text" => "Changelog"},
           %{
             "id" => "cl-section",
             "type" => "section",
             "title" => "v0.4",
             "blocks" => [
               %{
                 "id" => "cl-kept",
                 "type" => "paragraph",
                 "content" => text("Opened heading levels to h1–h6.")
               },
               %{
                 "id" => "cl-doomed",
                 "type" => "callout",
                 "tone" => "danger",
                 "title" => "Deprecated",
                 "content" => text("The legacy export path is gone.")
               }
             ]
           },
           %{"id" => "cl-divider", "type" => "divider"}
         ]
       }, %{"op" => "remove-block", "id" => "cl-doomed", "expectedVersion" => "12"}},
      {"move-block",
       %{
         "version" => 1,
         "title" => "Agenda",
         "blocks" => [
           %{"id" => "ag-heading", "type" => "heading", "level" => 1, "text" => "Agenda"},
           %{"id" => "ag-first", "type" => "paragraph", "content" => text("Welcome and intros.")},
           %{"id" => "ag-second", "type" => "paragraph", "content" => text("Roadmap review.")},
           %{"id" => "ag-last", "type" => "paragraph", "content" => text("Questions.")}
         ]
       }, %{"op" => "move-block", "id" => "ag-last", "after" => "ag-heading"}},
      {"patch-card-body",
       %{
         "version" => 1,
         "title" => "Plans",
         "blocks" => [
           %{
             "id" => "pl-card",
             "type" => "card",
             "tone" => "info",
             "slots" => %{
               "title" => [%{"type" => "heading", "text" => "Starter"}],
               "body" => [%{"type" => "paragraph", "content" => text("For small teams.")}]
             }
           }
         ]
       },
       %{
         "op" => "patch-card-body",
         "id" => "pl-card",
         "content" => [
           %{"type" => "text", "value" => "For teams of "},
           %{"type" => "strong", "children" => text("up to five")},
           %{"type" => "text", "value" => "."}
         ]
       }},
      {"patch-table-cells", pricing_table(),
       %{
         "op" => "patch-table-cells",
         "id" => "pr-table",
         "shape" => table_shape(),
         "cells" => [
           %{"area" => "body", "row" => 1, "column" => 1, "content" => text("Per seat")}
         ]
       }},
      {"patch-table-structure", pricing_table(),
       %{
         "op" => "patch-table-structure",
         "id" => "pr-table",
         "shape" => table_shape(),
         "action" => "add-row"
       }}
    ]
  end

  defp pricing_table do
    %{
      "version" => 1,
      "title" => "Pricing",
      "blocks" => [
        %{
          "id" => "pr-table",
          "type" => "table",
          "head" => [text("Plan"), text("Price")],
          "rows" => [[text("Basic"), text("Free")], [text("Team"), text("Paid")]]
        }
      ]
    }
  end

  defp table_shape do
    row = %{"kind" => "array", "cells" => ["inline-array", "inline-array"]}
    %{"v" => 1, "head" => %{"state" => "row", "row" => row}, "rows" => [row, row]}
  end
end
