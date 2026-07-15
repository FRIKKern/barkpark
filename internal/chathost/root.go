package chathost

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
)

var ErrRootDenied = errors.New("path is outside approved roots")

// ResolveApprovedPath returns a real path only when both the approved root and
// target resolve inside the same root. Resolving symlinks before the containment
// check prevents an apparently-safe child from escaping through a link.
func ResolveApprovedPath(approvedRoots []string, target string) (string, error) {
	resolvedTarget, err := filepath.EvalSymlinks(target)
	if err != nil {
		return "", err
	}
	resolvedTarget, err = filepath.Abs(resolvedTarget)
	if err != nil {
		return "", err
	}

	for _, root := range approvedRoots {
		resolvedRoot, err := filepath.EvalSymlinks(root)
		if err != nil {
			if errors.Is(err, os.ErrNotExist) {
				continue
			}
			return "", err
		}
		resolvedRoot, err = filepath.Abs(resolvedRoot)
		if err != nil {
			return "", err
		}

		rel, err := filepath.Rel(resolvedRoot, resolvedTarget)
		if err == nil && rel != ".." && !filepath.IsAbs(rel) && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
			return resolvedTarget, nil
		}
	}

	return "", ErrRootDenied
}
