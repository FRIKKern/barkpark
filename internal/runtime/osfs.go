package runtime

import "os"

// OSFS is the real-disk implementation of FS.
type OSFS struct{}

// WriteFile writes data to path with the given permission bits, atomically
// (write to a tempfile + rename so a crash mid-write doesn't leave a partial
// Caddyfile that the running Caddy can't reload from).
func (OSFS) WriteFile(path string, data []byte, perm uint32) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, os.FileMode(perm)); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// ReadFile reads the file at path.
func (OSFS) ReadFile(path string) ([]byte, error) {
	return os.ReadFile(path)
}
