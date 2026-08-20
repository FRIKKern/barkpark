// Metro config for a pnpm monorepo member (charter D2/D14).
//
// apps/mobile lives in the ROOT pnpm workspace next to web/ and the js SDK
// packages, so Metro must (a) watch the workspace root — @barkpark/core and
// @barkpark/react are symlinked workspace deps whose source lives outside
// this project dir — and (b) resolve modules from BOTH node_modules trees.
// pnpm's isolated layout means every dependency is a symlink into the root
// .pnpm store; Metro's symlink resolution (default-on since Metro 0.79 /
// RN 0.73) follows them, so NO node-linker=hoisted .npmrc is needed — do not
// add one at the workspace root, it would re-layout web/'s install too.
const { getDefaultConfig } = require('expo/metro-config')
const path = require('path')

const projectRoot = __dirname
const workspaceRoot = path.resolve(projectRoot, '../..')

const config = getDefaultConfig(projectRoot)

config.watchFolders = [workspaceRoot]
config.resolver.nodeModulesPaths = [
  path.resolve(projectRoot, 'node_modules'),
  path.resolve(workspaceRoot, 'node_modules'),
]

module.exports = config
