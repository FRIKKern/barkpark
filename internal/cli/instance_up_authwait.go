package cli

// instance_up_authwait.go makes bp instance up wait out AuthorizationFailed.
// A role that was just assigned, or activated in Privileged Identity
// Management, reaches Azure Resource Manager's replicas one by one. On
// 2026-11-18, after a PIM activation of Contributor, az writes and reads
// answered AuthorizationFailed on and off for about 20 minutes: az group
// create, a resource list, and the read az vm create makes after its
// deployment. up therefore runs such a call again with growing waits, for at
// most instanceUpAuthWait in all, and then stops with what to check.

import (
	"fmt"
	"regexp"
	"strings"
	"time"
)

// instanceUpAuthWait bounds the total wait for one call. Tests replace it.
var instanceUpAuthWait = 30 * time.Minute

var instanceUpAuthFailed = regexp.MustCompile(`\b(Linked)?AuthorizationFailed\b`)

// authFailed reports whether an az error is Azure's AuthorizationFailed.
func authFailed(err error) bool {
	return err != nil && instanceUpAuthFailed.MatchString(cmdOutput(err))
}

// azWhat names an az call in a message by its first words, such as
// "az group create", and never by its values.
func azWhat(args []string) string {
	words := []string{"az"}
	for _, a := range args {
		if strings.HasPrefix(a, "-") || len(words) == 4 {
			break
		}
		words = append(words, a)
	}
	return strings.Join(words, " ")
}

// retryAuth runs f and runs it again while it fails with AuthorizationFailed,
// after 15 s, 30 s, 60 s and then every 2 minutes, until the waits add up to
// instanceUpAuthWait. Any other result returns at once.
func (u *instanceUp) retryAuth(what string, f func() error) error {
	var waited time.Duration
	delay := 15 * time.Second
	for {
		err := f()
		if !authFailed(err) {
			return err
		}
		if waited+delay > instanceUpAuthWait {
			return fmt.Errorf("Azure still answers AuthorizationFailed to %s after %s of retries. "+
				"Check that your role is active on this subscription or resource group with az role assignment list --assignee <your sign-in> --all -o table, "+
				"activate it again in Privileged Identity Management if it has ended, and run the same command again. It resumes at this step.\n%v",
				what, waited, err)
		}
		u.out.errf("        Azure answered AuthorizationFailed to %s. A role that was just assigned or activated in PIM can take about 30 minutes to reach every part of Azure. Trying again in %s; waited %s of at most %s.",
			what, delay, waited, instanceUpAuthWait)
		instanceUpSleep(delay)
		waited += delay
		if delay *= 2; delay > 2*time.Minute {
			delay = 2 * time.Minute
		}
	}
}
