// AUTO-GENERATED — do not edit. Regenerate with: mix barkpark.plugin.gen_types
//
// Source of truth: api/priv/plugin_manifest_schema.json
// This hand-written .d.ts is committed as a fallback. The mix task regenerates
// it from the JSON Schema via `npx json-schema-to-typescript` when Node.js is
// available. Drift between the schema and this file is detected by tests in
// api/test/barkpark/plugins/types_test.exs.

export type PluginCapability =
  | "routes"
  | "workers"
  | "schemas"
  | "settings"
  | "node"
  | "codelists";

export interface PluginDependency {
  plugin_name: string;
  version_req: string;
}

export interface PluginSchemaRef {
  name: string;
  version: string;
  file: string;
}

export interface PluginWorker {
  name: string;
  child_spec_module: string;
}

export interface PluginCodelist {
  issue: string | number;
  name: string;
  file: string;
}

export interface PluginNodeScripts {
  lint?: string;
  typecheck?: string;
}

export interface PluginNode {
  entrypoint: string;
  package: string;
  scripts?: PluginNodeScripts;
}

export interface PluginSettingsSchema {
  [key: string]: unknown;
}

export interface PluginManifest {
  plugin_name: string;
  version: string;
  description: string;
  capabilities: PluginCapability[];
  module?: string;
  dependencies?: PluginDependency[];
  schemas?: PluginSchemaRef[];
  routes?: string[];
  workers?: PluginWorker[];
  settings_schema?: PluginSettingsSchema;
  codelists?: PluginCodelist[];
  node?: PluginNode;
}
