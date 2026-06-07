package setup

import (
	"fmt"
	"strings"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// verifyServer confirms a freshly-deployed/provisioned server is answering: a
// 2xx on GET /v1/capabilities (the API is up and identifies as barkpark) AND a
// non-5xx on GET /studio (the LiveView surface renders). It is the post-install
// gate before CONNECT points bp at the box. It reuses the apiclient HTTP path so
// the timeout/auth handling matches the rest of the CLI.
func verifyServer(baseURL, token string) error {
	baseURL = strings.TrimRight(baseURL, "/")
	client := apiclient.New(apiclient.Config{BaseURL: baseURL, Token: token})

	cap, err := client.GetConditional(baseURL+"/v1/capabilities", "")
	if err != nil {
		return fmt.Errorf("GET %s/v1/capabilities: %w", baseURL, err)
	}
	if cap.StatusCode < 200 || cap.StatusCode >= 300 {
		return fmt.Errorf("GET /v1/capabilities returned status %d", cap.StatusCode)
	}

	studio, err := client.GetConditional(baseURL+"/studio", "")
	if err != nil {
		return fmt.Errorf("GET %s/studio: %w", baseURL, err)
	}
	// /studio may redirect (3xx) to a scoped path; treat anything below 500 as
	// "the LiveView surface is reachable". A 5xx is a real failure.
	if studio.StatusCode >= 500 {
		return fmt.Errorf("GET /studio returned status %d", studio.StatusCode)
	}
	return nil
}
