package waker

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"os/exec"
	"strings"
	"time"
)

// DefaultHealthTimeout is the cold-wake wall-clock budget for the backing
// container's first non-5xx response on /. Matches runtime.DefaultHealthTimeout
// so a hot-deploy and a cold-wake look the same to the caller.
const DefaultHealthTimeout = 30 * time.Second

// DefaultContainerInnerPort is the port inside the container (matches
// runtime.containerInnerPort — Next/SSG sites are configured via the PORT env
// to bind here).
const DefaultContainerInnerPort = 3000

// CommandRunner mirrors runtime.CommandRunner — kept package-local so the
// waker can be tested without importing runtime in its tests.
type CommandRunner interface {
	Run(ctx context.Context, w io.Writer, name string, args ...string) error
}

// ExecRunner is the default real-shell-out CommandRunner.
type ExecRunner struct{}

// Run executes name+args, streaming combined stdout+stderr to w.
func (ExecRunner) Run(ctx context.Context, w io.Writer, name string, args ...string) error {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Stdout = w
	cmd.Stderr = w
	return cmd.Run()
}

// DockerContainer is the production ContainerManager: it shells to the
// docker CLI to bring up / take down a named container that backs one Site.
//
// First call to EnsureUp creates the container (`docker run -d`); subsequent
// calls after a Stop reuse the same name (`docker start`). Health check
// hammers http://127.0.0.1:InternalPort/ until any non-5xx response or the
// timeout — same semantics as the runtime executor's deploy health check.
type DockerContainer struct {
	// Name is the docker container name. Stable across restarts so
	// `docker start` works on the second wake; the runtime executor picks
	// the name when the waker is deployed (e.g. "site-shop-waker").
	Name string

	// Image is the docker image tag the container runs (e.g.
	// "site-shop-d-12345678" — the image the runtime executor docker-loaded
	// from the builder cache).
	Image string

	// InternalPort is the host-side loopback port the container binds. The
	// waker's reverse-proxy points here; the health check polls here.
	InternalPort int

	// ContainerInnerPort is the port inside the container. Defaults to
	// DefaultContainerInnerPort (3000) when zero.
	ContainerInnerPort int

	// Memory / CPUs are docker cgroup caps, matching the runtime executor's
	// always-on container. Empty → docker defaults.
	Memory string
	CPUs   string

	// HealthTimeout overrides DefaultHealthTimeout when set.
	HealthTimeout time.Duration

	// Runner is the subprocess driver. Tests inject a fake; production uses
	// ExecRunner.
	Runner CommandRunner

	// HealthClient is the http.Client used to probe the container's port.
	// Tests can override to point at httptest. Defaults to a 3s-timeout
	// client.
	HealthClient *http.Client
}

// EnsureUp brings the backing container into a running, health-checked state.
// Idempotent on the docker-side work: a single `docker inspect` call decides
// whether to `docker start` / `docker run` / do nothing, but every path —
// including an already-running container — converges on healthCheck before
// returning. A container that is up but wedged (process alive, HTTP dead)
// must never be reported healthy just because it was already running.
func (d *DockerContainer) EnsureUp(ctx context.Context) error {
	state, err := d.inspectState(ctx)
	if err != nil {
		return fmt.Errorf("inspect: %w", err)
	}
	switch state {
	case stateStopped:
		if err := d.runner().Run(ctx, devNull{}, "docker", "start", d.Name); err != nil {
			return fmt.Errorf("docker start %s: %w", d.Name, err)
		}
	case stateMissing:
		if err := d.dockerRun(ctx); err != nil {
			return fmt.Errorf("docker run %s: %w", d.Name, err)
		}
	}
	return d.healthCheck(ctx)
}

// Stop best-effort halts the container with a 5s SIGTERM grace.
func (d *DockerContainer) Stop(ctx context.Context) error {
	return d.runner().Run(ctx, devNull{}, "docker", "stop", "-t", "5", d.Name)
}

// dockerRun is the first-time `docker run -d` invocation. Arg shape mirrors
// the runtime executor's container start so always-on and zero-scale sites
// look the same once warm.
func (d *DockerContainer) dockerRun(ctx context.Context) error {
	innerPort := d.ContainerInnerPort
	if innerPort == 0 {
		innerPort = DefaultContainerInnerPort
	}
	args := []string{
		"run", "-d",
		"--name", d.Name,
		"-e", "HOSTNAME=0.0.0.0",
		"-e", fmt.Sprintf("PORT=%d", innerPort),
		"-p", fmt.Sprintf("127.0.0.1:%d:%d", d.InternalPort, innerPort),
	}
	if d.Memory != "" {
		args = append(args, "--memory="+d.Memory)
	}
	if d.CPUs != "" {
		args = append(args, "--cpus="+d.CPUs)
	}
	args = append(args, d.Image)
	return d.runner().Run(ctx, devNull{}, "docker", args...)
}

// inspectState distinguishes "running" / "stopped" / "missing" via a single
// `docker inspect -f {{.State.Running}}`. Missing = non-zero exit code.
func (d *DockerContainer) inspectState(ctx context.Context) (containerState, error) {
	var buf bytes.Buffer
	err := d.runner().Run(ctx, &buf, "docker", "inspect", "-f", "{{.State.Running}}", d.Name)
	if err != nil {
		// docker inspect returns non-zero when the container doesn't exist.
		// We can't reliably distinguish "missing" from "docker daemon down"
		// at this layer, but a daemon outage would have failed the earlier
		// runtime executor too — treat any inspect failure as "missing,
		// re-run".
		return stateMissing, nil
	}
	switch strings.TrimSpace(buf.String()) {
	case "true":
		return stateRunning, nil
	case "false":
		return stateStopped, nil
	default:
		return stateMissing, nil
	}
}

// healthCheck polls http://127.0.0.1:InternalPort/ until any non-5xx response
// or the timeout elapses. Mirrors runtime.healthCheck.
func (d *DockerContainer) healthCheck(ctx context.Context) error {
	deadline := time.Now().Add(d.healthTimeout())
	url := fmt.Sprintf("http://127.0.0.1:%d/", d.InternalPort)
	client := d.HealthClient
	if client == nil {
		client = &http.Client{Timeout: 3 * time.Second}
	}
	for {
		if time.Now().After(deadline) {
			return fmt.Errorf("container %s did not become healthy in %s", d.Name, d.healthTimeout())
		}
		req, _ := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		resp, err := client.Do(req)
		if err == nil {
			_ = resp.Body.Close()
			if resp.StatusCode < 500 {
				return nil
			}
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(500 * time.Millisecond):
		}
	}
}

func (d *DockerContainer) runner() CommandRunner {
	if d.Runner != nil {
		return d.Runner
	}
	return ExecRunner{}
}

func (d *DockerContainer) healthTimeout() time.Duration {
	if d.HealthTimeout > 0 {
		return d.HealthTimeout
	}
	return DefaultHealthTimeout
}

type containerState int

const (
	stateMissing containerState = iota
	stateStopped
	stateRunning
)

type devNull struct{}

func (devNull) Write(p []byte) (int, error) { return len(p), nil }
