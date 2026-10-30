package cli

// instance_up_image.go pins the published image on Container Apps. Without
// --image or --from-source, up deploys the release that
// ghcr.io/frikkern/barkpark:latest is at the time, as its version tag, so a
// later restart or redeploy runs the same release. deploy.sh does the same on
// a VM from the image's org.opencontainers.image.version label.

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strings"
	"time"
)

const instanceUpGHCRRepo = "frikkern/barkpark"

var instanceUpVersionTag = regexp.MustCompile(`^[0-9]+(\.[0-9]+)+$`)

// instanceUpFetch fetches a registry URL with the bearer token and Accept
// header and returns the body. Tests replace it.
var instanceUpFetch = func(ctx context.Context, url, token, accept string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	if accept != "" {
		req.Header.Set("Accept", accept)
	}
	resp, err := (&http.Client{Timeout: 20 * time.Second}).Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("GET %s: status %d", url, resp.StatusCode)
	}
	return body, nil
}

// instanceUpLatestVersion returns the release version that
// ghcr.io/frikkern/barkpark:latest carries in its version label.
func instanceUpLatestVersion(ctx context.Context) (string, error) {
	base := "https://ghcr.io/v2/" + instanceUpGHCRRepo
	b, err := instanceUpFetch(ctx, "https://ghcr.io/token?scope=repository:"+instanceUpGHCRRepo+":pull", "", "")
	if err != nil {
		return "", err
	}
	var tok struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(b, &tok); err != nil || tok.Token == "" {
		return "", fmt.Errorf("ghcr.io gave no pull token")
	}
	const index = "application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json"
	const manifest = "application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json"
	var m struct {
		Manifests []struct {
			Digest   string `json:"digest"`
			Platform struct {
				OS           string `json:"os"`
				Architecture string `json:"architecture"`
			} `json:"platform"`
		} `json:"manifests"`
		Config struct {
			Digest string `json:"digest"`
		} `json:"config"`
	}
	if b, err = instanceUpFetch(ctx, base+"/manifests/latest", tok.Token, index+", "+manifest); err != nil {
		return "", err
	}
	if err := json.Unmarshal(b, &m); err != nil {
		return "", fmt.Errorf("read the manifest of latest: %v", err)
	}
	for _, e := range m.Manifests {
		if e.Platform.OS == "linux" && e.Platform.Architecture == "amd64" {
			if b, err = instanceUpFetch(ctx, base+"/manifests/"+e.Digest, tok.Token, manifest); err != nil {
				return "", err
			}
			if err := json.Unmarshal(b, &m); err != nil {
				return "", fmt.Errorf("read the linux/amd64 manifest of latest: %v", err)
			}
			break
		}
	}
	if m.Config.Digest == "" {
		return "", fmt.Errorf("latest has no linux/amd64 image")
	}
	if b, err = instanceUpFetch(ctx, base+"/blobs/"+m.Config.Digest, tok.Token, ""); err != nil {
		return "", err
	}
	var cfg struct {
		Config struct {
			Labels map[string]string `json:"Labels"`
		} `json:"config"`
	}
	if err := json.Unmarshal(b, &cfg); err != nil {
		return "", fmt.Errorf("read the image config of latest: %v", err)
	}
	v := strings.TrimSpace(cfg.Config.Labels["org.opencontainers.image.version"])
	if !instanceUpVersionTag.MatchString(v) {
		return "", fmt.Errorf("latest has no release version label (%q)", v)
	}
	if _, err := instanceUpFetch(ctx, base+"/manifests/"+v, tok.Token, index+", "+manifest); err != nil {
		return "", fmt.Errorf("latest says version %s, but that tag does not resolve: %v", v, err)
	}
	return v, nil
}

// pinPublishedImage resolves latest to its version tag once and keeps it in
// the state file, so a resumed run deploys the same release.
func (u *instanceUp) pinPublishedImage() (string, error) {
	if u.st.Out.Image != "" {
		return u.st.Out.Image, nil
	}
	ctx, cancel := context.WithTimeout(u.ctx, time.Minute)
	defer cancel()
	v, err := instanceUpLatestVersion(ctx)
	if err != nil {
		return "", fmt.Errorf("find the release that %s is at: %v. Give --image ghcr.io/%s:<version>", instanceUpLatestImage, err, instanceUpGHCRRepo)
	}
	u.st.Out.Image = "ghcr.io/" + instanceUpGHCRRepo + ":" + v
	u.out.errf("        %s is release %s; deploying %s", instanceUpLatestImage, v, u.st.Out.Image)
	return u.st.Out.Image, nil
}
