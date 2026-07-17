declare module 'vrweb:timers/host@1.0.0' {
  export function start(delayMs: number, repeat: boolean): bigint;
  export function cancel(timer: bigint): void;
}
