package cloudclient

// ProvisionConsoleLine is one entry of `Barkpark.ProvisionConsole`: the latest
// provision job's console, the lines the worker narrated (barkpark_json/6
// `provision_console`, always present, [] with no job). `bp cloud status` reads
// ONE line from it, the warm-or-cold line a Hetzner launch writes
// (internal/cli/cloud/launch_host_line.go). It does not render the console; the
// /new page does that. Only the line text is decoded; the entry's `at` and
// truncation markers have no reader here.
type ProvisionConsoleLine struct {
	Line string `json:"line"`
}
