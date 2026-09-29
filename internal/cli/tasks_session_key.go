package cli

import (
	"crypto/rand"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

// THE SESSION KEY (task-f79e39f4992749a5).
//
// A worker id is LANE-scoped: every session of the cli lane claims, pulses and
// closes as `lead-cli`, so a predecessor that wakes on an inbox message writes
// a ledger byte-indistinguishable from the live lead's. The server-side half of
// the remedy is `Barkpark.Tasks.SessionId`: it HMACs a caller-presented SECRET
// key and stores the one-way result on `claim.session`. This is the client half
// — where that key comes from.
//
// WHY THE DEFAULT IS ENTROPY AND NOT A LABEL. The obvious client-side answer is
// a per-session NAME (`lead-cli-10`), and it is the one that fails: two sessions
// that pick the same label collide silently, a label is trivially copied from a
// template or a held file, and a generation label in a now-line is exactly the
// evidence that proved unreliable. So the default key is 32 hex characters of
// crypto/rand, minted ONCE into a 0600 file and reused for the life of that
// file. Two sessions that each mint get different keys without coordinating,
// and neither can guess the other's. A caller that genuinely wants to pin a key
// (a supervisor handing the same identity to a restarted process) sets
// BARKPARK_SESSION_KEY explicitly.
//
// The key never leaves the client except as the `X-Barkpark-Session` request
// header, and the server never stores it — only its HMAC. Reading a peer's
// `claim.session` off the ledger and presenting it as a key derives a
// DIFFERENT id, so the stored value cannot be replayed into an impersonation.

const sessionHeader = "X-Barkpark-Session"

var (
	sessionKeyOnce  sync.Once
	sessionKeyValue string
)

// sessionKey resolves this process's session key, minting one on first use.
//
// Resolution order, first hit wins:
//
//	BARKPARK_SESSION_KEY       — an explicit key; used verbatim.
//	BARKPARK_SESSION_KEY_FILE  — a path to mint into / read back from.
//	$XDG_CONFIG_HOME|~/.config/barkpark/session.key
//
// Returns "" only when no key could be resolved AND none could be minted (no
// writable config dir). A sessionless caller is fully supported server-side:
// the row simply carries no `claim.session`, exactly as before this shipped.
func sessionKey() string {
	sessionKeyOnce.Do(func() { sessionKeyValue = resolveSessionKey() })
	return sessionKeyValue
}

func resolveSessionKey() string {
	if v := strings.TrimSpace(os.Getenv("BARKPARK_SESSION_KEY")); v != "" {
		return v
	}
	path := strings.TrimSpace(os.Getenv("BARKPARK_SESSION_KEY_FILE"))
	if path == "" {
		dir := strings.TrimSpace(os.Getenv("XDG_CONFIG_HOME"))
		if dir == "" {
			home, err := os.UserHomeDir()
			if err != nil {
				return ""
			}
			dir = filepath.Join(home, ".config")
		}
		path = filepath.Join(dir, "barkpark", "session.key")
	}
	return sessionKeyFromFile(path)
}

// sessionKeyFromFile reads the key at path, minting a fresh random one when the
// file is absent or blank. Split out from resolveSessionKey so a test can drive
// the mint-then-reuse property against a temp path without touching $HOME.
func sessionKeyFromFile(path string) string {
	if b, err := os.ReadFile(path); err == nil {
		if v := strings.TrimSpace(string(b)); v != "" {
			return v
		}
	}
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		return ""
	}
	key := hex.EncodeToString(buf)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		// No durable home for the key: still return it, so THIS process is
		// attributable even though the next one will mint a different id.
		return key
	}
	// 0600: the key is a credential — whoever holds it can write under this
	// session's identity, which is precisely why the ledger stores the HMAC
	// and not this.
	if err := os.WriteFile(path, []byte(key+"\n"), 0o600); err != nil {
		return key
	}
	return key
}
