defmodule Barkpark.Seeds.Demo do
  @moduledoc """
  The demo seed profile — verbatim extraction of the 8 core schemas, 27
  sample documents, `barkpark-dev-token`, and the EDItEUR/Thema codelist
  blocks that lived in `priv/repo/seeds.exs`. Dispatched by
  `Barkpark.Seeds.run/1` (the default profile).
  """

  alias Barkpark.Repo
  alias Barkpark.Content.{Document, SchemaDefinition}
  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Seeds.Shared
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @doc "Seed the demo schemas, documents, and dev token under `scope`."
  def seed(scope) do
    seed_schemas(scope)
    seed_documents(scope)
    seed_dev_token(scope)
  end

  # ── Schema Definitions ──────────────────────────────────────────────────────

  defp seed_schemas(scope) do
    dataset = scope.dataset

    schemas = [
      %{
        name: "post",
        title: "Post",
        icon: "📄",
        visibility: "public",
        dataset: dataset,
        # surface (pd-doctrine t7, rule 4): title / excerpt / body / featured image
        # read as the article → "body"; slug / status / dates / byline relation /
        # trade flags live in the WP-style right rail → "sidebar".
        fields: [
          %{name: "title", title: "Title", type: "string", surface: "body"},
          %{name: "slug", title: "Slug", type: "slug", surface: "sidebar"},
          %{
            name: "status",
            title: "Status",
            type: "select",
            options: ["draft", "published", "archived"],
            surface: "sidebar"
          },
          %{name: "publishedAt", title: "Published At", type: "datetime", surface: "sidebar"},
          %{name: "excerpt", title: "Excerpt", type: "text", rows: 3, surface: "body"},
          %{name: "body", title: "Body", type: "richText", surface: "body"},
          %{name: "featuredImage", title: "Featured Image", type: "image", surface: "body"},
          %{
            name: "featuredAsset",
            title: "Featured Asset",
            type: "reference",
            refType: "mediaAsset",
            surface: "body"
          },
          %{
            name: "author",
            title: "Author",
            type: "reference",
            refType: "author",
            surface: "sidebar"
          },
          %{name: "featured", title: "Featured Post", type: "boolean", surface: "sidebar"}
        ],
        # Explicit Expectation (Exp-P1, barkpark-u7q5). SOFT layout: title → slug →
        # hero → body free-content region. `featuredImage` is the post's hero field
        # (post has no field literally named "hero"). `prefill` is the create-time
        # scaffold; `status` defaults to "draft", `featured` to false.
        #
        # CARDINALITY (EX1, barkpark-q39y): title / slug / featuredImage are expected
        # exactly ONCE and HARD-enforced (`max: 1, enforce: true`) — the slash menu
        # hides them at the cap and a 2nd insert is rejected. The body region is
        # free-content and carries no cardinality.
        layout: [
          %{kind: "field", name: "title", max: 1, enforce: true},
          %{kind: "field", name: "slug", max: 1, enforce: true},
          %{kind: "field", name: "featuredImage", max: 1, enforce: true},
          %{kind: "region", name: "body"}
        ],
        prefill: %{
          "status" => "draft",
          "featured" => false
        }
      },
      %{
        name: "page",
        title: "Page",
        icon: "📑",
        visibility: "public",
        dataset: dataset,
        # surface (t7): title / page content / hero read as the article; slug and
        # SEO metadata live in the sidebar.
        fields: [
          %{name: "title", title: "Title", type: "string", surface: "body"},
          %{name: "slug", title: "Slug", type: "slug", surface: "sidebar"},
          %{name: "body", title: "Page Content", type: "richText", surface: "body"},
          %{name: "seoTitle", title: "SEO Title", type: "string", surface: "sidebar"},
          %{
            name: "seoDescription",
            title: "SEO Description",
            type: "text",
            rows: 2,
            surface: "sidebar"
          },
          %{name: "heroImage", title: "Hero Image", type: "image", surface: "body"},
          %{
            name: "heroAsset",
            title: "Hero Asset",
            type: "reference",
            refType: "mediaAsset",
            surface: "body"
          }
        ]
      },
      %{
        name: "author",
        title: "Author",
        icon: "👤",
        visibility: "public",
        dataset: dataset,
        # surface (t7): name / bio / avatar are the author's article content; slug,
        # contact email, and role classification live in the sidebar.
        fields: [
          %{name: "name", title: "Name", type: "string", surface: "body"},
          %{name: "slug", title: "Slug", type: "slug", surface: "sidebar"},
          %{name: "bio", title: "Bio", type: "text", rows: 4, surface: "body"},
          %{name: "avatar", title: "Avatar", type: "image", surface: "body"},
          # Contact email is PII — `private: true` is the field-visibility
          # declaration the Envelope chokepoint redacts on (render/3 drops it
          # for anonymous and non-admin callers; field_readable?/3 refuses it
          # in filter/order clauses). Sealed by
          # test/barkpark/content/envelope_author_email_seal_test.exs.
          %{name: "email", title: "Email", type: "string", surface: "sidebar", private: true},
          %{
            name: "role",
            title: "Role",
            type: "select",
            options: ["editor", "writer", "contributor", "admin"],
            surface: "sidebar"
          }
        ]
      },
      %{
        name: "category",
        title: "Category",
        icon: "🏷",
        visibility: "public",
        dataset: dataset,
        # surface (t7): title / description read as article; slug and the color
        # swatch are sidebar metadata.
        fields: [
          %{name: "title", title: "Title", type: "string", surface: "body"},
          %{name: "slug", title: "Slug", type: "slug", surface: "sidebar"},
          %{name: "description", title: "Description", type: "text", rows: 2, surface: "body"},
          %{name: "color", title: "Color", type: "color", surface: "sidebar"}
        ]
      },
      %{
        name: "project",
        title: "Project",
        icon: "💼",
        visibility: "public",
        dataset: dataset,
        # surface (t7): title / description / cover image read as article; slug,
        # client + status + start date + featured flag are trade metadata → sidebar.
        fields: [
          %{name: "title", title: "Title", type: "string", surface: "body"},
          %{name: "slug", title: "Slug", type: "slug", surface: "sidebar"},
          %{name: "client", title: "Client", type: "string", surface: "sidebar"},
          %{
            name: "status",
            title: "Status",
            type: "select",
            options: ["planning", "active", "completed", "archived"],
            surface: "sidebar"
          },
          %{name: "description", title: "Description", type: "richText", surface: "body"},
          %{name: "coverImage", title: "Cover Image", type: "image", surface: "body"},
          %{name: "startDate", title: "Start Date", type: "datetime", surface: "sidebar"},
          %{name: "featured", title: "Featured", type: "boolean", surface: "sidebar"}
        ]
      },
      %{
        name: "siteSettings",
        title: "Site Settings",
        icon: "⚙",
        visibility: "private",
        dataset: dataset,
        # explicit desk-placement opt-in (issue #8463): siteSettings is a real
        # host config singleton (one canonical row), not generic content —
        # `singleton: true` keeps it a `:document` Settings row instead of
        # falling into the generic `:document_type_list` bucket every other
        # private schema now gets by default.
        singleton: true,
        # surface (t7): siteSettings is a config singleton — no article body, so
        # every field is settings → sidebar.
        fields: [
          %{name: "title", title: "Site Title", type: "string", surface: "sidebar"},
          %{
            name: "description",
            title: "Site Description",
            type: "text",
            rows: 2,
            surface: "sidebar"
          },
          %{name: "logo", title: "Logo", type: "image", surface: "sidebar"},
          %{name: "analyticsId", title: "Analytics ID", type: "string", surface: "sidebar"}
        ]
      },
      %{
        name: "navigation",
        title: "Navigation",
        icon: "🧭",
        visibility: "private",
        dataset: dataset,
        # explicit desk-placement opt-in (issue #8463) — see siteSettings above.
        singleton: true,
        # surface (t7): navigation is a config singleton — its menu-title label is
        # settings → sidebar.
        fields: [
          %{name: "title", title: "Menu Title", type: "string", surface: "sidebar"}
        ]
      },
      %{
        name: "colors",
        title: "Brand Colors",
        icon: "🎨",
        visibility: "private",
        dataset: dataset,
        # explicit desk-placement opt-in (issue #8463) — see siteSettings above.
        singleton: true,
        # surface (t7): colors is a config singleton — every swatch is settings →
        # sidebar.
        fields: [
          %{name: "primary", title: "Primary", type: "color", surface: "sidebar"},
          %{name: "secondary", title: "Secondary", type: "color", surface: "sidebar"},
          %{name: "accent", title: "Accent", type: "color", surface: "sidebar"}
        ]
      }
    ]

    for schema_attrs <- schemas do
      %SchemaDefinition{}
      |> SchemaDefinition.changeset(schema_attrs)
      |> Shared.stamp_schema_scope(scope)
      |> Repo.insert!(on_conflict: :nothing)
    end

    IO.puts("Seeded #{length(schemas)} schema definitions")

    # ── W7a task schema ─────────────────────────────────────────────────────
    #
    # Wave 7 step 1: everything is a task — a single first-class document type
    # living beside papers in the same workspace/project/dataset hierarchy (a
    # goal/epic is just a root task, a phase is a task with children). The
    # `task` schema is no longer seeded inline here: it is now declared by the
    # **Tasks plugin** (`Barkpark.Plugins.Tasks`) and auto-registered by
    # `Barkpark.Plugins.Bootstrap.register_all_schemas/0` (called by
    # `Barkpark.Seeds.run/1` after the profile body, and on every server boot).
    # This mirrors how the Bulldocs lift removed its inline `paper` seed. The
    # shape contract (`content.kind`, `content.lifecycle_status`, etc.) is
    # still enforced at the write boundary by
    # `Barkpark.Tasks.validate_kind_content/2`. See
    # `lib/barkpark/plugins/tasks.ex` for the wiring and `lib/barkpark/tasks.ex`
    # for the schema builder + status-axis rationale (choice b).

    :ok
  end

  # ── Documents ────────────────────────────────────────────────────────────────

  defp seed_documents(scope) do
    dataset = scope.dataset
    now = DateTime.utc_now()
    hours = fn h -> DateTime.add(now, -h * 3600) end

    documents = [
      # Posts — published (clean ID) + some drafts (drafts. prefix)
      %{
        doc_id: "p1",
        type: "post",
        dataset: dataset,
        title: "Getting Started with Structured Content",
        status: "published",
        content: %{"category" => "Technology", "author" => "Knut Melvaer"},
        inserted_at: hours.(2),
        updated_at: hours.(2)
      },
      %{
        doc_id: "p2",
        type: "post",
        dataset: dataset,
        title: "Why Headless CMS Changes Everything",
        status: "published",
        content: %{"category" => "Technology", "author" => "Simeon Griggs"},
        inserted_at: hours.(26),
        updated_at: hours.(26)
      },
      # p3 is a draft only (never published)
      %{
        doc_id: "drafts.p3",
        type: "post",
        dataset: dataset,
        title: "Content Modeling Best Practices",
        status: "draft",
        content: %{"category" => "Engineering", "author" => "Knut Melvaer"},
        inserted_at: hours.(50),
        updated_at: hours.(50)
      },
      # p4 is a draft only
      %{
        doc_id: "drafts.p4",
        type: "post",
        dataset: dataset,
        title: "Building with Portable Text",
        status: "draft",
        content: %{"category" => "Engineering", "author" => "Simeon Griggs"},
        inserted_at: hours.(74),
        updated_at: hours.(74)
      },
      %{
        doc_id: "p5",
        type: "post",
        dataset: dataset,
        title: "Real-time Collaboration in Practice",
        status: "published",
        content: %{"category" => "Design", "author" => "Knut Melvaer"},
        inserted_at: hours.(98),
        updated_at: hours.(98)
      },
      # p6 has both a published version and a newer draft (edited after publish)
      %{
        doc_id: "p6",
        type: "post",
        dataset: dataset,
        title: "GROQ vs GraphQL Deep Dive",
        status: "published",
        content: %{"category" => "Technology", "author" => "Simeon Griggs"},
        inserted_at: hours.(122),
        updated_at: hours.(122)
      },
      %{
        doc_id: "drafts.p6",
        type: "post",
        dataset: dataset,
        title: "GROQ vs GraphQL Deep Dive (updated draft)",
        status: "draft",
        content: %{"category" => "Technology", "author" => "Simeon Griggs"},
        inserted_at: hours.(2),
        updated_at: hours.(2)
      },
      %{
        doc_id: "p7",
        type: "post",
        dataset: dataset,
        title: "Design Systems for Content Teams",
        status: "published",
        content: %{"category" => "Design", "author" => "Knut Melvaer"},
        inserted_at: hours.(146),
        updated_at: hours.(146)
      },
      %{
        doc_id: "p8",
        type: "post",
        dataset: dataset,
        title: "Deploying Studio to Production",
        status: "published",
        content: %{"category" => "Engineering", "author" => "Simeon Griggs"},
        inserted_at: hours.(170),
        updated_at: hours.(170)
      },

      # Pages
      %{
        doc_id: "pg1",
        type: "page",
        dataset: dataset,
        title: "Home",
        status: "published",
        inserted_at: hours.(4),
        updated_at: hours.(4)
      },
      %{
        doc_id: "pg2",
        type: "page",
        dataset: dataset,
        title: "About Us",
        status: "published",
        inserted_at: hours.(48),
        updated_at: hours.(48)
      },
      %{
        doc_id: "drafts.pg3",
        type: "page",
        dataset: dataset,
        title: "Pricing",
        status: "draft",
        inserted_at: hours.(120),
        updated_at: hours.(120)
      },
      %{
        doc_id: "pg4",
        type: "page",
        dataset: dataset,
        title: "Contact",
        status: "published",
        inserted_at: hours.(168),
        updated_at: hours.(168)
      },
      %{
        doc_id: "pg5",
        type: "page",
        dataset: dataset,
        title: "Terms of Service",
        status: "published",
        inserted_at: hours.(240),
        updated_at: hours.(240)
      },

      # Authors (all published)
      %{
        doc_id: "a1",
        type: "author",
        dataset: dataset,
        title: "Knut Melvaer",
        status: "published",
        content: %{"role" => "admin", "email" => "knut@sanity.io"},
        inserted_at: hours.(300),
        updated_at: hours.(300)
      },
      %{
        doc_id: "a2",
        type: "author",
        dataset: dataset,
        title: "Simeon Griggs",
        status: "published",
        content: %{"role" => "editor", "email" => "simeon@sanity.io"},
        inserted_at: hours.(360),
        updated_at: hours.(360)
      },
      %{
        doc_id: "a3",
        type: "author",
        dataset: dataset,
        title: "Espen Hovlandsdal",
        status: "published",
        content: %{"role" => "writer", "email" => "espen@sanity.io"},
        inserted_at: hours.(420),
        updated_at: hours.(420)
      },

      # Categories (all published)
      %{
        doc_id: "c1",
        type: "category",
        dataset: dataset,
        title: "Technology",
        status: "published",
        content: %{"color" => "#3b82f6"},
        inserted_at: hours.(600),
        updated_at: hours.(600)
      },
      %{
        doc_id: "c2",
        type: "category",
        dataset: dataset,
        title: "Design",
        status: "published",
        content: %{"color" => "#ec4899"},
        inserted_at: hours.(624),
        updated_at: hours.(624)
      },
      %{
        doc_id: "c3",
        type: "category",
        dataset: dataset,
        title: "Engineering",
        status: "published",
        content: %{"color" => "#10b981"},
        inserted_at: hours.(648),
        updated_at: hours.(648)
      },

      # Projects
      %{
        doc_id: "pr1",
        type: "project",
        dataset: dataset,
        title: "Website Redesign",
        status: "published",
        content: %{"client" => "Acme Corp"},
        inserted_at: hours.(8),
        updated_at: hours.(8)
      },
      %{
        doc_id: "drafts.pr2",
        type: "project",
        dataset: dataset,
        title: "Mobile App v3",
        status: "draft",
        content: %{"client" => "StartupX"},
        inserted_at: hours.(52),
        updated_at: hours.(52)
      },
      %{
        doc_id: "pr3",
        type: "project",
        dataset: dataset,
        title: "API Migration",
        status: "published",
        content: %{"client" => "BigCo"},
        inserted_at: hours.(200),
        updated_at: hours.(200)
      },
      %{
        doc_id: "pr4",
        type: "project",
        dataset: dataset,
        title: "Design System",
        status: "published",
        content: %{"client" => "Internal"},
        inserted_at: hours.(270),
        updated_at: hours.(270)
      },

      # Singletons (all published)
      %{
        doc_id: "siteSettings",
        type: "siteSettings",
        dataset: dataset,
        title: "My Studio Site",
        status: "published",
        content: %{
          "description" => "A headless CMS powered site",
          "analyticsId" => "G-XXXXXXXXXX"
        },
        inserted_at: hours.(240),
        updated_at: hours.(240)
      },
      %{
        doc_id: "navigation",
        type: "navigation",
        dataset: dataset,
        title: "Main Navigation",
        status: "published",
        inserted_at: hours.(300),
        updated_at: hours.(300)
      },
      %{
        doc_id: "colors",
        type: "colors",
        dataset: dataset,
        title: "Brand Colors",
        status: "published",
        content: %{"primary" => "#3b82f6", "secondary" => "#6366f1", "accent" => "#f59e0b"},
        inserted_at: hours.(360),
        updated_at: hours.(360)
      }
    ]

    for doc_attrs <- documents do
      doc_attrs =
        doc_attrs
        |> Map.put(:rev, :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
        |> Map.put(:workspace_id, scope.workspace_id)
        |> Map.put(:project_id, scope.project_id)
        |> Map.put(:dataset_id, scope.dataset_id)

      %Document{}
      |> Document.changeset(doc_attrs)
      # AUDIT: OFFLINE-only dev/demo seed — raw-inserts status:"published" rows and
      # deliberately bypasses AuthoringWall (never reachable from any web controller).
      |> Repo.insert!(on_conflict: :nothing)
    end

    IO.puts("Seeded #{length(documents)} documents")
  end

  # ── Dev API Token ────────────────────────────────────────────────────────────

  defp seed_dev_token(scope) do
    dataset = scope.dataset
    dev_token = "barkpark-dev-token"
    dev_perms = ["read", "write", "admin"]

    # Mint the dev token through Auth.create_token so it is BOUND to the Default
    # workspace AND gets a `workspace_memberships` row (principal_type
    # "api_token") in the same transaction — without it ResolveWorkspace 403s
    # every /w/:ws/p/:project/... route and /api/workspaces returns empty.
    # Passing the workspace id explicitly (rather than relying on the nil →
    # default fallback) guarantees the membership branch is taken even if
    # get_default_workspace races. Idempotent: on a re-run the token already
    # exists (unique token_hash), so we skip the insert and only backfill the
    # workspace_id + membership if missing.
    case Auth.verify_token(dev_token) do
      {:error, :unauthorized} ->
        {:ok, _token} =
          Auth.create_token(dev_token, "dev-studio", dataset, dev_perms, scope.workspace_id)

      {:ok, %ApiToken{} = existing} ->
        # Backfill an older seeded token (raw-insert era) that lacks
        # workspace_id and/or its membership row.
        existing =
          if is_nil(existing.workspace_id) do
            {:ok, updated} =
              existing
              |> ApiToken.changeset(%{workspace_id: scope.workspace_id})
              |> Repo.update()

            updated
          else
            existing
          end

        unless TenancyAuth.member?(existing, scope.workspace_id) do
          role = TenancyAuth.role_for_permissions(existing.permissions)

          {:ok, _membership} =
            TenancyAuth.create_membership(scope.workspace_id, existing.id, role)
        end
    end

    IO.puts("Dev token created: #{dev_token}")
    IO.puts("Use with: curl -H 'Authorization: Bearer #{dev_token}' ...")
  end

  # ── Codelist Registry (Bootstrap) ───────────────────────────────────────────

  @doc """
  Seed the EDItEUR + Thema codelist registries from the bundled snapshots.
  Demo-profile only (they serve onixedit, which is not in the clean plugin
  set); called by `Barkpark.Seeds.run(:demo)` AFTER plugin-schema bootstrap
  to keep the pre-extraction console order.
  """
  def seed_codelists do
    # Task barkpark-2nw: seed the codelist registry from the bundled EDItEUR
    # XML snapshot at `priv/codelists/onix-issue-73.xml`. Mirrors the post-boot
    # Task in `Barkpark.Application` so `mix ecto.reset` produces a fully
    # populated DB without a separate `mix barkpark.codelists.seed` step.
    # Idempotent: re-running upserts the codelist + values, with no duplicate
    # rows. Soldiers on if the bundled file is missing.

    IO.puts("\n=== Seeding codelist registry from bundled EDItEUR snapshot ===")

    case Barkpark.Codelists.EDItEUR.seed_bundled() do
      {:ok, :no_snapshot} ->
        IO.puts(
          :stderr,
          "Bundled codelist snapshot missing — skipped (see api/priv/codelists/README.md)"
        )

      {:ok, count} ->
        IO.puts("Seeded #{count} codelist(s) from bundled snapshot")

      {:error, reason} ->
        IO.puts(:stderr, "Codelist seed reported errors: #{inspect(reason)}")
    end

    # Task barkpark-ufw: seed the Thema subject classification (EDItEUR
    # Thema v1.6) from the bundled JSON snapshot at
    # `priv/codelists/thema-1.6/thema-v1.6-en.json`. Thema is published
    # separately from the ONIX codelist bundle — see
    # `priv/codelists/thema-1.6/README.md`. Idempotent on
    # `(onixedit, onixedit:thema, "1.6")`.

    IO.puts("\n=== Seeding Thema codelist from bundled EDItEUR snapshot ===")

    case Barkpark.Codelists.EDItEUR.seed_thema() do
      {:ok, :no_snapshot} ->
        IO.puts(
          :stderr,
          "Bundled Thema snapshot missing — skipped (see api/priv/codelists/thema-1.6/README.md)"
        )

      {:ok, count} ->
        IO.puts("Seeded #{count} Thema codelist(s)")

      {:error, reason} ->
        IO.puts(:stderr, "Thema seed reported errors: #{inspect(reason)}")
    end
  end
end
