defmodule Barkpark.Papers.PublicPaperScopeTest do
  @moduledoc """
  P0 cross-workspace read-leak guard for the PUBLIC `/papers/:slug` surface
  (barkpark-w9dg).

  Papers are stamped `workspace_id` on write and slugs are PER-WORKSPACE (the
  Wave-2 uniqueness flip lifted the old global `(doc_id, type, dataset)` index
  to a per-workspace `(doc_id, type, dataset_id)` one). Before this fix,
  `PaperLive.mount` called the bare `Content.get_paper(slug)` which runs
  UNSCOPED — `scope_to_workspace(query, nil, …)` returns the query untouched —
  so `Repo.one` resolved the slug across EVERY tenant. Any unauthenticated
  visitor could read any workspace's paper by slug, and on a same-slug
  collision the resolved row was non-deterministic.

  The fix routes the public surface through `Content.get_public_paper/2`, which
  resolves the slug ONLY within the seeded **Default** (public) workspace — the
  one deterministic public tenant (where the flat, unauthenticated paperflow
  ingest lands by Default fallback).

  These tests stand up the Default workspace plus a SEPARATE non-Default
  workspace, give each a paper under the SAME slug, and prove:

    1. `get_public_paper/2` resolves DETERMINISTICALLY to the Default-workspace
       (intentionally-public) paper, and
    2. it NEVER exposes the other workspace's paper for that slug, and
    3. a slug that exists ONLY in a non-Default workspace returns `nil` (not the
       private paper) from the public surface, and
    4. fail-closed: with no seeded Default workspace the public read is `nil`,
       never an unscoped all-tenant read.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  @slug "2026-05-25-leak-probe"

  describe "get_public_paper/2 cross-workspace isolation" do
    setup do
      # The seeded Default workspace/project IS the public tenant.
      {default_ws, default_proj} = ensure_default_scope!()

      # A second, NON-Default workspace — its papers must never surface on the
      # public /papers/:slug read.
      other_ws = create_workspace!()
      other_proj = create_project!(other_ws)

      # Two papers under the SAME slug — one public (Default), one private
      # (other workspace). The per-workspace uniqueness flip lets them coexist.
      {:ok, public_paper} =
        Content.upsert_paper(%{
          "slug" => @slug,
          "body_html" => "<article id=\"public\">PUBLIC default-workspace paper</article>",
          "workspace_id" => default_ws.id,
          "project_id" => default_proj.id
        })

      {:ok, private_paper} =
        Content.upsert_paper(%{
          "slug" => @slug,
          "body_html" => "<article id=\"private\">PRIVATE other-workspace paper</article>",
          "workspace_id" => other_ws.id,
          "project_id" => other_proj.id
        })

      %{
        default_ws: default_ws,
        default_proj: default_proj,
        other_ws: other_ws,
        other_proj: other_proj,
        public_paper: public_paper,
        private_paper: private_paper
      }
    end

    test "resolves DETERMINISTICALLY to the Default (public) paper", ctx do
      paper = Content.get_public_paper(@slug)

      refute is_nil(paper)
      assert paper.workspace_id == ctx.default_ws.id
      assert paper.id == ctx.public_paper.id
      assert get_in(paper.content, ["body_html"]) =~ "PUBLIC default-workspace paper"
    end

    test "NEVER exposes the non-Default workspace's paper for the same slug", ctx do
      paper = Content.get_public_paper(@slug)

      # The leak: before the fix this could resolve to the other workspace's row.
      refute paper.workspace_id == ctx.other_ws.id
      refute paper.id == ctx.private_paper.id
      refute get_in(paper.content, ["body_html"]) =~ "PRIVATE other-workspace paper"
    end

    test "a slug that exists ONLY in a non-Default workspace returns nil publicly",
         ctx do
      private_only_slug = "2026-05-25-private-only"

      {:ok, _private_only} =
        Content.upsert_paper(%{
          "slug" => private_only_slug,
          "body_html" => "<article>private only</article>",
          "workspace_id" => ctx.other_ws.id,
          "project_id" => ctx.other_proj.id
        })

      # The private paper IS stored (proves the slug exists) — read it with its
      # OWN workspace+project scope (dataset resolution is project-scoped)...
      assert %{} =
               Content.get_paper(private_only_slug, Content.paper_default_dataset(),
                 workspace_id: ctx.other_ws.id,
                 project_id: ctx.other_proj.id
               )

      # ...but the PUBLIC surface must not see it.
      assert Content.get_public_paper(private_only_slug) == nil
    end

    test "fail-closed: no seeded Default workspace → public read is nil, not unscoped",
         ctx do
      fail_slug = "2026-05-25-failclosed"

      lone_ws = create_workspace!()
      lone_proj = create_project!(lone_ws)

      {:ok, _paper} =
        Content.upsert_paper(%{
          "slug" => fail_slug,
          "body_html" => "<article>lone</article>",
          "workspace_id" => lone_ws.id,
          "project_id" => lone_proj.id
        })

      # Simulate "no seeded Default tenant" without an FK-entangled teardown:
      # rename the Default workspace's slug so the slug-keyed
      # `Tenancy.get_default_workspace/0` (looks up slug == "default") returns
      # nil — the exact precondition the fail-closed branch guards.
      Tenancy.get_default_workspace()
      |> Ecto.Changeset.change(slug: "not-default-#{System.unique_integer([:positive])}")
      |> Repo.update!()

      assert Tenancy.get_default_workspace() == nil

      # Even though a paper with this slug exists in lone_ws, the public read
      # must NOT fall back to an unscoped all-tenant resolve — fail closed.
      assert Content.get_public_paper(fail_slug) == nil
      # ...and the public lookup of the EARLIER public-tenant slug now also
      # returns nil (its workspace is no longer the resolvable Default).
      assert Content.get_public_paper(@slug) == nil

      _ = ctx
    end
  end
end
