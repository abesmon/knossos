import { core } from "@vrweb/sdk";

export function create(): number { core.logCode(1); return 1; }
export function mount(_instance: number): number { return 0; }
export function event(_instance: number, _event: Uint8Array): number { return 0; }
export function unmount(_instance: number): number { return 0; }
