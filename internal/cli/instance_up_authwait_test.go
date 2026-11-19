package cli

import (
	"errors"
	"os"
	"strings"
	"testing"
	"time"
)

// instance_up_authwait_test.go covers how bp instance up waits out
// AuthorizationFailed while a new Azure role propagates. az is stubbed.

func authFailedErr(s string) error {
	return &instanceUpCmdError{cmd: s, err: errors.New("exit status 1"),
		stderr: "(AuthorizationFailed) The client 'op@example.com' with object id 'x' does not have authorization to perform action 'Microsoft.Resources/subscriptions/resourcegroups/write'."}
}

func stubSleeps(t *testing.T) *[]time.Duration {
	t.Helper()
	var slept []time.Duration
	instanceUpSleep = func(d time.Duration) { slept = append(slept, d) }
	return &slept
}

func TestInstanceUpRetriesAuthorizationFailed(t *testing.T) {
	f := stubInstanceUp(t)
	slept := stubSleeps(t)
	_ = os.MkdirAll("key", 0o700)
	refusals := 3
	f.reply = func(c instanceUpCmd) (string, error) {
		if strings.HasPrefix(c.String(), "az group create") && refusals > 0 {
			refusals--
			return "", authFailedErr(c.String())
		}
		return defaultUpReply(c)
	}
	_, stderr, code := runUp(t, vmArgs()...)
	if code != exitOK {
		t.Fatalf("exit %d: %s", code, stderr)
	}
	if n := f.has("az group create"); n != 4 {
		t.Errorf("group create ran %d times, want 4", n)
	}
	var authSleeps []time.Duration
	for _, d := range *slept {
		if d >= 15*time.Second && d <= 2*time.Minute && d%(15*time.Second) == 0 {
			authSleeps = append(authSleeps, d)
		}
	}
	if len(authSleeps) < 3 || authSleeps[0] != 15*time.Second || authSleeps[1] != 30*time.Second || authSleeps[2] != 60*time.Second {
		t.Errorf("waits = %v, want 15s, 30s, 60s first", *slept)
	}
	if !strings.Contains(stderr, "Azure answered AuthorizationFailed to az group create") ||
		!strings.Contains(stderr, "Trying again in 1m0s; waited 45s of at most 30m0s") {
		t.Errorf("stderr lacks the wait message:\n%s", stderr)
	}
}

func TestInstanceUpStopsAfterTheAuthorizationWait(t *testing.T) {
	f := stubInstanceUp(t)
	slept := stubSleeps(t)
	_ = os.MkdirAll("key", 0o700)
	f.reply = func(c instanceUpCmd) (string, error) {
		if strings.HasPrefix(c.String(), "az group create") {
			return "", authFailedErr(c.String())
		}
		return defaultUpReply(c)
	}
	_, stderr, code := runUp(t, vmArgs()...)
	if code == exitOK {
		t.Fatal("up went on although Azure kept refusing")
	}
	var total time.Duration
	for _, d := range *slept {
		total += d
	}
	if total > instanceUpAuthWait || total < instanceUpAuthWait-2*time.Minute {
		t.Errorf("waited %s in all, want close to and at most %s", total, instanceUpAuthWait)
	}
	for _, want := range []string{"Azure still answers AuthorizationFailed to az group create after", "az role assignment list", "Privileged Identity Management", "resumes at this step"} {
		if !strings.Contains(stderr, want) {
			t.Errorf("stderr lacks %q:\n%s", want, stderr)
		}
	}
	if f.has("az vm create") != 0 {
		t.Errorf("up went past the group step")
	}
}

func TestInstanceUpOtherErrorsAreNotRetried(t *testing.T) {
	f := stubInstanceUp(t)
	_ = os.MkdirAll("key", 0o700)
	f.reply = func(c instanceUpCmd) (string, error) {
		if strings.HasPrefix(c.String(), "az group create") {
			return "", &instanceUpCmdError{cmd: c.String(), err: errors.New("exit status 1"), stderr: "(InvalidResourceGroupLocation) wrong place"}
		}
		return defaultUpReply(c)
	}
	if _, _, code := runUp(t, vmArgs()...); code == exitOK {
		t.Fatal("up went on")
	}
	if n := f.has("az group create"); n != 1 {
		t.Errorf("group create ran %d times, want 1", n)
	}
}

func TestInstanceUpVMCreateRefusedReadFindsTheVM(t *testing.T) {
	f := stubInstanceUp(t)
	stubSleeps(t)
	_ = os.MkdirAll("key", 0o700)
	created := false
	f.reply = func(c instanceUpCmd) (string, error) {
		s := c.String()
		switch {
		case strings.HasPrefix(s, "az vm create"):
			created = true
			return "", &instanceUpCmdError{cmd: s, err: errors.New("exit status 1"),
				stderr: "(AuthorizationFailed) The client does not have authorization to perform action 'Microsoft.Network/networkInterfaces/read'."}
		case strings.HasPrefix(s, "az vm show") && created:
			return `{"publicIps":"20.9.9.9","fqdns":"pensum-cms.swedencentral.cloudapp.azure.com"}`, nil
		}
		return defaultUpReply(c)
	}
	_, stderr, code := runUp(t, vmArgs()...)
	if code != exitOK {
		t.Fatalf("exit %d: %s\n%s", code, stderr, f.dump())
	}
	if n := f.has("az vm create"); n != 1 {
		t.Errorf("vm create ran %d times, want 1", n)
	}
	if !strings.Contains(stderr, "but the VM barkpark exists") {
		t.Errorf("stderr:\n%s", stderr)
	}
	if st := readUpState(t); st.Out.IP != "20.9.9.9" {
		t.Errorf("state IP %q", st.Out.IP)
	}
}

func TestAzWhatNamesNoValues(t *testing.T) {
	for args, want := range map[string]string{
		"group create -n rg-secret -l x":          "az group create",
		"vm resize -g rg -n vm --size s":          "az vm resize",
		"network vnet subnet show --ids /x":       "az network vnet subnet",
		"ad app credential reset --id 1 --append": "az ad app credential",
	} {
		if got := azWhat(strings.Fields(args)); got != want {
			t.Errorf("azWhat(%s) = %q, want %q", args, got, want)
		}
	}
}
