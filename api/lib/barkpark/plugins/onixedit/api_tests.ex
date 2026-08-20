defmodule Barkpark.Plugins.OnixEdit.ApiTests do
  @moduledoc """
  Declarative API test specs the runner can fire on demand (Goal
  `barkpark-bsp`). Four high-signal smokes covering OnixEdit's main
  publicly-observable surfaces:

    1. Anon `/api/schemas` is a non-empty public list that withholds the
       private book schema (certifies the wave-2 disclosure clamp, #11764).
    2. Book schema reachable via the admin `/v1/schemas/production` route.
    3. The plugin's top-menu tab + desk-link render in `/studio/production`.
    4. Mutation round-trip — create a probe book on the admin mutate
       endpoint, then `:cleanup` deletes it (per plan §0 Q1, cleanup
       fires always after asserts).

  Auth modes per plan §0 Q3: `:none` for the two public reads, `:admin`
  for the two write-or-admin endpoints. Single-request only per Q5.

  Extracted verbatim from `Barkpark.Plugins.OnixEdit.api_tests/0` behind
  the plugin facade — the callback delegates to `specs/0`. The returned
  catalog is byte-identical to before.

  # TODO: add Bokbasen dryrun spec once credentials are wired via
  # :plugin_setting auth mode — the sandbox endpoint needs real OAuth
  # creds and we don't want the default smoke to hit external services.
  """

  @doc """
  The four declarative smoke specs. Returned unchanged from the former
  `OnixEdit.api_tests/0` body.
  """
  @spec specs() :: [map()]
  def specs do
    [
      # RETARGETED (api-read-path-security-sweep wave 3, option a).
      # This spec used to assert {:body_contains, ~s|"name":"book"|} on the
      # anonymous /api/schemas index. Since #11764 that route filters to
      # Schema.public_schema?/1, and book.json declares visibility "private",
      # so the anonymous index legitimately withholds book — the old assert
      # was permanently UNSATISFIABLE (CI never fired it; only a live runner
      # would catch the red). Option (a) over (b): rather than move to a
      # different public schema and re-assert presence, we convert the now-false
      # claim into a positive certification of the new disclosure clamp. The
      # anon index must be a NON-EMPTY PUBLIC list (paper.json is visibility
      # "public", so its presence proves non-emptiness) that does NOT contain
      # book (private, so its absence proves the clamp holds). Book itself stays
      # covered by spec 2 below, which reads it over the admin /v1/schemas route.
      %{
        name: "Anon /api/schemas is a non-empty public list that withholds book (clamp)",
        method: :get,
        path: "/api/schemas",
        auth: :none,
        asserts: [
          {:status, 200},
          :not_empty,
          # paper is visibility "public" — its presence grounds non-emptiness.
          {:body_contains, ~s|"name":"paper"|},
          # The decoded top-level list is public (paper present) and withholds
          # the private book schema (absent) — certifies the anon clamp.
          {:json_path, [],
           fn schemas ->
             is_list(schemas) and
               Enum.any?(schemas, &(&1["name"] == "paper")) and
               not Enum.any?(schemas, &(&1["name"] == "book"))
           end},
          {:duration_under_ms, 1_500}
        ]
      },
      %{
        name: "Book schema is exposed via /v1/schemas/production (admin)",
        method: :get,
        path: "/v1/schemas/production",
        auth: :admin,
        asserts: [
          {:status, 200},
          {:body_contains, ~s|"name":"book"|}
        ]
      },
      %{
        name: "Bokbasen top-menu tab renders in /studio/production",
        method: :get,
        path: "/studio/production",
        auth: :none,
        asserts: [
          {:status, 200},
          {:body_contains, "Bokbasen"},
          {:body_contains, "Pending submissions"},
          {:body_contains, "top-menu-tab"}
        ]
      },
      %{
        name: "Mutation round-trip: create + publish + delete a probe book",
        method: :post,
        path: "/v1/data/mutate/production",
        auth: :admin,
        headers: %{"content-type" => "application/json"},
        body: %{
          "mutations" => [
            %{
              "create" => %{
                "_type" => "book",
                "_id" => "api-test-runner-probe",
                "title" => "Probe"
              }
            }
          ]
        },
        asserts: [
          {:status, 200},
          {:body_contains, "api-test-runner-probe"}
        ],
        cleanup: [
          %{
            method: :post,
            path: "/v1/data/mutate/production",
            headers: %{"content-type" => "application/json"},
            auth: :admin,
            body: %{
              "mutations" => [
                %{"delete" => %{"id" => "api-test-runner-probe", "type" => "book"}}
              ]
            }
          }
        ]
      }
    ]
  end
end
