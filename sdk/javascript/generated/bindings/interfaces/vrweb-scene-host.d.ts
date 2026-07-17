declare module 'vrweb:scene/host@1.0.0' {
  /**
   * Canonical bounded value/request encoding defined by VRWeb Scene API.
   */
  export function query(target: Handle, request: Uint8Array): Uint8Array;
  /**
   * Enqueues one command in a host-validated transaction.
   */
  export function mutate(transaction: bigint, command: Uint8Array): void;
  /**
   * Applies all commands atomically at a host phase boundary and returns a bounded result
   * containing guest create-token to opaque-handle mappings.
   */
  export function commit(transaction: bigint): Uint8Array;
  export function call(target: Handle, method: string, args: Array<Uint8Array>): Uint8Array;
  export function subscribe(target: Handle, signal: string): bigint;
  export function unsubscribe(subscription: bigint): void;
  /**
   * Opaque generational handle owned by one module/page instance.
   */
  export type Handle = bigint;
}
