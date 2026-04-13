alias Barkpark.Repo
alias Barkpark.Content.{Document, SchemaDefinition}
alias Barkpark.Auth.ApiToken

dataset = "production"

# ── Schema Definitions ──────────────────────────────────────────────────────

schemas = [
  %{
    name: "post", title: "Post", icon: "📄", visibility: "public", dataset: dataset,
    fields: [
      %{name: "title", title: "Title", type: "string"},
      %{name: "slug", title: "Slug", type: "slug"},
      %{name: "status", title: "Status", type: "select", options: ["draft", "published", "archived"]},
      %{name: "publishedAt", title: "Published At", type: "datetime"},
      %{name: "excerpt", title: "Excerpt", type: "text", rows: 3},
      %{name: "body", title: "Body", type: "richText"},
      %{name: "featuredImage", title: "Featured Image", type: "image"},
      %{name: "author", title: "Author", type: "reference", refType: "author"},
      %{name: "featured", title: "Featured Post", type: "boolean"}
    ]
  },
  %{
    name: "page", title: "Page", icon: "📑", visibility: "public", dataset: dataset,
    fields: [
      %{name: "title", title: "Title", type: "string"},
      %{name: "slug", title: "Slug", type: "slug"},
      %{name: "body", title: "Page Content", type: "richText"},
      %{name: "seoTitle", title: "SEO Title", type: "string"},
      %{name: "seoDescription", title: "SEO Description", type: "text", rows: 2},
      %{name: "heroImage", title: "Hero Image", type: "image"}
    ]
  },
  %{
    name: "author", title: "Author", icon: "👤", visibility: "public", dataset: dataset,
    fields: [
      %{name: "name", title: "Name", type: "string"},
      %{name: "slug", title: "Slug", type: "slug"},
      %{name: "bio", title: "Bio", type: "text", rows: 4},
      %{name: "avatar", title: "Avatar", type: "image"},
      %{name: "email", title: "Email", type: "string"},
      %{name: "role", title: "Role", type: "select", options: ["editor", "writer", "contributor", "admin"]}
    ]
  },
  %{
    name: "category", title: "Category", icon: "🏷", visibility: "public", dataset: dataset,
    fields: [
      %{name: "title", title: "Title", type: "string"},
      %{name: "slug", title: "Slug", type: "slug"},
      %{name: "description", title: "Description", type: "text", rows: 2},
      %{name: "color", title: "Color", type: "color"}
    ]
  },
  %{
    name: "project", title: "Project", icon: "💼", visibility: "public", dataset: dataset,
    fields: [
      %{name: "title", title: "Title", type: "string"},
      %{name: "slug", title: "Slug", type: "slug"},
      %{name: "client", title: "Client", type: "string"},
      %{name: "status", title: "Status", type: "select", options: ["planning", "active", "completed", "archived"]},
      %{name: "description", title: "Description", type: "richText"},
      %{name: "coverImage", title: "Cover Image", type: "image"},
      %{name: "startDate", title: "Start Date", type: "datetime"},
      %{name: "featured", title: "Featured", type: "boolean"}
    ]
  },
  %{
    name: "siteSettings", title: "Site Settings", icon: "⚙", visibility: "private", dataset: dataset,
    fields: [
      %{name: "title", title: "Site Title", type: "string"},
      %{name: "description", title: "Site Description", type: "text", rows: 2},
      %{name: "logo", title: "Logo", type: "image"},
      %{name: "analyticsId", title: "Analytics ID", type: "string"}
    ]
  },
  %{
    name: "navigation", title: "Navigation", icon: "🧭", visibility: "private", dataset: dataset,
    fields: [
      %{name: "title", title: "Menu Title", type: "string"}
    ]
  },
  %{
    name: "colors", title: "Brand Colors", icon: "🎨", visibility: "private", dataset: dataset,
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
  |> Repo.insert!(on_conflict: :nothing)
end

IO.puts("Seeded #{length(schemas)} schema definitions")

# ── Documents ────────────────────────────────────────────────────────────────

now = DateTime.utc_now()
hours = fn h -> DateTime.add(now, -h * 3600) end

documents = [
  # Posts — published (clean ID) + some drafts (drafts. prefix)
  %{doc_id: "p1", type: "post", dataset: dataset, title: "Getting Started with Structured Content", status: "published", content: %{"category" => "Technology", "author" => "Knut Melvaer"}, inserted_at: hours.(2), updated_at: hours.(2)},
  %{doc_id: "p2", type: "post", dataset: dataset, title: "Why Headless CMS Changes Everything", status: "published", content: %{"category" => "Technology", "author" => "Simeon Griggs"}, inserted_at: hours.(26), updated_at: hours.(26)},
  # p3 is a draft only (never published)
  %{doc_id: "drafts.p3", type: "post", dataset: dataset, title: "Content Modeling Best Practices", status: "draft", content: %{"category" => "Engineering", "author" => "Knut Melvaer"}, inserted_at: hours.(50), updated_at: hours.(50)},
  # p4 is a draft only
  %{doc_id: "drafts.p4", type: "post", dataset: dataset, title: "Building with Portable Text", status: "draft", content: %{"category" => "Engineering", "author" => "Simeon Griggs"}, inserted_at: hours.(74), updated_at: hours.(74)},
  %{doc_id: "p5", type: "post", dataset: dataset, title: "Real-time Collaboration in Practice", status: "published", content: %{"category" => "Design", "author" => "Knut Melvaer"}, inserted_at: hours.(98), updated_at: hours.(98)},
  # p6 has both a published version and a newer draft (edited after publish)
  %{doc_id: "p6", type: "post", dataset: dataset, title: "GROQ vs GraphQL Deep Dive", status: "published", content: %{"category" => "Technology", "author" => "Simeon Griggs"}, inserted_at: hours.(122), updated_at: hours.(122)},
  %{doc_id: "drafts.p6", type: "post", dataset: dataset, title: "GROQ vs GraphQL Deep Dive (updated draft)", status: "draft", content: %{"category" => "Technology", "author" => "Simeon Griggs"}, inserted_at: hours.(2), updated_at: hours.(2)},
  %{doc_id: "p7", type: "post", dataset: dataset, title: "Design Systems for Content Teams", status: "published", content: %{"category" => "Design", "author" => "Knut Melvaer"}, inserted_at: hours.(146), updated_at: hours.(146)},
  %{doc_id: "p8", type: "post", dataset: dataset, title: "Deploying Studio to Production", status: "published", content: %{"category" => "Engineering", "author" => "Simeon Griggs"}, inserted_at: hours.(170), updated_at: hours.(170)},

  # Pages
  %{doc_id: "pg1", type: "page", dataset: dataset, title: "Home", status: "published", inserted_at: hours.(4), updated_at: hours.(4)},
  %{doc_id: "pg2", type: "page", dataset: dataset, title: "About Us", status: "published", inserted_at: hours.(48), updated_at: hours.(48)},
  %{doc_id: "drafts.pg3", type: "page", dataset: dataset, title: "Pricing", status: "draft", inserted_at: hours.(120), updated_at: hours.(120)},
  %{doc_id: "pg4", type: "page", dataset: dataset, title: "Contact", status: "published", inserted_at: hours.(168), updated_at: hours.(168)},
  %{doc_id: "pg5", type: "page", dataset: dataset, title: "Terms of Service", status: "published", inserted_at: hours.(240), updated_at: hours.(240)},

  # Authors (all published)
  %{doc_id: "a1", type: "author", dataset: dataset, title: "Knut Melvaer", status: "published", content: %{"role" => "admin", "email" => "knut@sanity.io"}, inserted_at: hours.(300), updated_at: hours.(300)},
  %{doc_id: "a2", type: "author", dataset: dataset, title: "Simeon Griggs", status: "published", content: %{"role" => "editor", "email" => "simeon@sanity.io"}, inserted_at: hours.(360), updated_at: hours.(360)},
  %{doc_id: "a3", type: "author", dataset: dataset, title: "Espen Hovlandsdal", status: "published", content: %{"role" => "writer", "email" => "espen@sanity.io"}, inserted_at: hours.(420), updated_at: hours.(420)},

  # Categories (all published)
  %{doc_id: "c1", type: "category", dataset: dataset, title: "Technology", status: "published", content: %{"color" => "#3b82f6"}, inserted_at: hours.(600), updated_at: hours.(600)},
  %{doc_id: "c2", type: "category", dataset: dataset, title: "Design", status: "published", content: %{"color" => "#ec4899"}, inserted_at: hours.(624), updated_at: hours.(624)},
  %{doc_id: "c3", type: "category", dataset: dataset, title: "Engineering", status: "published", content: %{"color" => "#10b981"}, inserted_at: hours.(648), updated_at: hours.(648)},

  # Projects
  %{doc_id: "pr1", type: "project", dataset: dataset, title: "Website Redesign", status: "published", content: %{"client" => "Acme Corp"}, inserted_at: hours.(8), updated_at: hours.(8)},
  %{doc_id: "drafts.pr2", type: "project", dataset: dataset, title: "Mobile App v3", status: "draft", content: %{"client" => "StartupX"}, inserted_at: hours.(52), updated_at: hours.(52)},
  %{doc_id: "pr3", type: "project", dataset: dataset, title: "API Migration", status: "published", content: %{"client" => "BigCo"}, inserted_at: hours.(200), updated_at: hours.(200)},
  %{doc_id: "pr4", type: "project", dataset: dataset, title: "Design System", status: "published", content: %{"client" => "Internal"}, inserted_at: hours.(270), updated_at: hours.(270)},

  # Singletons (all published)
  %{doc_id: "siteSettings", type: "siteSettings", dataset: dataset, title: "My Studio Site", status: "published", content: %{"description" => "A headless CMS powered site", "analyticsId" => "G-XXXXXXXXXX"}, inserted_at: hours.(240), updated_at: hours.(240)},
  %{doc_id: "navigation", type: "navigation", dataset: dataset, title: "Main Navigation", status: "published", inserted_at: hours.(300), updated_at: hours.(300)},
  %{doc_id: "colors", type: "colors", dataset: dataset, title: "Brand Colors", status: "published", content: %{"primary" => "#3b82f6", "secondary" => "#6366f1", "accent" => "#f59e0b"}, inserted_at: hours.(360), updated_at: hours.(360)}
]

for doc_attrs <- documents do
  %Document{}
  |> Document.changeset(doc_attrs)
  |> Repo.insert!(on_conflict: :nothing)
end

IO.puts("Seeded #{length(documents)} documents")

# ── Dev API Token ────────────────────────────────────────────────────────────

dev_token = "barkpark-dev-token"

%ApiToken{}
|> ApiToken.changeset(%{
  token_hash: ApiToken.hash_token(dev_token),
  label: "dev-studio",
  dataset: dataset,
  permissions: ["read", "write", "admin"]
})
|> Repo.insert!(on_conflict: :nothing)

IO.puts("Dev token created: #{dev_token}")
IO.puts("Use with: curl -H 'Authorization: Bearer #{dev_token}' ...")
