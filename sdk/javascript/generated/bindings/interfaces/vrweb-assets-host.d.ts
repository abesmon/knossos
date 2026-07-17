declare module 'vrweb:assets/host@1.0.0' {
  /**
   * Returns bounded metadata with a logical vrweb-asset URI, never a host path.
   */
  export function lookup(name: string): Uint8Array;
}
