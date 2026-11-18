package cli

// instance_backup_fetch_cmd.go is `bp instance backup fetch`: copy a backup
// that `bp instance backup` wrote on a VM to this machine and check it.
//
//	bp instance backup fetch --to <dir> [--name <backup>] [--state <file> |
//	                         --ssh-host <user@host> [--ssh-key <path>]]
//	                         [--remote-dir <dir>]
//
// It reaches the VM over ssh as `bp instance up` does, with the key and host
// from up's state file, or with --ssh-host. It lists the backups under
// --remote-dir, /var/backups/barkpark by default, that have a manifest.json,
// takes the newest name or --name, and streams that directory with sudo tar
// over ssh into a hidden directory under --to. Only db.dump, media.tar.gz and
// manifest.json are accepted. The sha256 of db.dump and media.tar.gz must
// match the manifest. Then the directory is renamed to <to>/<name>;
// otherwise it is removed and the command fails. A backup already fetched
// and checked is not fetched again. The backup holds no key, so a copy on
// the operator's machine holds none either.

import (
	"archive/tar"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"
)

const instanceBackupRemoteDir = "/var/backups/barkpark"

// The bp instance help for fetch, which printInstanceHelp joins into its text.
const instanceBackupFetchUsageHelp = `  bp instance backup fetch --to <dir> [--name <backup>] [--state <f> |
                      --ssh-host <user@host> [--ssh-key <path>]]
`

const instanceBackupFetchWhatHelp = `               fetch copies the newest backup, or --name, from the VM's
               /var/backups/barkpark (--remote-dir) to <dir>/<name> over ssh,
               with the host and key from bp instance up's state file or
               --ssh-host, and keeps it only when the sha256 of db.dump and
               media.tar.gz match the manifest.
`

var (
	instanceBackupName      = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)
	instanceBackupRemotePth = regexp.MustCompile(`^/[A-Za-z0-9._/-]+$`)
)

// instanceBackupStream runs a command and copies its stdout to w as it runs.
// Tests replace it.
var instanceBackupStream = func(ctx context.Context, name string, args []string, w io.Writer) error {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Stdout = w
	var stderr strings.Builder
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("%s: %v\n%s", name, err, strings.TrimSpace(stderr.String()))
	}
	return nil
}

