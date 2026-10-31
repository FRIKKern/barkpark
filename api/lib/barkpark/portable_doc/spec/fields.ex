defmodule Barkpark.PortableDoc.Spec.Fields do
  @moduledoc """
  The fields the reader reads on each block type, for the published JSON Schema
  (`Barkpark.PortableDoc.Spec`). One entry per type `render/compose.ex` renders;
  `spec_test.exs` fails when this map and the reader disagree on the type set or
  on a type's fields (`ComposeCensus.Reads` reads them off the reader's source).

  A field's shape is a shorthand `Spec` expands: `:string`, `:integer`,
  `:number`, `:boolean`, `:object`, `:array`, `:any`, `:scalar` (string or
  number), `:inline` (inline nodes), `:block`, `:blocks`, `{:array, shape}`,
  `{:object, %{field => shape}}`, `{:any_of, [shape]}`, `{:integer, min, max}`,
  `{:enum, [value]}`, and `{:typeless, type}` (that type's fields on a map with
  no `"type"`, which the reader fills in).

  Keys the server injects before rendering (`_render_opts`, `_paper_links`,
  `_code_label`, `_ref_title`) and the read-time `unavailable` marker are not
  authored, so they are not listed.

  `id`, `role` and `locked` ride every block and are added by `Spec`.

  `aliases/0` maps each spelling the reader rewrites to `{type, set}`: the
  canonical type and the fields the rewrite forces, overriding what is stored.
  """

  @fields %{
    "action" => %{"href" => :string, "label" => :string, "priority" => :string},
    "api-endpoint" => %{"method" => :string, "params" => {:array, :object}, "path" => :string},
    "arrayOf" => %{"label" => :string, "value" => :array},
    "asciicast" => %{
      "caption" => :string,
      "poster" => :string,
      "rows" => :integer,
      "src" => :string
    },
    "bar-chart" => %{"bars" => {:array, :object}, "max" => :number, "values" => :boolean},
    "blockquote" => %{
      "attribution" => :string,
      "cite" => :string,
      "content" => :inline,
      "text" => :string
    },
    "byline" => %{"items" => :array, "text" => :string},
    "callout" => %{
      "collapsed" => :boolean,
      "collapsible" => :boolean,
      "content" => :inline,
      "slots" => {:object, %{"body" => :blocks}},
      "text" => :string,
      "title" => :string,
      "tone" => :string
    },
    "card" => %{
      "slots" =>
        {:object,
         %{
           "action" => :blocks,
           "body" => :blocks,
           "media" => {:array, {:any_of, [:block, {:typeless, "image"}]}},
           "title" => :blocks
         }},
      "span" => :integer,
      "tone" => :string
    },
    "cards" => %{"items" => {:array, :object}},
    "chart" => %{
      "annotations" => :object,
      "axes" => :object,
      "caption" => :string,
      "kind" => :string,
      "query" => :object,
      "series" => {:array, :object}
    },
    "chat-approval" => %{
      "approval_status" => :string,
      "summary" => :string,
      "tool_name" => :string
    },
    "chat-plan" => %{"approval_status" => :string, "preview" => :string, "title" => :string},
    "chat-question" => %{"approval_status" => :string, "questions" => {:array, :object}},
    "chat-thinking" => %{"tokens" => :integer},
    "chat-todo" => %{"todos" => {:array, :object}},
    "chat-tool-diff" => %{"input" => :object},
    "code" => %{
      "code" => {:any_of, [:string, :inline]},
      "content" => {:any_of, [:string, :inline]},
      "emphasis" => {:array, :object},
      "lang" => :string,
      "text" => {:any_of, [:string, :inline]},
      "value" => {:any_of, [:string, :inline]}
    },
    "code-tabs" => %{"syncKey" => :string, "tabs" => {:array, :object}},
    "codelist" => %{
      "codelistId" => :string,
      "label" => :string,
      "plugin" => :string,
      "value" => :scalar
    },
    "columns" => %{"columns" => {:array, :blocks}},
    "composite" => %{"fields" => {:array, :object}, "label" => :string, "value" => :object},
    "criteria-progress" => %{"detail" => :string, "rows" => {:array, :object}},
    "diagram" => %{"caption" => :string, "source" => :string},
    "diff" => %{"diff" => :string, "file" => :string, "lang" => :string},
    "divider" => %{},
    "duel" => %{
      "legendA" => :string,
      "legendB" => :string,
      "rows" => {:array, :object},
      "sourceDefault" => :string
    },
    "embed" => %{"target" => :string},
    "equation" => %{"display" => :boolean, "tex" => :string},
    "expandable" => %{
      "blocks" => :blocks,
      "children" => :blocks,
      "open" => :boolean,
      "summary" => :string
    },
    "eyebrow" => %{"content" => :inline, "text" => :string},
    "field-boolean" => %{"label" => :string, "value" => :boolean},
    "field-color" => %{"label" => :string, "value" => :string},
    "field-datetime" => %{"label" => :string, "value" => :string},
    "field-image" => %{"label" => :string, "value" => {:any_of, [:string, :object]}},
    "field-number" => %{"label" => :string, "unit" => :string, "value" => :scalar},
    "field-reference" => %{
      "label" => :string,
      "refType" => :string,
      "value" => {:any_of, [:string, :object]}
    },
    "field-select" => %{"label" => :string, "options" => :array, "value" => :scalar},
    "field-slug" => %{"label" => :string, "value" => :string},
    "field-string" => %{"label" => :string, "value" => :string},
    "field-text" => %{"label" => :string, "value" => :string},
    "figure" => %{"caption" => :string, "child" => :block},
    "filetree" => %{"legend" => :string, "text" => :string},
    "footnote" => %{"notes" => {:array, :object}},
    "form" => %{"kind" => :string, "questions" => {:array, :object}},
    "gauge-list" => %{
      "groupBy" => :string,
      "max" => :number,
      "mode" => :string,
      "rows" => {:array, :object},
      "snapshot" => :array,
      "title" => :string
    },
    "heading" => %{
      "align" => :string,
      "content" => :inline,
      "level" => {:any_of, [{:integer, 1, 6}, {:enum, ~w(1 2 3 4 5 6)}]},
      "text" => :string
    },
    "heatmap" => %{
      "cells" => {:array, :array},
      "colLabels" => {:array, :string},
      "marginals" => :boolean,
      "max" => :number,
      "mode" => :string,
      "query" => :object,
      "rowLabels" => {:array, :string},
      "values" => :boolean
    },
    "image" => %{"alt" => :string, "height" => :scalar, "src" => :string, "width" => :scalar},
    "ingress" => %{"content" => :inline, "text" => :string},
    "lineage" => %{"nodes" => {:array, :object}, "sourceDefault" => :string},
    "list" => %{
      "items" =>
        {:array,
         {:any_of,
          [
            :inline,
            :scalar,
            {:object,
             %{
               "checked" => :boolean,
               "children" => :blocks,
               "content" => :inline,
               "text" => :string
             }}
          ]}},
      "ordered" => :boolean,
      "start" => :integer,
      "task" => :boolean
    },
    "localizedText" => %{"label" => :string, "languages" => {:array, :string}, "value" => :object},
    "master-ref" => %{"master" => :string, "version" => :string},
    "note" => %{
      "content" => :inline,
      "label" => :string,
      "lead" => :string,
      "slots" => {:object, %{"body" => :blocks, "label" => :blocks, "lead" => :blocks}},
      "text" => :string
    },
    "notes" => %{"items" => {:array, :object}},
    "paper-links" => %{
      "description" => :string,
      "layout" => :string,
      "reasons" => :object,
      "refs" => :array,
      "title" => :string
    },
    "paragraph" => %{"align" => :string, "content" => :inline, "text" => :string},
    "pipeline" => %{"nodes" => {:array, :object}},
    "pre-gate-badge" => %{
      "anchor" => :string,
      "label" => :string,
      "title" => :string,
      "tone" => :string
    },
    "pullquote" => %{"content" => :inline, "text" => :string},
    "questionnaire" => %{"kind" => :string, "questions" => {:array, :object}},
    "roadmap" => %{
      "end" => :string,
      "query" => :object,
      "scale" => {:array, :string},
      "snapshot" => {:array, :object},
      "start" => :string,
      "today" => :string
    },
    "route" => %{
      "caption" => :string,
      "distance" => :string,
      "duration" => :string,
      "elevation" => :string,
      "polyline" => :string,
      "sport" => :string
    },
    "section" => %{
      "blocks" => :blocks,
      "layout" => :object,
      "title" => :string,
      "variant" => :string
    },
    "sheet" => %{"ref" => :string, "snapshot" => :object},
    "stage" => %{
      "detail" => :string,
      "files" => :array,
      "kind" => :string,
      "slots" => {:object, %{"detail" => :blocks, "kind" => :blocks, "title" => :blocks}},
      "source" => {:any_of, [:boolean, :string]},
      "title" => :string
    },
    "stat" => %{
      "body" => :string,
      "denom" => :scalar,
      "dots" => :object,
      "label" => :string,
      "max" => :number,
      "query" => :object,
      "source" => :string,
      "spark" => {:array, :number},
      "unit" => :string,
      "value" => :scalar,
      "verdict" => :string
    },
    "stat-grid" => %{"items" => {:array, :object}, "sourceDefault" => :string},
    "stats" => %{"items" => {:array, :object}, "sourceDefault" => :string},
    "status-legend" => %{},
    "steps" => %{
      "steps" =>
        {:array, {:object, %{"blocks" => :blocks, "children" => :blocks, "title" => :string}}}
    },
    "table" => %{
      "cols" => {:array, :object},
      "columns" => :array,
      "head" => :array,
      "headCol" => :boolean,
      "header" => {:any_of, [:boolean, :array]},
      "rows" => :array,
      "spans" => {:array, :object}
    },
    "tabs" => %{"tabs" => {:array, {:object, %{"blocks" => :blocks, "label" => :string}}}},
    "task-board" => %{"query" => :object, "snapshot" => {:array, :object}},
    "task-detail" => %{"query" => :object, "task" => :object},
    "task-list" => %{
      "config" => :object,
      "query" => :object,
      "snapshot" => {:array, :object},
      "title" => :string
    },
    "tasks" => %{
      "config" => :object,
      "query" => :object,
      "snapshot" => {:array, :object},
      "title" => :string
    },
    "terminal" => %{
      "blocks" => :blocks,
      "children" => :blocks,
      "footer" => :string,
      "live" => :boolean,
      "title" => :string
    },
    "toc" => %{
      "depth" => :integer,
      "items" => {:array, :object},
      "numbered" => :boolean,
      "sticky" => :boolean
    },
    "video" => %{
      "captions" => {:array, :object},
      "loop" => :boolean,
      "poster" => :string,
      "src" => :string
    }
  }

  @aliases %{
    "bulletList" => {"list", %{}},
    "bullet_list" => {"list", %{}},
    "bulleted-list" => {"list", %{}},
    "bulleted_list" => {"list", %{}},
    "h1" => {"heading", %{"level" => 1}},
    "h2" => {"heading", %{"level" => 2}},
    "h3" => {"heading", %{"level" => 3}},
    "numbered_list" => {"list", %{"ordered" => true}},
    "ordered-list" => {"list", %{"ordered" => true}},
    "quote" => {"blockquote", %{}}
  }

  def all, do: @fields

  def aliases, do: @aliases
end
