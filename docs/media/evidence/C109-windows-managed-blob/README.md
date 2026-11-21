<!-- doc-tier: human | canonical-for: managed-local-write-windows-proof | budget: 900tok -->
# Windows managed original-blob proof

15 October 2026: the compiled backend passes 63 owner/adjacent tests and six
further release cases in seven separate test launches. The Windows journey
passes 16 checkpoints in 153903 ms; every owned process stops and
PostgreSQL reports stopped. Synthetic originals, journals and private byte
captures are retained.

The proof observes real PostgreSQL lock waiting in both directions, outer
rollback, a killed precommit worker/database, pending-address byte/copy/delete
refusal before file access, and exact retained intent/originals after server and
database restart. Worker and connection death after actual file I/O leave a
pending physical-effect root; reopening its real journal retains recovery.
Ordinary unreserved HTTP deletion still works on its separate disposable file.

The full Windows build takes 183522 ms, using OTP28/Elixir1.20.1 and
the unchanged locked dependencies. [Provenance](provenance.json) binds compiled
revision ae3be838480c7910b23b9a9568c61d16c08b23a0 to fixture revision a1b7e8fda0140408b137ab23d3dcd74ee8d74b9f; only
the live fixture's cross-VM journal naming changed afterward. All production
input trees match. [Native inputs](native/source-inputs.json),
[result](native/result.json) and [build](build/result.json) carry exact hashes.

Four failed native attempts remain under `retained-failures/`: preboot sandbox
pool starvation; missing source support/nested compiler; inherited release boot
environment; and a repeated integer journal name across fresh VMs. Repairs use
the actual source support, isolate only the test VM environment and allocate UUID
journals. No assertion, security baseline, binding pin or check was weakened.
The final formatter, documentation and 182 annotation-binding checks are under
`gates/`; the original hosted security failures are retained there too.

Live entry points in `api/test/barkpark/media/` are
`media_pending_delete_live.exs`, `media_pending_delete_interrupt_live.exs` and
`local_write_live.exs`. They require a fresh owned database, native-observed
synthetic `C105_PROOF_INPUT` and `C109_JOURNALS`. Never use an existing library.
The retained producer scripts were executed from the Barkdown harness checkout;
their recorded private output paths explain this run, not a production command.
Raw process bytes stay private. Base64 companions retain exact redacted log
bytes; readable .log copies normalize line endings and trailing whitespace.

This proves the original-blob boundary only. Renditions, caches, remote effects,
full writer coverage/reconciliation, native cleanup, HTTP pending-delete adoption
and Barkdown's runtime pin/package remain separate. No real library, model, Mac
transfer, installer execution, merge or deployment occurred. Source CI and
independent documentation review remain required for
[draft PR23205](https://github.com/FRIKKern/barkpark/pull/23205).
