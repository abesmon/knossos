import { createHash } from "node:crypto";
import { copyFileSync, cpSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join, relative, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { performance } from "node:perf_hooks";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

const root = dirname(fileURLToPath(import.meta.url));
const repository = resolve(root, "../..");
const jco = join(root, "node_modules/.bin/jco");
const esbuild = join(root, "node_modules/.bin/esbuild");
const tsc = join(root, "node_modules/.bin/tsc");
const wit = resolve(root, "../wit");
const dist = join(root, "dist");
function option(name) {
  const index = process.argv.indexOf(name);
  if (index === -1) return undefined;
  if (!process.argv[index + 1]) throw new Error(`${name} requires a value`);
  return resolve(process.cwd(), process.argv[index + 1]);
}
const requestedSource = option("--entry");
const requestedManifest = option("--manifest");
const requestedOutput = option("--output");
if ([requestedSource, requestedManifest, requestedOutput].filter(Boolean).length > 0
    && !requestedSource) throw new Error("--entry is required for an external build");
if (requestedSource && (!requestedManifest || !requestedOutput)) {
  throw new Error("external build requires --entry, --manifest and --output");
}
const externalBuild = Boolean(requestedSource);
const source = requestedSource ?? join(root, "fixtures/lifecycle.ts");
const requestedManifestData = externalBuild
  ? JSON.parse(readFileSync(requestedManifest, "utf8")) : undefined;
const debugSourceMap = externalBuild
  ? requestedManifestData?.debug?.source_map : "debug/module.wasm.map";
if (debugSourceMap !== undefined && (typeof debugSourceMap !== "string" || !debugSourceMap.endsWith(".map"))) {
  throw new Error("manifest debug.source_map must be a .map path");
}
const buildDirectory = externalBuild ? mkdtempSync(join(tmpdir(), "vrweb-js-build-")) : dist;
const adapterEntry = join(buildDirectory, "adapter-entry.mjs");
const bundledSource = join(buildDirectory, "module.bundle.js");
const bundledSourceMap = `${bundledSource}.map`;
const component = join(buildDirectory, "module.wasm");
const check = process.argv.includes("--check");

const fixtureManifest = {
  format: 1,
  id: "vrweb.example.javascript-lifecycle",
  version: "1.0.0",
  sdk: "1.0.0",
  runtime: "wasm-component",
  world: "vrweb:module@1",
  component: "module.wasm",
  exports: { default: { kind: "scene-component" } },
  requires: [
    "vrweb:core/1", "vrweb:scene/1", "vrweb:assets/1", "vrweb:state/1",
    "vrweb:timers/1", "vrweb:input/1", "vrweb:features/1", "vrweb:log/1",
  ],
  optional: [],
  limits: { fuel: 50000000 },
  debug: { source_map: debugSourceMap },
};
const effectiveManifest = requestedManifestData ?? fixtureManifest;

function run(command, args, options = {}) {
  const result = spawnSync(command, args, { cwd: root, encoding: "utf8", stdio: options.capture ? "pipe" : "inherit" });
  if (result.status !== 0) {
    throw new Error(`${basename(command)} failed with exit ${result.status}${result.stderr ? `\n${result.stderr}` : ""}`);
  }
  return result.stdout ?? "";
}

function requireFailure(command, args, label) {
  const result = spawnSync(command, args, { cwd: root, encoding: "utf8", stdio: "pipe" });
  if (result.status === 0) throw new Error(`${label} unexpectedly succeeded`);
}

function sha256File(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

function filesUnder(directory) {
  const result = [];
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) result.push(...filesUnder(path));
    else result.push(path);
  }
  return result.sort();
}

function verifyBindings() {
  const temporary = mkdtempSync(join(tmpdir(), "vrweb-js-bindings-"));
  try {
    run(jco, ["guest-types", wit, "-n", "module", "-o", temporary, "--strict"]);
    const committed = join(root, "generated/bindings");
    const expected = filesUnder(committed).map((path) => relative(committed, path));
    const actual = filesUnder(temporary).map((path) => relative(temporary, path));
    if (JSON.stringify(actual) !== JSON.stringify(expected)) throw new Error("generated binding file list is stale");
    for (const path of expected) {
      if (readFileSync(join(committed, path), "utf8") !== readFileSync(join(temporary, path), "utf8")) {
        throw new Error(`generated binding is stale: ${path}`);
      }
    }
  } finally {
    rmSync(temporary, { recursive: true, force: true });
  }
}

