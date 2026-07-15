# Codex app-server fixtures

`fake_app_server.py` implements the pinned 0.144.1 stdio JSONL handshake and
the lifecycle scenarios used by `codex_test.exs`. It never launches Codex or a
model turn and reads no credential file. Supported scenarios are `normal`,
`malformed`, `stall_turn`, and `die_on_turn`.
