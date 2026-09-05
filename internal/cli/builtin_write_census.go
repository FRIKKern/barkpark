package cli

// BUILT-IN WRITE RECEIPTS — the census the wave-29 write fence needs and did
// not have.
//
// screenWriteReceipt (run.go) sits at runCommand's post-2xx hook, so it covers
// the GENERIC manifest path: all 93 manifest write verbs, in all four output
// shapes. #15900 extended the same ONE verdict (writeReceiptVerdict) to every
// manifest-dispatched MCP write, and #15917 (task-c3c5b24d4724f95e) to the two
// curated MCP chat built-ins. What NONE of those reach is the BUILT-IN CLI
// verbs: commands that compose their own request and render their own receipt
// without ever entering runCommand. A proxy page, an empty 200 or an error
// envelope on a 2xx is laundered into a success line on every one of them that
// derives its receipt from the STATUS rather than from the BODY.
//
// This table is that population, re-derived from source. It is not a curated
// list: builtinWriteCensusDerive (builtin_write_census_test.go) recomputes the
// (file, function) → site-count map from the source tree on every test run and
// reds when the two disagree, so a NEW built-in write — or a new call site
// inside a censused function — cannot land without a row here.
//
// WHAT THE DERIVATION SEES, and what it cannot. Two signals, both line-level
// over internal/cli/**.go minus _test.go, mcp*.go and run.go:
//
//	(a) RAW TRANSPORT — a line naming http.MethodPost/Put/Patch/Delete or the
//	    literal "POST"/"PUT"/"PATCH"/"DELETE". This catches doRequest, direct
//	    http.NewRequest[WithContext], and the wrappers that take the method as
//	    an argument (supportMainJSON, cp.do, tinkerRequest).
//	(b) APICLIENT — a call to an internal/apiclient *Client method that is
//	    TRANSITIVELY a write, on an expression the file itself proves is an
//	    *apiclient.Client. The write-method set is derived from
//	    internal/apiclient source too, so adding a write method there and
//	    calling it from a built-in reds on BOTH halves.
//
// It CANNOT see a write whose method string is computed at runtime, nor one
// issued from outside internal/cli. That bound is named, not hidden: the fence
// this census governs is the one the CLI's own built-ins can reach.
type builtinWriteReceipt struct {
	// File is the repo-relative path; Func the enclosing function name.
	File string
	Func string
	// Sites is how many write call sites the derivation finds in Func. It is
	// part of the key on purpose: runSeed issues TWO mutate POSTs (the batch
	// and the --publish follow-up) and a fence on one is not a fence on both.
	Sites int
	// Endpoint names what is written, for a reader who is not going to open
	// the file.
	Endpoint string
	// Class is machineRendered when the receipt reaches a caller as structured
	// output (-o json/yaml, renderRaw, emitStructured) or as a number a script
	// can read back; humanOnly when it only ever reaches a terminal.
	//
	// The class does NOT decide whether the receipt is screened — a human line
	// that lies is still a lie. It decides how loud the lie is, and therefore
	// the order this census was worked in.
	Class string
	// Disposition is the decision, and every row carries exactly one:
	//
	//	dispScreened   — the 2xx goes through screenBuiltinWriteReceipt, i.e.
	//	                 through writeReceiptVerdict, the ONE verdict function.
	//	dispCannotLie  — the receipt is STRUCTURALLY unable to lie: the success
	//	                 line is derived from a decoded typed field the server
	//	                 must supply, so an empty/HTML/null/error-envelope body
	//	                 cannot produce it. Why is the proof.
	//	dispOutOfFence — a write to a NON-Barkpark API (Hetzner, Vercel's own
	//	                 control plane) or a surface with its own census. Named
	//	                 so the population is complete; not screened here.
	Disposition string
	// Why is the one-sentence justification. For dispCannotLie it must name
	// the field the server has to supply; for dispOutOfFence, the other owner.
	Why string
}

const (
	machineRendered = "machine-rendered"
	humanOnly       = "human-only"

	dispScreened   = "screened"
	dispCannotLie  = "cannot-lie"
	dispOutOfFence = "out-of-fence"
)

