defmodule Barkpark.Content.SchemaVisibilityClampTest do
  @moduledoc """
  The corpus schema-visibility clamp (`Content.Schema.visible_schemas/2`) —
  the ONE owner shared by `TasksController.derive_graph_corpus/2` and
  `FinderLive.graph_payload/2` (task-336d22b7722ea71e).

  The defect this key-shape prevents: the predecessor asked "is this the one
  restricted tier?" (`PublicRead.public_read_token?/1`) and showed EVERYTHING
  in the else-arm, so a principal with no token at all — not a public-read
  token — fell through to the full corpus. These tests pin the inverted key:
  default-narrow, widen ONLY for a principal that has earned it.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.CallerContext
  alias Barkpark.Content.Schema

  @schemas [
    %{name: "open", visibility: "public"},
    %{name: "vault", visibility: "private"},
    %{name: "unset", visibility: nil}
  ]

  defp names(schemas), do: Enum.map(schemas, & &1.name)

  test "NO-TOKEN IS THE NARROWEST TIER: the anonymous baseline sees public-visibility schemas only" do
    # The current defect was precisely that "unrecognised" fell through to
    # "show everything" — a visitor with no credential is not a public-read
    # token, and the old key's else-arm handed them the unclamped corpus.
    assert names(Schema.visible_schemas(@schemas, CallerContext.anonymous())) == ["open"]
  end

  test "DEFAULT-NARROW: nil, bare maps, and unknown principal shapes are all clamped, never fail open" do
    for principal <- [
          nil,
          %{},
          %{principal_type: :user},
          :who_knows,
          %CallerContext{principal_type: :service_account}
        ] do
      assert names(Schema.visible_schemas(@schemas, principal)) == ["open"],
             "principal #{inspect(principal)} was handed the wide view — the clamp fell open"
    end
  end

  test "the public-read tier is clamped by MEMBERSHIP, not list equality" do
    # TokenController mints `["public-read", "read"]` as a real shape; an
    # equality pin on `["public-read"]` would be escapable by construction.
    ctx = CallerContext.from_token(%{id: "t1", permissions: ["public-read", "read"]})
    assert names(Schema.visible_schemas(@schemas, ctx)) == ["open"]
  end

  test "EARNED WIDENING: read/write/admin tokens and user sessions keep the full view" do
    # Both directions: a fix that narrows everything is indistinguishable from
    # one that narrows correctly unless the permit arm is proven too.
    for ctx <- [
          CallerContext.from_token(%{id: "t2", permissions: ["read"]}),
          CallerContext.from_token(%{id: "t3", permissions: ["read", "write", "admin"]}),
          CallerContext.from_user("user-1", roles: ["member"], load_grants: false)
        ] do
      assert names(Schema.visible_schemas(@schemas, ctx)) == ["open", "vault", "unset"],
             "earned principal #{inspect(ctx.principal_type)}/#{inspect(ctx.roles)} lost the wide view"
    end
  end

  test "the narrow arm fails CLOSED on an all-private corpus: empty, not everything" do
    schemas = [%{name: "vault", visibility: "private"}]
    assert Schema.visible_schemas(schemas, CallerContext.anonymous()) == []
    assert Schema.visible_schemas(schemas, nil) == []
  end
end
