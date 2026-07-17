import type { SceneMethod, SceneSignal } from "../generated/catalog.js";

export type Handle = bigint;
export type EncodedValue = { t: string; v?: unknown };

export declare const sdkVersion: "1.0.0";
export declare const value: {
  null(): EncodedValue;
  bool(value: boolean): EncodedValue;
  int(value: bigint | number): EncodedValue;
  float(value: number): EncodedValue;
  string(value: string): EncodedValue;
  vec2(x: number, y: number): EncodedValue;
  vec3(x: number, y: number, z: number): EncodedValue;
  vec4(x: number, y: number, z: number, w: number): EncodedValue;
  color(r: number, g: number, b: number, a?: number): EncodedValue;
};

export declare class SceneNode {
  readonly handle: Handle;
  constructor(handle: Handle | number | string);
  static root(): SceneNode;
  className(): string;
  name(): string;
  parent(): SceneNode | null;
  get(property: string): EncodedValue;
  children(): SceneNode[];
  call(method: SceneMethod | string, args?: EncodedValue[]): EncodedValue;
  subscribe(signal: SceneSignal | string): bigint;
}

export declare class SceneTransaction {
  readonly id: bigint;
  readonly closed: boolean;
  set(node: SceneNode, property: string, value: EncodedValue): this;
  create(className: string, parent: SceneNode, initial?: Record<string, EncodedValue>): string;
  setResource(node: SceneNode, property: string, resource: Handle | number | string): this;
  reparent(node: SceneNode, parent: SceneNode): this;
  destroy(node: SceneNode): this;
  commit(): { applied: number; created: Record<string, string | number> };
}

export declare const core: {
  logCode(code: number): void;
  reportError(message: string): void;
};
export declare const scene: {
  root(): SceneNode;
  transaction(): SceneTransaction;
  readonly catalog: Readonly<Record<string, unknown>>;
  node(handle: Handle | number | string): SceneNode;
  createResource(className: string): Handle;
};
export declare const state: {
  read(key: string): unknown;
  command(request: object): void;
  subscribe(key: string): bigint;
  unsubscribe(subscription: bigint): void;
};
export declare const assets: { lookup(name: string): unknown };
export declare const timers: { start(delayMs: number, repeat: boolean): bigint; cancel(timer: bigint): void };
export declare const input: { enable(kind: string, enabled: boolean): void };
export declare const features: { has(capability: string): boolean };
export declare const log: { write(request: object): void };
