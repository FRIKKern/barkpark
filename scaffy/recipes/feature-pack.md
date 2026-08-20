<!-- doc-tier: human | canonical-for: scaffy-recipes | budget: none -->
# Recipe: feature-pack — a complete thin-CRUD feature in six commands

A **recipe** is a documented shell sequence over existing catalog commands (charter D80:
chain primitives are rejected; the recipe IS the composition surface). This one births a
complete Barkpark feature — plugin, schema, route, CLI verb, Go nouns, SDK method — on
virgin ground, with every registration op landing on marks the previous command planted.

**Proven end-to-end** (bookmarks spec re-run, 2026-07-18, envelope
`tooling/scaffy-duels/results/bookmarks-rerun--S--1.agent.json`): six engine runs, zero
guard-skipped ops, zero hand-bridged registrations, full WORKING bar green, `remove` in
reverse order byte-clean. 440s wall including gates vs ~1170s hand-built.

## The sequence (order matters — each step anchors on the previous one's output)

Substitute your own feature for the worked `bookmarks` values:

```sh
# 1. The plugin skeleton — ships register_routes / cli_commands / register_schemas
#    EMPTY-OPEN with zone marks; everything below anchors on them.
bp scaffy run scaffy/commands/add-plugin.scaffy \
  --var PluginName=bookmarks --var Description="Users bookmark documents."

# 2. A schema type, declared BY the plugin (lands on the register-schemas zones).
bp scaffy run scaffy/commands/add-schema-type.scaffy \
  --var Plugin=bookmarks --var SchemaName=bookmark \
  --var Title=Bookmarks --var Visibility=private --var Icon=🔖

# 3. A route in the plugin's register_routes/1.
bp scaffy run scaffy/commands/add-plugin-route.scaffy \
  --var Plugin=bookmarks --var Method=get --var Path=/bookmarks/recent \
  --var Controller=BarkparkWeb.BookmarksController --var ActionName=Recent \
  --var AuthBucket=Token

# 4. A CLI verb in the plugin's cli_commands/0.
bp scaffy run scaffy/commands/add-cli-verb.scaffy \
  --var Plugin=bookmarks --var Noun=bookmark --var Verb=recent \
  --var PathTemplate=/v1/bookmarks/recent \
  --var Summary="List the caller's recent bookmarks"

# 5. The Go noun, in BOTH mirror copies (builtins.go + usage.go).
bp scaffy run scaffy/commands/ensure-cli-noun.scaffy --var Noun=bookmark

# 6. The SDK method — six-file house shape (module, msw test, types, client, indexes).
bp scaffy run scaffy/commands/add-sdk-method.scaffy \
  --var MethodName=GetRecentBookmarks --var TypeBase=RecentBookmarks \
  --var HttpPath=/v1/bookmarks/recent --var Summary="the caller's recent bookmarks"
```

## What stays yours (declared out of automated scope)

Two content-level edits the commands intentionally do not own:

1. **Schema fields** — the scaffold ships one sample field; replace it with your real
   `fields` array (the bookmarks run needed `doc_id` + `note`).
2. **Plugin manifest/README declarations** — capabilities / schemas / nouns prose in
   `plugin.json` + README (each command's "manual steps" note calls these out).

Controller implementations, LiveView, and migrations are separate work — the recipe wires
registration, not behavior.

## Reversal

`bp scaffy remove` the receipts in **reverse order** (6 → 1). Proven byte-clean
(`git status --short` empty). Drift in any injected span refuses loudly — that refusal is
the feature, not a bug (never force past it; reconcile the hand edit first).

## Laws this recipe encodes

- **Chain members must anchor on each other's outputs** — commands authored against
  existing exemplars do not automatically compose with commands that CREATE fresh
  instances. A chain is only proven end-to-end on virgin ground (this one is).
- **Catalog-first**: if you are an agent about to hand-edit any of these six shapes,
  run the recipe step instead (measured law, `/papers/scaffy-benchmark`).
