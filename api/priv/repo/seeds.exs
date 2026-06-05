alias Barkpark.Repo
alias Barkpark.Content.{Document, SchemaDefinition}
alias Barkpark.Auth
alias Barkpark.Auth.ApiToken
alias Barkpark.Tenancy
alias Barkpark.Tenancy.Auth, as: TenancyAuth

dataset = "production"

# ── Default Workspace / Project (tenancy scope for all seed content) ─────────
#
# Wave 1 tenancy: every seeded schema_definition + document is stamped with the
# Default Workspace / Default Project so a freshly-seeded DB has all content
# under one tenant. The w1-s4 backfill migration seeds these rows on
# `mix ecto.reset` (it runs BEFORE seeds.exs), but seeds also run standalone via
# `mix run priv/repo/seeds.exs` — so reuse Tenancy.get_default_*; create only if
# missing. Idempotent: a present Default is reused, never duplicated.

default_workspace =
  case Tenancy.get_default_workspace() do
    nil ->
      {:ok, ws} = Tenancy.create_workspace(%{slug: "default", name: "Default Workspace"})
      ws

    ws ->
      ws
  end

default_project =
  case Tenancy.get_default_project() do
    nil ->
      {:ok, project} =
        Tenancy.create_project(default_workspace, %{slug: "default", name: "Default Project"})

      project

    project ->
      project
  end

default_ws_id = default_workspace.id
default_project_id = default_project.id

# Resolve the authoritative `dataset_id` for the seed dataset under the Default
# project, get-or-creating the dataset row. This is the SAME key the read path
# resolves to (Content.scope_to_dataset → resolve_read_dataset_id →
# get_dataset): documents are filtered `WHERE dataset_id = <id>` with NO
# NULL-fallback, so a seeded doc left with dataset_id = NULL is invisible to
# every scoped read on a fresh DB. Stamp it onto every seeded document below,
# mirroring Content.resolve_dataset_id_for_write / TenancyFixtures.create_document_in!.
{:ok, %Barkpark.Tenancy.Dataset{id: default_dataset_id}} =
  Tenancy.get_or_create_dataset(default_project_id, dataset)

IO.puts(
  "Default scope: workspace=#{default_ws_id} project=#{default_project_id} dataset_id=#{default_dataset_id}"
)

# SchemaDefinition.changeset/2 does not cast the tenancy FKs (they were added as
# belongs_to without a cast slot); put_change them directly so seeded schemas
# land under Default. Documents cast workspace_id/project_id, so those go through
# attrs instead.
stamp_schema_scope = fn changeset ->
  changeset
  |> Ecto.Changeset.put_change(:workspace_id, default_ws_id)
  |> Ecto.Changeset.put_change(:project_id, default_project_id)
end

# ── Schema Definitions ──────────────────────────────────────────────────────