func runInstanceBackupFetch(out *writer, args []string) int {
	const usage = "bp instance backup fetch --to <dir> [--name <backup>] [--state <file> | --ssh-host <user@host> [--ssh-key <path>]] [--remote-dir <dir>]"
	a, err := parseHzArgs(args, []string{"to", "name", "state", "ssh-host", "ssh-key", "remote-dir"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	to := strings.TrimSpace(a.val("to"))
	if to == "" || len(a.pos) != 0 {
		return useError(out, "usage", "--to <dir> is required (usage: "+usage+")", exitUsage)
	}
	want := strings.TrimSpace(a.val("name"))
	if want != "" && !instanceBackupName.MatchString(want) {
		return useError(out, "usage", "--name is "+want+"; give the name of a backup directory, such as 2026-11-18", exitUsage)
	}
	remote := strings.TrimSpace(a.val("remote-dir"))
	if remote == "" {
		remote = instanceBackupRemoteDir
	}
	if !instanceBackupRemotePth.MatchString(remote) || strings.Contains(remote, "..") {
		return useError(out, "usage", "--remote-dir must be an absolute path of letters, digits, dots, dashes and slashes", exitUsage)
	}
	sshArgs, target, err := instanceBackupSSH(a)
	if err != nil {
		return useError(out, "usage", err.Error()+" (usage: "+usage+")", exitUsage)
	}
	ctx := context.Background()
	ssh := func(remoteCmd string) (string, error) {
		return instanceUpRun(ctx, out.stderr, instanceUpCmd{name: "ssh", args: append(append([]string{}, sshArgs...), target, remoteCmd)})
	}

	list, err := ssh("sudo find " + remote + " -mindepth 2 -maxdepth 2 -name manifest.json -printf '%h\\n'")
	if err != nil {
		return useError(out, "failed", "list the backups on the VM: "+err.Error(), exitGeneric)
	}
	var names []string
	for _, line := range strings.Split(list, "\n") {
		if n := filepath.Base(strings.TrimSpace(line)); strings.TrimSpace(line) != "" && instanceBackupName.MatchString(n) {
			names = append(names, n)
		}
	}
	sort.Strings(names)
	if len(names) == 0 {
		return useError(out, "failed", "no backup with a manifest.json under "+remote+" on the VM. Run sudo bp instance backup --out "+remote+"/$(date +%F) there first", exitGeneric)
	}
	name := names[len(names)-1]
	if want != "" {
		if !slices.Contains(names, want) {
			return useError(out, "failed", fmt.Sprintf("%s/%s on the VM has no manifest.json. The VM has: %s", remote, want, strings.Join(names, ", ")), exitGeneric)
		}
		name = want
	}

	final := filepath.Join(to, name)
	if man, err := checkFetchedBackup(final); err == nil {
		return fetchDone(out, final, name, man, true)
	} else if !errors.Is(err, os.ErrNotExist) {
		return useError(out, "failed", fmt.Sprintf("%s exists but does not check out (%v). Move it away and run again", final, err), exitGeneric)
	}
	if err := os.MkdirAll(to, 0o700); err != nil {
		return useError(out, "failed", err.Error(), exitGeneric)
	}
	partial, err := os.MkdirTemp(to, "."+name+".partial-")
	if err != nil {
		return useError(out, "failed", err.Error(), exitGeneric)
	}
	keep := false
	defer func() {
		if !keep {
			os.RemoveAll(partial)
		}
	}()
	out.errf("fetching %s/%s from %s", remote, name, target)
	pr, pw := io.Pipe()
	done := make(chan error, 1)
	go func() { done <- untarBackup(pr, name, partial) }()
	streamErr := instanceBackupStream(ctx, "ssh", append(append([]string{}, sshArgs...), target, "sudo tar -C "+remote+" -cf - "+name), pw)
	pw.CloseWithError(streamErr)
	if err := <-done; err != nil || streamErr != nil {
		if streamErr != nil {
			err = streamErr
		}
		return useError(out, "failed", "copy "+name+" from the VM: "+err.Error(), exitGeneric)
	}
	man, err := checkFetchedBackup(partial)
	if err != nil {
		return useError(out, "failed", fmt.Sprintf("the copy of %s does not match its manifest, so it was removed: %v", name, err), exitGeneric)
	}
	if err := os.Rename(partial, final); err != nil {
		return useError(out, "failed", err.Error(), exitGeneric)
	}
	keep = true
	return fetchDone(out, final, name, man, false)
}

// instanceBackupSSH returns the ssh options and the user@host to reach: from
// --ssh-host, or from bp instance up's state file.
func instanceBackupSSH(a *hzArgs) ([]string, string, error) {
	base := []string{"-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=30"}
	if h := strings.TrimSpace(a.val("ssh-host")); h != "" {
		if strings.HasPrefix(h, "-") || strings.ContainsAny(h, " \t;|&$`'\"") {
			return nil, "", fmt.Errorf("--ssh-host is %q; give user@host", h)
		}
		if k := strings.TrimSpace(a.val("ssh-key")); k != "" {
			base = append([]string{"-i", k}, base...)
		}
		return base, h, nil
	}
	statePath := strings.TrimSpace(a.val("state"))
	if statePath == "" {
		statePath = instanceUpStateFile
	}
	st, err := loadInstanceUpState(statePath)
	if err != nil {
		return nil, "", err
	}
	if st == nil || st.Path != instanceTargetVM || st.Out.IP == "" {
		return nil, "", fmt.Errorf("%s has no VM from bp instance up. Run in the directory where up ran, pass --state <file>, or pass --ssh-host <user@host>", statePath)
	}
	key := st.SSHKey
	if k := strings.TrimSpace(a.val("ssh-key")); k != "" {
		key = k
	}
	args := append([]string{"-i", key}, base...)
	args = append(args, "-o", "UserKnownHostsFile="+statePath+".known_hosts")
	return args, instanceUpVMUser + "@" + st.Out.IP, nil
}

// untarBackup writes the members of one backup directory from a tar stream
// into dir. It accepts only the three member files of a backup, as regular
// files, and refuses any other entry.
func untarBackup(r io.Reader, name, dir string) error {
	tr := tar.NewReader(r)
	allowed := map[string]bool{instanceBackupDB: true, instanceBackupMedia: true, instanceBackupManifest: true}
	got := 0
	for {
		h, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			io.Copy(io.Discard, r)
			return err
		}
		p := strings.TrimSuffix(strings.TrimPrefix(h.Name, "./"), "/")
		if p == name && h.Typeflag == tar.TypeDir {
			continue
		}
		member, ok := strings.CutPrefix(p, name+"/")
		if !ok || !allowed[member] || h.Typeflag != tar.TypeReg {
			io.Copy(io.Discard, r)
			return fmt.Errorf("the backup holds %q, which is not a backup member", h.Name)
		}
		f, err := os.OpenFile(filepath.Join(dir, member), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
		if err != nil {
			io.Copy(io.Discard, r)
			return err
		}
		_, cerr := io.Copy(f, tr)
		if err := f.Close(); cerr == nil {
			cerr = err
		}
		if cerr != nil {
			io.Copy(io.Discard, r)
			return cerr
		}
		got++
	}
	if got != len(allowed) {
		return fmt.Errorf("the backup has %d of its 3 files", got)
	}
	return nil
}

// checkFetchedBackup reads dir's manifest and checks both member files
// against it. A missing directory gives an error that wraps os.ErrNotExist.
func checkFetchedBackup(dir string) (instanceBackupManifestV1, error) {
	var man instanceBackupManifestV1
	raw, err := os.ReadFile(filepath.Join(dir, instanceBackupManifest))
	if err != nil {
		return man, err
	}
	if err := json.Unmarshal(raw, &man); err != nil || man.Format != instanceBackupFormat {
		return man, fmt.Errorf("%s is not a %s manifest", instanceBackupManifest, instanceBackupFormat)
	}
	for _, want := range []instanceBackupFile{man.DB, man.MediaArchive} {
		got, err := hashFile(dir, want.Path)
		if err != nil {
			return man, fmt.Errorf("%s: %v", want.Path, err)
		}
		if got != want {
			return man, fmt.Errorf("%s has %d bytes sha256 %s, the manifest says %d bytes sha256 %s", want.Path, got.Bytes, got.SHA256, want.Bytes, want.SHA256)
		}
	}
	return man, nil
}

func fetchDone(out *writer, dir, name string, man instanceBackupManifestV1, already bool) int {
	bytes := man.DB.Bytes + man.MediaArchive.Bytes
	if out.emitStructured(map[string]any{"ok": true, "action": "backup-fetch", "name": name, "dir": dir, "bytes": bytes,
		"already": already, "created_at": man.CreatedAt}) {
		return exitOK
	}
	if already {
		out.outf("%s is already here and matches its manifest: %s", name, dir)
		return exitOK
	}
	out.outf("fetched %s, %d bytes, sha256 of db.dump and media.tar.gz match the manifest: %s", name, bytes, dir)
	return exitOK
}