// builtinWriteCensus is the whole built-in write population. Sorted by file.
var builtinWriteCensus = []builtinWriteReceipt{
	// ---- chat ------------------------------------------------------------
	{
		File: "internal/cli/chat_cmd.go", Func: "runChatUnarchive", Sites: 1,
		Endpoint: "POST /v1/chat/sessions/:id/unarchive", Class: machineRendered,
		Disposition: dispScreened,
		Why: "the SAME shape #15917 fenced on the MCP side: chatArchiveFlip json.Unmarshals a 200 into ChatSession, " +
			"and {}, null and {\"result\":null} all decode to a ZERO session with a nil error — printed as " +
			"`unarchived   untitled session` at rc=0.",
	},
	// ---- cloud / hetzner: their own census (hzResDone), classified only ----
	{
		File: "internal/cli/cloud/dns.go", Func: "newUpsertRequest", Sites: 1,
		Endpoint: "POST <hetzner-dns>/records", Class: humanOnly,
		Disposition: dispOutOfFence,
		Why:         "Hetzner's DNS API, not Barkpark — the write fence's verdict is about Barkpark receipt shapes.",
	},
	{
		File: "internal/cli/cloud/dns.go", Func: "newDeleteByIDRequest", Sites: 1,
		Endpoint: "DELETE <hetzner-dns>/records/:id", Class: humanOnly,
		Disposition: dispOutOfFence,
		Why:         "Hetzner's DNS API, not Barkpark.",
	},
	{
		File: "internal/cli/cloud_support_cmd.go", Func: "stepRosterRow", Sites: 1,
		Endpoint: "POST /v1/data/mutate/:dataset", Class: humanOnly,
		Disposition: dispOutOfFence,
		Why:         "the cloud/support surface carries its own receipt census (hzResDone); classified here, screened there.",
	},
	{
		File: "internal/cli/cloud_support_cmd.go", Func: "stepBind", Sites: 2,
		Endpoint: "POST /v1/fleet/support-tokens; POST <cp>/v1/fleet/supports", Class: humanOnly,
		Disposition: dispOutOfFence,
		Why:         "cloud/support census (hzResDone).",
	},
	{
		File: "internal/cli/cloud_support_cmd.go", Func: "stepToken", Sites: 1,
		Endpoint: "DELETE /v1/fleet/support-tokens/:id", Class: humanOnly,
		Disposition: dispOutOfFence,
		Why:         "cloud/support census (hzResDone).",
	},
	{
		File: "internal/cli/cloud_support_cmd.go", Func: "stepRoster", Sites: 1,
		Endpoint: "POST /v1/data/mutate/:dataset", Class: humanOnly,
		Disposition: dispOutOfFence,
		Why:         "cloud/support census (hzResDone).",
	},
	{
		File: "internal/cli/cloud_support_cmd.go", Func: "stepCPRow", Sites: 1,
		Endpoint: "DELETE <cp>/v1/fleet/supports/:id", Class: humanOnly,
		Disposition: dispOutOfFence,
		Why:         "cloud/support census (hzResDone).",
	},
	{
		File: "internal/cli/cloud_support_cmd.go", Func: "supportTokenProbe", Sites: 1,
		Endpoint: "POST /v1/fleet/support-tokens (probe)", Class: humanOnly,
		Disposition: dispOutOfFence,
		Why:         "cloud/support census (hzResDone); a reachability probe, whose only output is the status.",
	},
	// ---- cloud workspace transfer ----------------------------------------
	{
		File: "internal/cli/cloud_workspace_cmd.go", Func: "runCloudWorkspaceImport", Sites: 1,
		Endpoint: "POST <base>/api/workspaces/:slug/import", Class: machineRendered,
		Disposition: dispScreened,
		Why: "the machine view is out.renderRaw(body) VERBATIM — an HTML proxy page on a 200 was echoed as the " +
			"import receipt at rc=0, and the human view's importCounts({}) printed `0 rows across 0 tables` as a success.",
	},
	{
		File: "internal/cli/cloud_workspace_cmd.go", Func: "putOneBlob", Sites: 1,
		Endpoint: "PUT <base>/api/workspaces/:slug/media/blob/:path", Class: humanOnly,
		Disposition: dispCannotLie,
		Why: "the success path REQUIRES a `bytes` number the server echoed AND requires it to equal the bytes sent; " +
			"a nil `bytes` is already `target accepted the blob but echoed no byte count — the transfer cannot be verified`.",
	},
	// ---- cmux ------------------------------------------------------------
	{
		File: "internal/cli/cmux_dispatch.go", Func: "runCmuxDispatch", Sites: 1,
		Endpoint: "POST /v1/tasks/:id/claim (TaskClaimResources)", Class: humanOnly,
		Disposition: dispCannotLie,
		Why: "TaskClaimResources reports a WON claim only on env.OK==true AND a decoded doc.claim.epoch>0; " +
			"{}, null and {\"result\":null} decode to ok:false (a SKIP, not a success), a non-JSON body fails " +
			"taskPostRaw's decode, and an ok:true carrying no positive epoch is an explicit hard error.",
	},
	{
		File: "internal/cli/cmux_hook.go", Func: "hookPreToolUse", Sites: 1,
		Endpoint: "POST /v1/tasks/:id/pulse (TaskPulse)", Class: humanOnly,
		Disposition: dispCannotLie,
		Why: "TaskPulse goes through taskPost, which refuses anything but ok:true, and then REQUIRES a decoded " +
			"doc.claim.epoch>0 — `pulse …: server returned no fencing epoch`.",
	},
	{
		File: "internal/cli/cmux_hook.go", Func: "hookReclaimEpoch", Sites: 1,
		Endpoint: "POST /v1/tasks/:id/claim (TaskClaimN)", Class: humanOnly,
		Disposition: dispCannotLie,
		Why:         "TaskClaimN: same taskPost ok:true wall plus the same doc.claim.epoch>0 requirement.",
	},
	{
		File: "internal/cli/cmux_hook.go", Func: "hookCloseAtEpoch", Sites: 1,
		Endpoint: "POST /v1/tasks/:id/close (TaskCloseN)", Class: humanOnly,
		Disposition: dispCannotLie,
		Why: "TaskCloseN goes through taskPost: the success line needs `ok:true`, which only the server can supply. " +
			"{} / null / {\"result\":null} all decode to ok:false and become an error; a non-JSON or empty body " +
			"fails the envelope decode outright.",
	},
	// ---- hetzner control plane -------------------------------------------
	{
		File: "internal/cli/hetzner_instance_cmd.go", Func: "Deprovision", Sites: 1,
		Endpoint: "POST <cp>/v1/internal/barkparks/:id/deprovision", Class: humanOnly,
		Disposition: dispOutOfFence,
		Why:         "the cloud control-plane surface, which has its own receipt census (hzResDone).",
	},
	{
		File: "internal/cli/hetzner_instance_cmd.go", Func: "Adopt", Sites: 1,
		Endpoint: "POST <cp>/v1/internal/barkparks", Class: humanOnly,
		Disposition: dispOutOfFence,
		Why:         "cloud control-plane census (hzResDone).",
	},
	// ---- migrate ---------------------------------------------------------
	{
		File: "internal/cli/migrate_cmd.go", Func: "migrateSchemas", Sites: 1,
		Endpoint: "POST /v1/schemas/:dataset", Class: machineRendered,
		Disposition: dispScreened,
		Why: "count++ fires on the 2xx STATUS alone and nothing reads the body, so an empty 200 or an HTML page " +
			"per schema printed `✓ schemas: N POSTed to target` and put N in the -o json receipt.",
	},
	{
		File: "internal/cli/migrate_cmd.go", Func: "migrateWriteBatch", Sites: 1,
		Endpoint: "POST /v1/data/mutate/:dataset", Class: machineRendered,
		Disposition: dispCannotLie,
		Why: "migrateBatchWritten counts the SERVER's `results` array and errors when it is absent or unparsable " +
			"(`we could not tell` must never be reported as `all of them landed`); every poison body yields a nil " +
			"Results or a decode error, and migrateTypeReceipt then refuses the checkmark on a short write.",
	},
	// ---- paper working copy ----------------------------------------------
	{
		File: "internal/cli/paper_wc_cmd.go", Func: "runPaperPush", Sites: 1,
		Endpoint: "POST /v1/plugins/bulldocs/papers/:slug/sync (PaperSync)", Class: machineRendered,
		Disposition: dispCannotLie,
		Why: "PaperSync unmarshals the 200 and then refuses on `!result.OK` — `server answered 200 without ok:true` — " +
			"so every poison body (empty, null, {}, {\"result\":null}, HTML, ok:false error envelope) is already a " +
			"non-zero exit before any receipt renders.",
	},
	{
		File: "internal/cli/paper_wc_cmd.go", Func: "runPaperPushCheck", Sites: 1,
		Endpoint: "POST /v1/plugins/bulldocs/papers/validate (dry-run)", Class: machineRendered,
		Disposition: dispCannotLie,
		Why: "the verdict is `valid:true`, a field only the server can set: an unparsable body is an explicit " +
			"`unparsable validate reply` refusal, and every readable poison leaves valid=false → exitGeneric.",
	},
	// ---- seed ------------------------------------------------------------
	{
		File: "internal/cli/seed_cmd.go", Func: "runSeed", Sites: 2,
		Endpoint: "POST /v1/data/mutate/:dataset (batch, then --publish batch)", Class: machineRendered,
		Disposition: dispScreened,
		Why: "the LOUDEST hole in the population: both counts in the receipt are LOCAL (len(docs), and ids read off " +
			"the documents we sent), so `{\"ok\":true,\"count\":3,\"ids\":[…],\"published\":true}` printed at rc=0 " +
			"over an empty 200, a proxy page or an error envelope on a 2xx. Nothing in it was ever a measurement.",
	},
	// ---- task create -----------------------------------------------------
	{
		File: "internal/cli/tasks_create_cmd.go", Func: "sendTaskMutations", Sites: 1,
		Endpoint: "POST /v1/data/mutate/:dataset (create, then publish)", Class: machineRendered,
		Disposition: dispCannotLie,
		Why: "the caller renders nothing without firstMutationRecord, which REQUIRES a server-generated id out of " +
			"`results[0].id` — `task create: server returned no id` — and the publish arm repeats it on its own " +
			"response (`the publish response carried no result`).",
	},
	// ---- task next -------------------------------------------------------
	{
		File: "internal/cli/tasks_next_cmd.go", Func: "runTaskNextFrontier", Sites: 1,
		Endpoint: "POST /v1/tasks/:id/claim (TaskClaimResources)", Class: machineRendered,
		Disposition: dispCannotLie,
		Why: "the filing named this one FIRST, and it is already safe: TaskClaimResources emits a claim only on " +
			"ok:true AND doc.claim.epoch>0, so the frontier receipt cannot print an epoch the server did not send.",
	},
	// ---- tinker REPL -----------------------------------------------------
	{
		File: "internal/cli/tinker_cmd.go", Func: "runTinker", Sites: 1,
		Endpoint: "POST /v1/data/mutate/:dataset (REPL `mutate`)", Class: humanOnly,
		Disposition: dispScreened,
		Why: "tinkerRequest ends in out.renderRaw(respBody) — an empty 200 printed NOTHING and returned to the " +
			"prompt, which in a REPL reads as `it worked`.",
	},
	// ---- vercel deploy flow ----------------------------------------------
	{
		File: "internal/cli/vercel_cmd.go", Func: "vercelEnsureWorkspace", Sites: 1,
		Endpoint: "POST <base>/api/workspaces", Class: humanOnly,
		Disposition: dispScreened,
		Why:         "`✓ workspace '%s' created` is printed off the 2xx status alone; the body is read only on failure.",
	},
	{
		File: "internal/cli/vercel_cmd.go", Func: "vercelApplySchema", Sites: 1,
		Endpoint: "POST /v1/schemas/:dataset", Class: humanOnly,
		Disposition: dispScreened,
		Why:         "`✓ schema applied` is printed off the 2xx status alone.",
	},
	{
		File: "internal/cli/vercel_cmd.go", Func: "vercelSeed", Sites: 2,
		Endpoint: "POST /v1/data/mutate/:dataset (seed, then publish)", Class: humanOnly,
		Disposition: dispScreened,
		Why: "`✓ seeded` and `✓ published %d document(s)` are both printed off the 2xx status; the published count " +
			"is len(ids) read out of the LOCAL seed file, never out of the response.",
	},
	{
		File: "internal/cli/vercel_cmd.go", Func: "vercelMintReadToken", Sites: 1,
		Endpoint: "POST /v1/tokens", Class: humanOnly,
		Disposition: dispCannotLie,
		Why: "the function's whole product is the server's `token` string: an unparsable body is a `parse mint " +
			"response` error and an empty token is `mint token: server returned no token`.",
	},
	{
		File: "internal/cli/vercel_cmd.go", Func: "vercelDisableProtection", Sites: 1,
		Endpoint: "PATCH https://api.vercel.com/v9/projects/:id", Class: humanOnly,
		Disposition: dispOutOfFence,
		Why:         "Vercel's own API, not Barkpark — a Barkpark receipt verdict has nothing to say about its bodies.",
	},
}
