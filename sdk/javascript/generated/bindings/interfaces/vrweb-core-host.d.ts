declare module 'vrweb:core/host@1.0.0' {
  /**
   * Bounded diagnostic code for tests and low-overhead telemetry.
   */
  export function logCode(code: number): void;
  /**
   * Records a bounded guest-language error before the guest traps. Language adapters use this
   * to preserve their portable stack frames across the Component Model boundary.
   */
  export function reportError(message: string): void;
}
