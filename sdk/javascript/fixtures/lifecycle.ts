import { core, scene, state, value } from "@vrweb/sdk";

let nextInstance = 1;

function hostGlobal(name: string): unknown {
  return (globalThis as unknown as Record<string, unknown>)[name];
}

function containsAscii(bytes: Uint8Array, text: string): boolean {
  outer: for (let start = 0; start <= bytes.length - text.length; start += 1) {
    for (let index = 0; index < text.length; index += 1) {
      if (bytes[start + index] !== text.charCodeAt(index)) continue outer;
    }
    return true;
  }
  return false;
}

export function create(): number {
  const isolated = hostGlobal("window") === undefined
    && hostGlobal("document") === undefined
    && hostGlobal("process") === undefined;
  const root = scene.root();
  const createTransaction = scene.transaction();
  const token = createTransaction.create("Node3D", root);
  const created = scene.node(createTransaction.commit().created[token]);
  const parent = created.parent();
  const scopedCreation = parent?.handle === root.handle;
  core.logCode(isolated ? 81 : -81);
  core.logCode(root.handle > 0n ? 82 : -82);
  core.logCode(created.handle !== root.handle ? 83 : -83);
  core.logCode(scopedCreation ? 84 : -84);
  scene.transaction().destroy(created).commit();
  core.logCode(isolated && root.handle > 0n && scopedCreation ? 71 : -71);
  return nextInstance++;
}

export function mount(instance: number): number {
  core.logCode(instance === 1 ? 72 : -72);
  return 0;
}

export function event(instance: number, envelope: Uint8Array): number {
  if (envelope[0] === 255) {
    while (true) { /* runtime fuel/epoch must stop hostile guest code */ }
  }
  if (envelope[0] === 254) {
    const chunks: Uint8Array[] = [];
    while (true) chunks.push(new Uint8Array(1024 * 1024));
  }
  if (envelope[0] === 253) {
    throw new Error("VRWEB_SOURCE_MAP_PROBE");
  }
  if (envelope[0] === 123 && containsAscii(envelope, "source-map-probe")) {
    throw new Error("VRWEB_SOURCE_MAP_PROBE");
  }
  if (envelope[0] === 123 && containsAscii(envelope, "oversized-error")) {
    throw new Error("X".repeat(20_000));
  }
  // ComponentizeJS may pass a cross-realm Uint8Array for which instanceof is false. Validate
  // the observable WIT list<u8> contract instead of an engine-specific prototype identity.
  const isByteEnvelope = typeof envelope?.length === "number" && envelope[0] === 123;
  const root = scene.root();
  scene.transaction().set(root, "visible", value.bool(false)).commit();
  state.command({ key: "light", command: "set", value: true });
  const lightIsOn = state.read("light") === true;
  core.logCode(instance === 1 && isByteEnvelope && lightIsOn ? 73 : -73);
  return 0;
}

export function unmount(instance: number): number {
  core.logCode(instance === 1 ? 74 : -74);
  return 0;
}
