# dr-w22-gate-probe — THROWAWAY

Deploy-reliability wave 22, verifier probe `gate-can-lose`.

Purpose: measure, on live GitHub, what the four REQUIRED contexts
("Elixir gate", "Cloud gate", "Console gate", "PR references an active task")
conclude for a PR that touches ONLY a file in a brand-new top-level directory —
i.e. a candidate siting for a wave-22 slice that compiles nothing.

This directory is deleted with the probe PR. It must never merge.
