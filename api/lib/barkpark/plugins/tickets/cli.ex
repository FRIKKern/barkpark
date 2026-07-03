defmodule Barkpark.Plugins.Tickets.CLI do
  @moduledoc """
  Tickets — the `bp` CLI manifest surface, folded into `GET /v1/capabilities`.

  The API design IS the CLI design (charter Decision 5): every ticket verb the
  operator or key-holder types on the command line falls out of the capabilities
  manifest with zero bespoke Go code. This module returns the command maps in the
  frozen `cli_command()` shape (the same shape `Barkpark.Plugins.Tasks.cli_commands/0`
  emits — `docs/cli/manifest.schema.json#/$defs/command`); the plugin module
  `tickets.ex` delegates its `cli_commands/0` here via
  `Code.ensure_loaded?(Tickets.CLI)`, so the two slices merge cleanly across
  worktrees even when only one of them has landed.

  ## Two nouns, disjoint paths

    * `ticket` — the support conversation. Operator verbs (`inbox`, `show`,
      `answer`, `close`) ride the `:token_root` bucket (bearer-gated, mounted at
      `/v1/tickets/inbox*` and `/v1/tickets/:id/{answer,close}`); the key-holder
      verbs (`ls`, `file`, `reply`) ride the `:ticket_key` bucket (mounted at
      `/v1/tickets`). Both share the `ticket` noun with disjoint routes — the
      submitter never sees the operator's inbox, and vice versa.
    * `ticket-key` — the named low-trust credential. `mint`/`ls`/`rotate`/`pause`/
      `revoke` are admin-only key management under the `/v1/plugins/tickets/keys`
      surface.

  ## Auth tiers (manifest projection)

  Every `ticket` verb is `read`-tier and every `ticket-key` verb is `admin`-tier —
  mirroring the Tasks precedent (`/v1/tasks` workflow writes stay `read`-tier
  because they are bearer-gated ops, not admin document mutations). The manifest
  tier controls existence-hiding visibility only; the SERVER's `RequireTicketKey`
  / `RequireToken` / `RequireAdmin` pipelines are the real boundary. A `ticket`
  key-holder configures their raw `bptk_…` key as the `bp` token; the read-tier
  `authHeaders` path forwards it as `Authorization: Bearer …`, which only the
  `:ticket_key` routes accept (the `kind` guard rejects it everywhere else).

  ## The 2-minute handoff card (charter Decision 6)

  `ticket-key mint` defaults to `table` output. The mint response carries a
  `quickstart` string — the raw key (once) plus three verbatim curl commands — and
  the Go renderer prints that block verbatim as the primary human output. `rotate`
  likewise defaults to `table` so the freshly-minted secret is visible (a `minimal`
  receipt would hide the one thing the operator needs to forward).
  """

  @doc """
  The ticket + ticket-key CLI command maps, in the frozen `cli_command()` shape.

  Consumed by `Barkpark.Plugins.Tickets.cli_commands/0` (the plugin delegate) and
  folded into the capabilities manifest by the capabilities controller, which
  stamps `source: "plugin:tickets"` provenance from the `ticket` / `ticket-key`
  nouns.
  """
  @spec commands() :: [map()]
  def commands do
    ticket_commands() ++ ticket_key_commands()
  end

  # ── noun: ticket ───────────────────────────────────────────────────────────

  defp ticket_commands do
    [
      %{
        id: "ticket.inbox",
        noun: "ticket",
        verb: "inbox",
        summary:
          "Operator triage: tickets waiting on you, oldest-waiting first (status=open).",
        http: %{method: "GET", path_template: "/v1/tickets/inbox"},
        auth_tier: "read",
        args: [],
        flags: [
          %{name: "limit", type: "int", summary: "Max tickets to return.", default: 50}
        ],
        writes: false,
        batch: false,
        paginated: true,
        dry_run: false,
        default_output: "table",
        scoped_prefix: nil
      },
      %{
        id: "ticket.ls",
        noun: "ticket",
        verb: "ls",
        summary: "List the tickets this key has filed (key-holder's own threads).",
        http: %{method: "GET", path_template: "/v1/tickets"},
        auth_tier: "read",
        args: [],
        flags: [
          %{name: "limit", type: "int", summary: "Max tickets to return.", default: 50}
        ],
        writes: false,
        batch: false,
        paginated: true,
        dry_run: false,
        default_output: "table",
        scoped_prefix: nil
      },
      %{
        id: "ticket.show",
        noun: "ticket",
        verb: "show",
        summary: "Show one ticket thread (operator detail: subject, status, messages).",
        http: %{method: "GET", path_template: "/v1/tickets/inbox/:id"},
        auth_tier: "read",
        args: [
          %{name: "id", required: true, type: "string", summary: "Ticket id."}
        ],
        flags: [],
        writes: false,
        batch: false,
        paginated: false,
        dry_run: false,
        default_output: "table",
        scoped_prefix: nil
      },
      %{
        id: "ticket.file",
        noun: "ticket",
        verb: "file",
        summary: "File a new ticket (request/question). Runs with a ticket key.",
        http: %{method: "POST", path_template: "/v1/tickets"},
        auth_tier: "read",
        args: [
          %{name: "subject", required: true, type: "string", summary: "One-line subject."},
          %{name: "body", required: true, type: "string", summary: "Ticket body / question."}
        ],
        flags: [],
        writes: true,
        batch: false,
        paginated: false,
        dry_run: false,
        default_output: "minimal",
        scoped_prefix: nil
      },
      %{
        id: "ticket.reply",
        noun: "ticket",
        verb: "reply",
        summary:
          "Append a message to a ticket thread. A key-holder reply auto-reopens an answered ticket.",
        http: %{method: "POST", path_template: "/v1/tickets/:id/messages"},
        auth_tier: "read",
        args: [
          %{name: "id", required: true, type: "string", summary: "Ticket id."},
          %{name: "body", required: true, type: "string", summary: "Message body."}
        ],
        flags: [],
        writes: true,
        batch: false,
        paginated: false,
        dry_run: false,
        default_output: "minimal",
        scoped_prefix: nil
      },
      %{
        id: "ticket.answer",
        noun: "ticket",
        verb: "answer",
        summary:
          "Operator answer (flips status to answered — the key-holder's move). --close answers and closes in one write.",
        http: %{method: "POST", path_template: "/v1/tickets/:id/answer"},
        auth_tier: "read",
        args: [
          %{name: "id", required: true, type: "string", summary: "Ticket id to answer."},
          %{name: "body", required: true, type: "string", summary: "The answer text."}
        ],
        flags: [
          %{
            name: "close",
            type: "bool",
            summary: "Close the ticket in the same write (answer + close)."
          }
        ],
        writes: true,
        batch: false,
        paginated: false,
        dry_run: false,
        default_output: "minimal",
        scoped_prefix: nil
      },
      %{
        id: "ticket.close",
        noun: "ticket",
        verb: "close",
        summary: "Close a ticket (status=closed, done).",
        http: %{method: "POST", path_template: "/v1/tickets/:id/close"},
        auth_tier: "read",
        args: [
          %{name: "id", required: true, type: "string", summary: "Ticket id to close."}
        ],
        flags: [],
        writes: true,
        batch: false,
        paginated: false,
        dry_run: false,
        default_output: "minimal",
        scoped_prefix: nil
      }
    ]
  end

  # ── noun: ticket-key ───────────────────────────────────────────────────────

  defp ticket_key_commands do
    [
      %{
        id: "ticket-key.mint",
        noun: "ticket-key",
        verb: "mint",
        summary:
          "Mint a named ticket key + print the forwardable handoff card (raw key once + curl quickstart).",
        http: %{method: "POST", path_template: "/v1/plugins/tickets/keys"},
        auth_tier: "admin",
        args: [
          %{
            name: "name",
            required: true,
            type: "string",
            summary: "Human label for the key-holder (e.g. \"Gyldendal — Kari\")."
          }
        ],
        flags: [],
        writes: true,
        batch: false,
        paginated: false,
        dry_run: false,
        # `table` so the response's `quickstart` handoff card is the primary
        # human output (a `minimal` receipt would hide the raw key + curls).
        default_output: "table",
        scoped_prefix: nil
      },
      %{
        id: "ticket-key.ls",
        noun: "ticket-key",
        verb: "ls",
        summary: "List ticket keys (name, state, last-used).",
        http: %{method: "GET", path_template: "/v1/plugins/tickets/keys"},
        auth_tier: "admin",
        args: [],
        flags: [],
        writes: false,
        batch: false,
        paginated: false,
        dry_run: false,
        default_output: "table",
        scoped_prefix: nil
      },
      %{
        id: "ticket-key.rotate",
        noun: "ticket-key",
        verb: "rotate",
        summary: "Rotate a key's secret (same identity + history, new raw key).",
        http: %{method: "POST", path_template: "/v1/plugins/tickets/keys/:id/rotate"},
        auth_tier: "admin",
        args: [
          %{name: "id", required: true, type: "string", summary: "Ticket key id to rotate."}
        ],
        flags: [],
        writes: true,
        batch: false,
        paginated: false,
        dry_run: false,
        # `table` so the freshly-minted secret is visible (see mint).
        default_output: "table",
        scoped_prefix: nil
      },
      %{
        id: "ticket-key.pause",
        noun: "ticket-key",
        verb: "pause",
        summary: "Pause a key (403 on use; the thread and its history survive).",
        http: %{method: "POST", path_template: "/v1/plugins/tickets/keys/:id/pause"},
        auth_tier: "admin",
        args: [
          %{name: "id", required: true, type: "string", summary: "Ticket key id to pause."}
        ],
        flags: [],
        writes: true,
        batch: false,
        paginated: false,
        dry_run: false,
        default_output: "minimal",
        scoped_prefix: nil
      },
      %{
        id: "ticket-key.revoke",
        noun: "ticket-key",
        verb: "revoke",
        summary: "Revoke a key (indistinguishable from missing = 401 on use).",
        http: %{method: "DELETE", path_template: "/v1/plugins/tickets/keys/:id"},
        auth_tier: "admin",
        args: [
          %{name: "id", required: true, type: "string", summary: "Ticket key id to revoke."}
        ],
        flags: [],
        writes: true,
        batch: false,
        paginated: false,
        dry_run: false,
        default_output: "minimal",
        scoped_prefix: nil
      }
    ]
  end
end