schemas = [
  %{
    name: "post",
    title: "Post",
    icon: "📄",
    visibility: "public",
    dataset: dataset,
    fields: [
      %{name: "title", title: "Title", type: "string"},
      %{name: "slug", title: "Slug", type: "slug"},
      %{
        name: "status",
        title: "Status",
        type: "select",
        options: ["draft", "published", "archived"]
      },
      %{name: "publishedAt", title: "Published At", type: "datetime"},
      %{name: "excerpt", title: "Excerpt", type: "text", rows: 3},
      %{name: "body", title: "Body", type: "richText"},
      %{name: "featuredImage", title: "Featured Image", type: "image"},
      %{name: "featuredAsset", title: "Featured Asset", type: "reference", refType: "mediaAsset"},
      %{name: "author", title: "Author", type: "reference", refType: "author"},
      %{name: "featured", title: "Featured Post", type: "boolean"}
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
    fields: [
      %{name: "title", title: "Title", type: "string"},
      %{name: "slug", title: "Slug", type: "slug"},
      %{name: "body", title: "Page Content", type: "richText"},
      %{name: "seoTitle", title: "SEO Title", type: "string"},
      %{name: "seoDescription", title: "SEO Description", type: "text", rows: 2},
      %{name: "heroImage", title: "Hero Image", type: "image"},
      %{name: "heroAsset", title: "Hero Asset", type: "reference", refType: "mediaAsset"}
    ]
  },
  %{
    name: "author",
    title: "Author",
    icon: "👤",
    visibility: "public",
    dataset: dataset,
    fields: [
      %{name: "name", title: "Name", type: "string"},
      %{name: "slug", title: "Slug", type: "slug"},
      %{name: "bio", title: "Bio", type: "text", rows: 4},
      %{name: "avatar", title: "Avatar", type: "image"},
      %{name: "email", title: "Email", type: "string"},
      %{
        name: "role",
        title: "Role",
        type: "select",
        options: ["editor", "writer", "contributor", "admin"]
      }
    ]
  },
  %{
    name: "category",
    title: "Category",
    icon: "🏷",
    visibility: "public",
    dataset: dataset,
    fields: [
      %{name: "title", title: "Title", type: "string"},
      %{name: "slug", title: "Slug", type: "slug"},
      %{name: "description", title: "Description", type: "text", rows: 2},
      %{name: "color", title: "Color", type: "color"}
    ]
  },
  %{
    name: "project",
    title: "Project",
    icon: "💼",
    visibility: "public",
    dataset: dataset,
    fields: [
      %{name: "title", title: "Title", type: "string"},
      %{name: "slug", title: "Slug", type: "slug"},
      %{name: "client", title: "Client", type: "string"},
      %{
        name: "status",
        title: "Status",
        type: "select",
        options: ["planning", "active", "completed", "archived"]
      },
      %{name: "description", title: "Description", type: "richText"},
      %{name: "coverImage", title: "Cover Image", type: "image"},
      %{name: "startDate", title: "Start Date", type: "datetime"},
      %{name: "featured", title: "Featured", type: "boolean"}
    ]
  },
  %{
    name: "siteSettings",
    title: "Site Settings",
    icon: "⚙",
    visibility: "private",
    dataset: dataset,
    fields: [
      %{name: "title", title: "Site Title", type: "string"},
      %{name: "description", title: "Site Description", type: "text", rows: 2},
      %{name: "logo", title: "Logo", type: "image"},
      %{name: "analyticsId", title: "Analytics ID", type: "string"}
    ]
  },
  %{
    name: "navigation",
    title: "Navigation",
    icon: "🧭",
    visibility: "private",
    dataset: dataset,
    fields: [
      %{name: "title", title: "Menu Title", type: "string"}
    ]
  },
  %{
    name: "colors",
    title: "Brand Colors",
    icon: "🎨",
    visibility: "private",
    dataset: dataset,
    fields: [
      %{name: "primary", title: "Primary", type: "color"},
      %{name: "secondary", title: "Secondary", type: "color"},
      %{name: "accent", title: "Accent", type: "color"}
    ]
  }
]

for schema_attrs <- schemas do
  %SchemaDefinition{}
  |> SchemaDefinition.changeset(schema_attrs)
  |> stamp_schema_scope.()
  |> Repo.insert!(on_conflict: :nothing)
end

IO.puts("Seeded #{length(schemas)} schema definitions")

# ── W7a task/goal/phase/event schemas (W7 retire-beads substrate) ────────────
#
# Wave 7 step 1: tasks/goals/phases/events are first-class document types
# living beside papers in the same workspace/project/dataset hierarchy. Register
# the four schemas the same way `paper` is seeded above so they appear in the
# Studio desk + `Content.get_schema/2` + `Content.list_schemas/2` immediately
# after `mix ecto.reset`. The shape contracts (`content.kind`,
# `content.lifecycle_status`, etc.) are enforced at the write boundary by
# `Barkpark.Tasks.validate_kind_content/2` (wired into `Content.create_document/4`
# + `Content.upsert_document/4`); the schema rows here are the "first-class
# document type" half (so Studio renders them) — the validation is the
# field-shape half. See `lib/barkpark/tasks.ex` moduledoc for the full
# rationale + status-axis choice (b).

tasks_dataset = "production"

for schema_def <- Barkpark.Tasks.schema_definitions(tasks_dataset) do
  attrs =
    schema_def
    |> Map.from_struct()
    |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])

  %SchemaDefinition{}
  |> SchemaDefinition.changeset(attrs)
  |> stamp_schema_scope.()
  |> Repo.insert!(on_conflict: :nothing)
end

IO.puts("Seeded W7a task/goal/phase/event schemas (dataset=#{tasks_dataset})")

# ── Documents ────────────────────────────────────────────────────────────────

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
    content: %{"description" => "A headless CMS powered site", "analyticsId" => "G-XXXXXXXXXX"},
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
    |> Map.put(:workspace_id, default_ws_id)
    |> Map.put(:project_id, default_project_id)
    |> Map.put(:dataset_id, default_dataset_id)

  %Document{}
  |> Document.changeset(doc_attrs)
  |> Repo.insert!(on_conflict: :nothing)
end

IO.puts("Seeded #{length(documents)} documents")

# ── Dev API Token ────────────────────────────────────────────────────────────

dev_token = "barkpark-dev-token"
dev_perms = ["read", "write", "admin"]

