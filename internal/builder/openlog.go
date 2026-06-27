package builder

import (
	"io"
	"os"
	"path/filepath"
)

// openLog opens path for the build log, creating the parent dir if missing.
// Returns an io.WriteCloser writing append+truncate (one build, one log file).
// Split out so tests can stub it.
var openLog = func(path string) (io.WriteCloser, error) {
	if dir := filepath.Dir(path); dir != "" && dir != "." {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return nil, err
		}
	}
	return os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
}