mkdirSync(dist, { recursive: true });
verifyBindings();
if (externalBuild) {
  const typeConfig = join(buildDirectory, "tsconfig.json");
  writeFileSync(typeConfig, JSON.stringify({
    compilerOptions: {
      target: "ES2022", module: "ESNext", moduleResolution: "Bundler", strict: true,
      noEmit: true, skipLibCheck: false, lib: ["ES2022"], baseUrl: root,
      paths: { "@vrweb/sdk": [join(root, "src/vrweb.d.ts")] },
    },
    files: [source, join(root, "src/vrweb.d.ts"), join(root, "generated/bindings/module.d.ts")],
  }, null, 2));
  run(tsc, ["--project", typeConfig]);
} else {
  run(tsc, ["--project", join(root, "tsconfig.json")]);
}
requireFailure(esbuild, [join(root, "fixtures/hostile-node.mjs"), "--bundle", "--format=esm",
  "--platform=neutral", `--outfile=${join(dist, "hostile-node.js")}`, "--log-level=silent"],
"Node filesystem dependency bundle");
const sourceSpecifier = source.replaceAll("\\", "\\\\").replaceAll('"', '\\"');
writeFileSync(adapterEntry, `
import * as guest from "${sourceSpecifier}";
import { reportError } from "vrweb:core/host@1.0.0";

function invoke(callback) {
  try {
    return callback();
  } catch (error) {
    const stack = error && typeof error.stack === "string" ? error.stack : "";
    const portableFrames = stack.split("\\n").filter((line) => line.includes("module.bundle.js:"));
    reportError([String(error), ...portableFrames].join("\\n"));
    throw error;
  }
}

export function create() { return invoke(() => guest.create()); }
export function mount(instance) { return invoke(() => guest.mount(instance)); }
export function event(instance, envelope) { return invoke(() => guest.event(instance, envelope)); }
export function unmount(instance) { return invoke(() => guest.unmount(instance)); }
`);
await build({
  entryPoints: [adapterEntry],
  bundle: true,
  format: "esm",
  platform: "neutral",
  outfile: bundledSource,
  logLevel: "warning",
  sourcemap: debugSourceMap ? "external" : false,
  sourcesContent: Boolean(debugSourceMap),
  plugins: [{
    name: "vrweb-wit-external",
    setup(build) {
      build.onResolve({ filter: /^@vrweb\/sdk$/ }, () => ({
        path: join(root, "src/vrweb.js"), sideEffects: false,
      }));
      build.onResolve({ filter: /^\.\.?\// }, (args) => {
        if (!args.importer.startsWith(join(root, "src"))) return undefined;
        return { path: resolve(dirname(args.importer), args.path), sideEffects: false };
      });
      build.onResolve({ filter: /^vrweb:/ }, (args) => ({
        path: args.path,
        external: true,
        // WIT imports are capability functions, not side-effectful module initializers. This lets
        // esbuild remove SDK interfaces that creator source never references.
        sideEffects: false,
      }));
    },
  }],
});
if (debugSourceMap) {
  const map = JSON.parse(readFileSync(bundledSourceMap, "utf8"));
  map.file = "module.bundle.js";
  map.sourceRoot = "vrweb-source:///";
  map.sources = map.sources.map((path) => {
    const normalized = path.replaceAll("\\", "/");
    if (normalized.endsWith(`/${basename(source)}`) || normalized === basename(source)) {
      return basename(source);
    }
    return `@vrweb/sdk/${basename(normalized)}`;
  });
  map.x_vrweb_generated = "module.bundle.js";
  writeFileSync(bundledSourceMap, JSON.stringify(map));
}
const bundledText = readFileSync(bundledSource, "utf8");
const importedInterfaces = new Set(
  [...bundledText.matchAll(/from\s+["'](vrweb:[^/]+\/host@\d+\.\d+\.\d+)["']/g)]
    .map((match) => match[1]),
);
if (importedInterfaces.size === 0) {
  throw new Error("JavaScript bundle has no VRWeb host imports");
}
const declaredCapabilities = new Set([
  ...(effectiveManifest.requires ?? []), ...(effectiveManifest.optional ?? []),
]);
for (const importedInterface of importedInterfaces) {
  const match = /^(vrweb:[^/]+)\/host@(\d+)\./.exec(importedInterface);
  if (!match) throw new Error(`unsupported VRWeb host import: ${importedInterface}`);
  const capability = `${match[1]}/${match[2]}`;
  if (!declaredCapabilities.has(capability)) {
    throw new Error(`component imports undeclared capability: ${capability}`);
  }
}

// ComponentizeJS includes every import declared by its selected world, even when JavaScript does
// not reference it. Generate a build-local world from the imports that survived tree-shaking so
// the component's actual authority is no wider than the creator source requires.
const importOrder = [
  "vrweb:core/host@1.0.0", "vrweb:scene/host@1.0.0", "vrweb:assets/host@1.0.0",
  "vrweb:state/host@1.0.0", "vrweb:timers/host@1.0.0", "vrweb:input/host@1.0.0",
  "vrweb:features/host@1.0.0", "vrweb:log/host@1.0.0",
];
const unknownImports = [...importedInterfaces].filter((name) => !importOrder.includes(name));
if (unknownImports.length > 0) {
  throw new Error(`JavaScript bundle imports unsupported VRWeb interfaces: ${unknownImports.join(", ")}`);
}
const tailoredWit = mkdtempSync(join(tmpdir(), "vrweb-js-wit-"));
cpSync(join(wit, "deps"), join(tailoredWit, "deps"), { recursive: true });
writeFileSync(join(tailoredWit, "module.wit"), `package vrweb:module@1.0.0;

world module {
${importOrder.filter((name) => importedInterfaces.has(name)).map((name) => `  import ${name};`).join("\n")}

  export create: func() -> s32;
  export mount: func(instance: s32) -> s32;
  export event: func(instance: s32, envelope: list<u8>) -> s32;
  export unmount: func(instance: s32) -> s32;
}
`);
const componentizeStarted = performance.now();
try {
  run(jco, ["componentize", bundledSource, "--wit", tailoredWit, "-n", "module", "--disable=all", "-o", component]);
} finally {
  rmSync(tailoredWit, { recursive: true, force: true });
}
const componentizeMs = Math.round(performance.now() - componentizeStarted);
const observedWit = run(jco, ["wit", component], { capture: true });
const expectedWit = readFileSync(join(root, "fixtures/expected.wit"), "utf8");
if (!externalBuild && observedWit.trimEnd() !== expectedWit.trimEnd()) {
  throw new Error("component WIT fingerprint differs from expected.wit");
}
for (const lifecycleExport of ["create", "mount", "event", "unmount"]) {
  if (!observedWit.includes(`export ${lifecycleExport}: func(`)) {
    throw new Error(`component is missing lifecycle export: ${lifecycleExport}`);
  }
}
if (observedWit.includes("wasi:")) throw new Error("JavaScript component unexpectedly imports WASI");

const observedImports = [...observedWit.matchAll(/import (vrweb:[^/]+)\/host@(\d+)\.[^;]+;/g)]
  .map((match) => `${match[1]}/${match[2]}`);
for (const capability of observedImports) {
  if (!declaredCapabilities.has(capability)) {
    throw new Error(`component imports undeclared capability: ${capability}`);
  }
}
let manifestPath;
let packageOutput;
if (externalBuild) {
  manifestPath = requestedManifest;
  packageOutput = requestedOutput;
  const manifest = requestedManifestData;
  if (manifest.runtime !== "wasm-component" || manifest.world !== "vrweb:module@1"
      || manifest.sdk !== "1.0.0" || typeof manifest.component !== "string") {
    throw new Error("external manifest must declare runtime, world, sdk 1.0.0 and component");
  }
  const manifestDirectory = dirname(manifestPath);
  const componentTarget = resolve(manifestDirectory, manifest.component);
  const componentRelative = relative(manifestDirectory, componentTarget);
  if (componentRelative.startsWith("..") || componentRelative === "") {
    throw new Error("manifest component must stay below the manifest directory");
  }
  mkdirSync(dirname(componentTarget), { recursive: true });
  copyFileSync(component, componentTarget);
  if (debugSourceMap) {
    const sourceMapTarget = resolve(manifestDirectory, debugSourceMap);
    const sourceMapRelative = relative(manifestDirectory, sourceMapTarget);
    if (sourceMapRelative.startsWith("..") || sourceMapRelative === "") {
      throw new Error("manifest debug source map must stay below the manifest directory");
    }
    mkdirSync(dirname(sourceMapTarget), { recursive: true });
    copyFileSync(bundledSourceMap, sourceMapTarget);
  }
} else {
  manifestPath = join(dist, "vrweb-module.json");
  packageOutput = join(dist, "lifecycle.vrmod");
  const sourceMapTarget = join(dist, debugSourceMap);
  mkdirSync(dirname(sourceMapTarget), { recursive: true });
  copyFileSync(bundledSourceMap, sourceMapTarget);
  writeFileSync(manifestPath, JSON.stringify(fixtureManifest, null, 2) + "\n");
}
run("python3", [resolve(repository, "tools/build_vrmod.py"), "--manifest", manifestPath,
  "--output", packageOutput]);

const evidence = {
  format: 1,
  sdk: "1.0.0",
  adapter: "componentize-js",
  componentize_js: "0.21.0",
  jco: "1.25.2",
  byte_reproducible: false,
  reproducibility: "Pinned source, lockfile, generated bindings and exact WIT fingerprint; ComponentizeJS/Wizer output contains nondeterministic VM snapshot bytes.",
  source_sha256: sha256File(source),
  bundle_sha256: sha256File(bundledSource),
  lock_sha256: sha256File(join(root, "package-lock.json")),
  wit_sha256: createHash("sha256").update(observedWit).digest("hex"),
  component_sha256: sha256File(component),
  component_bytes: readFileSync(component).byteLength,
  componentize_ms: componentizeMs,
};
const evidencePath = externalBuild ? `${packageOutput}.evidence.json` : join(dist, "build-evidence.json");
writeFileSync(evidencePath, JSON.stringify(evidence, null, 2) + "\n");
if (externalBuild) rmSync(buildDirectory, { recursive: true, force: true });
console.log(`VRWeb JavaScript component ${check ? "check" : "build"}: PASS`);