# Mint the dev token through Auth.create_token so it is BOUND to the Default
# workspace AND gets a `workspace_memberships` row (principal_type "api_token")
# in the same transaction — without it ResolveWorkspace 403s every
# /w/:ws/p/:project/... route and /api/workspaces returns empty. Passing
# default_ws_id explicitly (rather than relying on the nil → default fallback)
# guarantees the membership branch is taken even if get_default_workspace races.
# Idempotent: on a re-run the token already exists (unique token_hash), so we
# skip the insert and only backfill the workspace_id + membership if missing.
case Auth.verify_token(dev_token) do
  {:error, :unauthorized} ->
    {:ok, _token} =
      Auth.create_token(dev_token, "dev-studio", dataset, dev_perms, default_ws_id)

  {:ok, %ApiToken{} = existing} ->
    # Backfill an older seeded token (raw-insert era) that lacks workspace_id
    # and/or its membership row.
    existing =
      if is_nil(existing.workspace_id) do
        {:ok, updated} =
          existing
          |> ApiToken.changeset(%{workspace_id: default_ws_id})
          |> Repo.update()

        updated
      else
        existing
      end

    unless TenancyAuth.member?(existing, default_ws_id) do
      role = TenancyAuth.role_for_permissions(existing.permissions)
      {:ok, _membership} = TenancyAuth.create_membership(default_ws_id, existing.id, role)
    end
end

IO.puts("Dev token created: #{dev_token}")
IO.puts("Use with: curl -H 'Authorization: Bearer #{dev_token}' ...")

# ── Plugin Schemas (Bootstrap) ──────────────────────────────────────────────
#
# Mirrors the post-boot Task in Barkpark.Application — when seeds run via
# `mix run priv/repo/seeds.exs` the app is already started, so the registry
# is populated. Idempotent via the (name, dataset) unique index on
# schema_definitions; per-plugin failures are logged inside Bootstrap and
# never raise here.

IO.puts("\n=== Registering plugin schemas ===")

case Barkpark.Plugins.Bootstrap.register_all_schemas() do
  {:ok, count} ->
    IO.puts("Registered #{count} plugin schema(s) via Plugins.Bootstrap")

  {:error, reason} ->
    IO.puts(:stderr, "Plugin schema bootstrap reported errors: #{inspect(reason)}")
end

# ── Codelist Registry (Bootstrap) ───────────────────────────────────────────
#
# Task barkpark-2nw: seed the codelist registry from the bundled EDItEUR
# XML snapshot at `priv/codelists/onix-issue-73.xml`. Mirrors the post-boot
# Task in `Barkpark.Application` so `mix ecto.reset` produces a fully
# populated DB without a separate `mix barkpark.codelists.seed` step.
# Idempotent: re-running upserts the codelist + values, with no duplicate
# rows. Soldiers on if the bundled file is missing.

IO.puts("\n=== Seeding codelist registry from bundled EDItEUR snapshot ===")

case Barkpark.Codelists.EDItEUR.seed_bundled() do
  {:ok, :no_snapshot} ->
    IO.puts(:stderr, "Bundled codelist snapshot missing — skipped (see api/priv/codelists/README.md)")

  {:ok, count} ->
    IO.puts("Seeded #{count} codelist(s) from bundled snapshot")

  {:error, reason} ->
    IO.puts(:stderr, "Codelist seed reported errors: #{inspect(reason)}")
end

# ── Thema Codelist (Bootstrap) ──────────────────────────────────────────────
#
# Task barkpark-ufw: seed the Thema subject classification (EDItEUR
# Thema v1.6) from the bundled JSON snapshot at
# `priv/codelists/thema-1.6/thema-v1.6-en.json`. Thema is published
# separately from the ONIX codelist bundle — see
# `priv/codelists/thema-1.6/README.md`. Idempotent on
# `(onixedit, onixedit:thema, "1.6")`.

IO.puts("\n=== Seeding Thema codelist from bundled EDItEUR snapshot ===")

case Barkpark.Codelists.EDItEUR.seed_thema() do
  {:ok, :no_snapshot} ->
    IO.puts(:stderr, "Bundled Thema snapshot missing — skipped (see api/priv/codelists/thema-1.6/README.md)")

  {:ok, count} ->
    IO.puts("Seeded #{count} Thema codelist(s)")

  {:error, reason} ->
    IO.puts(:stderr, "Thema seed reported errors: #{inspect(reason)}")
end

IO.puts("\n=== Seeding search surface config defaults ===")
Barkpark.Search.SurfaceConfigs.seed_defaults!()
IO.puts("Search surface config defaults seeded")
