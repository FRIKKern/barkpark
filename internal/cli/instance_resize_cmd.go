package cli

// instance_resize_cmd.go is `bp instance resize`: change the size of the VM
// that `bp instance up --path vm` made, for example from a larger size for an
// import to a smaller one for daily use.
//
//	bp instance resize --size <vm size> [--state <file>] --yes
//
// It reads the resource group, the VM name and the host from up's state file,
// runs az vm resize, which restarts the VM, waits until /readyz answers 200
// and records the new size in the state file. deploy.sh enables every service
// at boot, so nothing has to be started by hand.

import (
	"context"
	"fmt"
	"strings"
)

func runInstanceResize(out *writer, g globals, args []string) int {
	const usage = "bp instance resize --size <vm size> [--state <file>] --yes"
	a, err := parseHzArgs(args, []string{"size", "state"}, []string{"yes"}, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 0 {
		return useError(out, "usage", "unexpected argument "+a.pos[0]+" (usage: "+usage+")", exitUsage)
	}
	size := strings.TrimSpace(a.val("size"))
	if size == "" || !instanceUpAzureName.MatchString(size) {
		return useError(out, "usage", "--size is required: an Azure VM size such as Standard_D2s_v7 (usage: "+usage+")", exitUsage)
	}
	statePath := strings.TrimSpace(a.val("state"))
	if statePath == "" {
		statePath = instanceUpStateFile
	}
	st, err := loadInstanceUpState(statePath)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if st == nil {
		return useError(out, "usage", statePath+" is missing. Run bp instance resize in the directory where bp instance up ran, or pass --state <file>", exitUsage)
	}
	if st.Path != instanceTargetVM || st.Done["vm"] == "" {
		return useError(out, "usage", statePath+" has no VM from bp instance up --path vm", exitUsage)
	}
	if !g.yes && !a.bools["yes"] {
		return useError(out, "usage", fmt.Sprintf("resizing restarts the VM %s, and Barkpark is down for about a minute. Add --yes to go on", st.vmName()), exitUsage)
	}
	u := &instanceUp{ctx: context.Background(), out: out, g: g, st: st, statePath: statePath}
	var acct struct {
		ID string `json:"id"`
	}
	if err := u.az(&acct, "account", "show"); err != nil {
		return useError(out, "failed", "az is not signed in. Run az login.\n"+err.Error(), exitGeneric)
	}
	if st.Subscription != "" && acct.ID != st.Subscription {
		return useError(out, "failed", fmt.Sprintf("az uses subscription %s, but the VM is in %s. Run az account set --subscription %s", acct.ID, st.Subscription, st.Subscription), exitGeneric)
	}
	from := st.Size
	out.errf("resizing %s in %s from %s to %s; the VM restarts", st.vmName(), st.ResourceGroup, from, size)
	if err := u.az(nil, "vm", "resize", "-g", st.ResourceGroup, "-n", st.vmName(), "--size", size, "--query", "hardwareProfile.vmSize"); err != nil {
		hint := ""
		if strings.Contains(cmdOutput(err), "not available") || strings.Contains(cmdOutput(err), "AllocationFailed") {
			hint = fmt.Sprintf("\naz vm list-vm-resize-options -g %s -n %s -o table lists the sizes this VM can take without a deallocation.", st.ResourceGroup, st.vmName())
		}
		return useError(out, "failed", err.Error()+hint, exitGeneric)
	}
	st.Size = size
	if err := u.save(); err != nil {
		return useError(out, "failed", err.Error(), exitGeneric)
	}
	if st.host() != "" {
		if err := stepUpReady(u); err != nil {
			return useError(out, "failed", err.Error(), exitGeneric)
		}
	}
	if u.out.emitStructured(map[string]any{"ok": true, "action": "resize", "vm": st.vmName(), "resource_group": st.ResourceGroup,
		"from": from, "size": size, "host": st.host()}) {
		return exitOK
	}
	out.outf("%s is now %s and https://%s/readyz answers 200.", st.vmName(), size, st.host())
	return exitOK
}
