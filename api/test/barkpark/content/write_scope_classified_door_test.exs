defmodule Barkpark.Content.WriteScopeClassifiedDoorTest do
  @moduledoc """
  THE SEEDED-DEFAULT RULING, at the funnel (task-e6523cc7154304f0).

  `Content.WriteScope.resolve_write_scope/1`'s last arm used to stamp the
  seeded Default Workspace on ANY write whose opts carried no `:workspace_id`.
  30 seats across 22 files reach that arm. The ruling classifies them, and the
  classification lives in ONE place — the door below — not in 30 patches:

    (a) an ATTRIBUTABLE caller (opts carry a `:caller_context` with a user or
        token id, or a bare `:user_id` — the shape Studio LiveView
        `Shared.hook_opts/1` produces) takes infer-or-refuse: exactly one
        candidate workspace is stamped, anything else is a typed refusal.
        NEVER the seeded Default — that is the fail-open-scoping class.
    (b) anonymous-BY-DESIGN seats derive scope from the ROUTE'S SITE CONTEXT
        and refuse when it is absent. Proved here on `Plugins.Tickets.Thread`,
        whose site context is the submitter key's workspace.
    (c) boot-time INSTANCE-WIDE seats keep the seeded Default but must DECLARE
        it with `instance_wide: true` — a DISTINCT opts key, not a second
        `:workspace_id` atom beside `:shared_only`, because `:shared_only` also
        carries READ meaning across `Content.Scope` / `Tasks.*` / `Media` and an
        instance-wide declaration has none.

  Every class carries a POSITIVE CONTROL — a write WITH scope still lands —
  so a refusal assertion cannot pass because the whole path is broken.

  MUTATION ARM: restoring the silent fallback (replacing the
  `resolve_key_absent_write_scope(opts)` arm with the old
  `Tenancy.get_default_workspace()` body) reds
  `class (a): a user principal in two workspaces is REFUSED, not Defaulted`
  and its `:user_id` sibling. Run pasted in the PR body.

  SCOPE NOTE (shared test database): every assertion is keyed on ids this test
  minted. `async: false` because the seeded Default Workspace is process-global
  state the class-(c) arm reads.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Auth.ApiToken
  alias Barkpark.Content
  alias Barkpark.Content.CallerContext
  alias Barkpark.Plugins.Tickets
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Barkpark.TenancyFixtures

  @dataset "test"

  defp attrs, do: %{"dataset" => @dataset}

  defp workspace_with_project! do
    ws = TenancyFixtures.create_workspace!()
    _ = TenancyFixtures.create_project!(ws, "default")
    ws
  end

  # A token with `workspace_id: nil` — minted through the changeset because
  # `Auth.create_token/5`'s workspace_id argument DEFAULTS to the seeded Default
  # id, so a token minted that way is never homeless and could not reach the
  # state under test.
  defp homeless_token!(member_of) do
    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token("door-#{System.unique_integer([:positive])}"),
        label: "seeded-default-ruling",
        dataset: @dataset,
        permissions: ["read", "write"],
        workspace_id: nil
      })
      |> Repo.insert()

    for ws <- member_of do
      {:ok, _} = Tenancy.Auth.create_membership(ws.id, token.id, "member", "api_token")
    end

    token
  end

  defp user_in!(workspaces) do
    user =
      Barkpark.AccountsFixtures.register_user(
        "door-#{System.unique_integer([:positive])}@example.com"
      )

    for ws <- workspaces do
      {:ok, _} = Tenancy.Auth.create_membership(ws.id, user.id, "member", "user")
    end

    user
  end

  describe "class (a) — an attributable caller never reaches the seeded Default" do
    test "a user principal in exactly ONE workspace is INFERRED into it" do
      ws = workspace_with_project!()
      user = user_in!([ws])

      ctx = %CallerContext{principal_type: :user, user_id: user.id}

      assert {:ok, stamped} = Content.put_scope_attrs(attrs(), caller_context: ctx)
      assert stamped["workspace_id"] == ws.id

      default = Tenancy.get_default_workspace()
      refute is_nil(default), "the seeded Default must exist or this test proves nothing"
      refute stamped["workspace_id"] == default.id
    end

    test "a user principal in two workspaces is REFUSED, not Defaulted" do
      ws_a = workspace_with_project!()
      ws_b = workspace_with_project!()
      user = user_in!([ws_a, ws_b])

      ctx = %CallerContext{principal_type: :user, user_id: user.id}

      assert {:error, :workspace_scope_required} =
               Content.put_scope_attrs(attrs(), caller_context: ctx)
    end

    test "POSITIVE CONTROL: the same two-workspace user WITH a workspace_id still lands" do
      ws_a = workspace_with_project!()
      ws_b = workspace_with_project!()
      user = user_in!([ws_a, ws_b])

      ctx = %CallerContext{principal_type: :user, user_id: user.id}

      assert {:ok, stamped} =
               Content.put_scope_attrs(attrs(), caller_context: ctx, workspace_id: ws_b.id)

      assert stamped["workspace_id"] == ws_b.id
    end

    test "a bare :user_id (the Studio hook_opts shape) is class (a) too" do
      ws = workspace_with_project!()
      one = user_in!([ws])

      assert {:ok, stamped} = Content.put_scope_attrs(attrs(), source: :studio, user_id: one.id)
      assert stamped["workspace_id"] == ws.id

      ws_a = workspace_with_project!()
      ws_b = workspace_with_project!()
      many = user_in!([ws_a, ws_b])

      assert {:error, :workspace_scope_required} =
               Content.put_scope_attrs(attrs(), source: :studio, user_id: many.id)
    end

    test "an api_token principal in two workspaces is REFUSED" do
      ws_a = workspace_with_project!()
      ws_b = workspace_with_project!()
      token = homeless_token!([ws_a, ws_b])

      ctx = %CallerContext{principal_type: :api_token, token_id: token.id}

      assert {:error, :workspace_scope_required} =
               Content.put_scope_attrs(attrs(), caller_context: ctx)
    end

    test "an ANONYMOUS caller_context is NOT class (a) — it carries no principal to infer from" do
      # The predicate is "does this opts list NAME a principal", not "is there a
      # :caller_context key". An anonymous context names nobody, so it falls to
      # the residual rather than producing a refusal nobody can act on.
      assert {:ok, stamped} =
               Content.put_scope_attrs(attrs(), caller_context: CallerContext.anonymous())

      default = Tenancy.get_default_workspace()
      assert stamped["workspace_id"] == default.id
    end
  end

  describe "class (c) — instance-wide writes DECLARE the seeded Default" do
    test "instance_wide: true resolves to the seeded Default Workspace/Project" do
      default_ws = Tenancy.get_default_workspace()
      default_proj = Tenancy.get_default_project()
      refute is_nil(default_ws)

      assert {:ok, stamped} = Content.put_scope_attrs(attrs(), instance_wide: true)
      assert stamped["workspace_id"] == default_ws.id
      assert stamped["project_id"] == default_proj.id
    end

    test "instance_wide OVERRIDES an attributable caller — a declaration beats an inference" do
      ws_a = workspace_with_project!()
      ws_b = workspace_with_project!()
      user = user_in!([ws_a, ws_b])
      ctx = %CallerContext{principal_type: :user, user_id: user.id}

      # Without the declaration this exact opts list is refused (test above).
      assert {:ok, stamped} =
               Content.put_scope_attrs(attrs(), caller_context: ctx, instance_wide: true)

      assert stamped["workspace_id"] == Tenancy.get_default_workspace().id
    end

    test "the class-(c) SEATS pass the declaration — in CODE, not in a comment" do
      # Every seat the ruling names as class (c) must carry the declaration in
      # its source. COMMENT LINES ARE STRIPPED FIRST: each of these seats also
      # NAMES `instance_wide: true` in the comment explaining why it is class
      # (c), so a whole-file match would pass on a seat whose call had lost the
      # option. (Caught by mutation 3 — dropping the option from bootstrap.ex
      # left the test green until this line stripped the comments.)
      root = Path.expand("../../..", __DIR__)

      for {file, symbol} <- [
            {"lib/barkpark/plugins/bootstrap.ex", "do_upsert"},
            {"lib/barkpark/content/tag_registry.ex", "do_register!"},
            {"lib/mix/tasks/onix.import.ex", "handle_upsert"}
          ] do
        code =
          root
          |> Path.join(file)
          |> File.read!()
          |> String.split("\n")
          |> Enum.reject(&(String.trim_leading(&1) |> String.starts_with?("#")))
          |> Enum.join("\n")

        assert code =~ "instance_wide: true",
               "#{file} (#{symbol}) is a class-(c) seat and must DECLARE the seeded Default"
      end
    end
  end

  describe "class (b) — anonymous-by-design seats derive scope from the route's site context" do
    setup do
      Content.upsert_schema(
        %{
          "name" => "ticket",
          "title" => "Ticket",
          "visibility" => "public",
          "fields" => []
        },
        @dataset,
        instance_wide: true
      )

      :ok
    end

    test "a submitter key bound to NO workspace is refused, not filed under Default" do
      {:ok, %{key: key}} = Tickets.Keys.mint(%{name: "homeless", dataset: @dataset})
      assert is_nil(key.workspace_id)

      assert {:error, :workspace_scope_required} =
               Tickets.Thread.create(key, %{"subject" => "hello", "body" => "anonymous"})
    end

    test "POSITIVE CONTROL: a workspace-bound key files the ticket under THAT workspace" do
      ws = workspace_with_project!()

      Content.upsert_schema(
        %{"name" => "ticket", "title" => "Ticket", "visibility" => "public", "fields" => []},
        @dataset,
        workspace_id: ws.id
      )

      {:ok, %{key: key}} =
        Tickets.Keys.mint(%{name: "bound", dataset: @dataset, workspace_id: ws.id})

      assert {:ok, ticket} =
               Tickets.Thread.create(key, %{"subject" => "hello", "body" => "anonymous"})

      assert ticket.workspace_id == ws.id
    end
  end

  describe "the residual — unchanged, and that is the point" do
    test "no scope key, no principal, no declaration still resolves to the seeded Default" do
      default = Tenancy.get_default_workspace()

      assert {:ok, stamped} = Content.put_scope_attrs(attrs(), source: :cli)
      assert stamped["workspace_id"] == default.id
    end

    test ":shared_only still takes the task-6fa023cdabdc5f6a path, untouched" do
      ws = workspace_with_project!()
      token = homeless_token!([ws])
      ctx = %CallerContext{principal_type: :api_token, token_id: token.id}

      assert {:ok, stamped} =
               Content.put_scope_attrs(attrs(), workspace_id: :shared_only, caller_context: ctx)

      assert stamped["workspace_id"] == ws.id
    end
  end
end
