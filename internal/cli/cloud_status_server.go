package cli

import (
	"github.com/FRIKKern/barkpark/internal/cli/cloud"
	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

// serverMarker says, on a row that is provisioning or failed, whether its launch
// took a warm server or is creating a new one, and why. The provisioner writes
// that line to the job's console (internal/provisioner/launch_host.go) and
// cloud.LastLaunchHost reads it with the same wording. A row whose console has
// no such line (an Azure launch, an adopted box, a job from before the line
// existed) gets "".
//
//	server: warm (warm-52d0bbcf)
//	server: new — warm pool is off on the worker (WARM_POOL_SIZE=0)
func serverMarker(b cloudclient.Barkpark, status string) string {
	if status != "provisioning" && status != "failed" {
		return ""
	}
	lines := make([]string, len(b.ProvisionConsole))
	for i, l := range b.ProvisionConsole {
		lines[i] = l.Line
	}
	h, ok := cloud.LastLaunchHost(lines)
	if !ok {
		return ""
	}
	if h.Warm {
		return "server: warm (" + h.Name + ")"
	}
	return "server: new — " + h.Why
}
