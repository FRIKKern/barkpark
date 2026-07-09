package cli

// mcp_bridge.go — the generic capabilities→MCP bridge: turn EVERY bp capability
// (every manifest command) into an MCP tool automatically, so `bp mcp serve
// --tools all` exposes the whole API surface, not just the curated task five.
//
// This is a STUB. The bridge slice (mcp-w1-bridge) rewrites registerBridgeTools
// to walk the manifest commands and register one generic tool per command —
// deriving each tool's input schema from the command's args + flags and riding
// the SAME execManifestCommand seam the curated task tools use. Until then,
// `--tools all` is the curated set plus nothing extra: a no-op here keeps the
// flag live and the wiring honest without pretending to a surface that isn't
// built yet.

import (
	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// registerBridgeTools registers a generic MCP tool for every non-task manifest
// command. Stub: returns nil (no extra tools) until the bridge slice implements
// the capabilities walk. Signature is fixed so mcp_serve.go compiles against it
// now and the bridge slice only fills the body.
func registerBridgeTools(srv *mcp.Server, g globals, ctx manifest.Context, m *manifest.Manifest) error {
	_, _, _, _ = srv, g, ctx, m
	return nil
}
