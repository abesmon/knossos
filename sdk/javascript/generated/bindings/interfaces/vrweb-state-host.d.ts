declare module 'vrweb:state/host@1.0.0' {
  export function read(key: string): Uint8Array;
  export function command(request: Uint8Array): void;
  export function subscribe(key: string): bigint;
  export function unsubscribe(subscription: bigint): void;
}
