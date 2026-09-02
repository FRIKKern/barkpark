test(cli): guard the Hetzner create-advisory enrolment table against source (#14762)

hetzner_lb_cmd.go carried a prose "SEVEN ENROLLED CREATE PAIRS" header
(PDS-D432) calling itself the complete list. Nothing guarded it, so the
three wave-32 pairs enrolled in other files — network/create ip_range,
firewall/create rule_count, zone/create mode — silently understated the
population by three.

Replace the prose-only contract with a machine-checked one:
TestHetznerAdvisoryEnrolmentTableComplete AST-scans every hetzner_*.go
for hzResAsked literals (keyed on enclosing constructor + response field,
so `type`/`location` enrolled by two verbs stay distinct) and reds both
ways — a live pair with no row in hzAdvisoryEnrolledPairs, or a row naming
a pair no site emits. The prose header now lists all ten across three
files and points at the guard.

Mutation-proven: removing the three wave-32 rows reds naming exactly
ip_range/rule_count/mode; injecting a fourth hzResAsked with no row reds
naming it. Full internal/cli suite green.
