package setup

import (
	"crypto/rand"
	"encoding/base64"
	"fmt"
)

// GenerateAdminToken mints the admin bearer token a clean-profile seed
// installs: bp_admin_<base64url of 24 random bytes> (32 URL-safe chars after
// the prefix). The executor generates it at execute time — never at plan time,
// so a dry run shows only a redacted placeholder — threads it into the seed as
// BARKPARK_SEED_ADMIN_TOKEN, then chains it into the connect step so it lands
// in config.json (0600) and the capabilities probe verifies tier=admin live.
func GenerateAdminToken() (string, error) {
	b := make([]byte, 24)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("generate admin token: %w", err)
	}
	return "bp_admin_" + base64.RawURLEncoding.EncodeToString(b), nil
}
