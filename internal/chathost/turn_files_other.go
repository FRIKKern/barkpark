//go:build !unix

package chathost

// oNoFollow is 0 where the platform has no O_NOFOLLOW; O_EXCL and os.Root
// still keep an open off a link.
const oNoFollow = 0
