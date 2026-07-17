/// <reference path="./interfaces/vrweb-assets-host.d.ts" />
/// <reference path="./interfaces/vrweb-core-host.d.ts" />
/// <reference path="./interfaces/vrweb-features-host.d.ts" />
/// <reference path="./interfaces/vrweb-input-host.d.ts" />
/// <reference path="./interfaces/vrweb-log-host.d.ts" />
/// <reference path="./interfaces/vrweb-scene-host.d.ts" />
/// <reference path="./interfaces/vrweb-state-host.d.ts" />
/// <reference path="./interfaces/vrweb-timers-host.d.ts" />
declare module 'vrweb:module/module@1.0.0' {
  export type * as VrwebAssetsHost100 from 'vrweb:assets/host@1.0.0'; // import vrweb:assets/host@1.0.0
  export type * as VrwebCoreHost100 from 'vrweb:core/host@1.0.0'; // import vrweb:core/host@1.0.0
  export type * as VrwebFeaturesHost100 from 'vrweb:features/host@1.0.0'; // import vrweb:features/host@1.0.0
  export type * as VrwebInputHost100 from 'vrweb:input/host@1.0.0'; // import vrweb:input/host@1.0.0
  export type * as VrwebLogHost100 from 'vrweb:log/host@1.0.0'; // import vrweb:log/host@1.0.0
  export type * as VrwebSceneHost100 from 'vrweb:scene/host@1.0.0'; // import vrweb:scene/host@1.0.0
  export type * as VrwebStateHost100 from 'vrweb:state/host@1.0.0'; // import vrweb:state/host@1.0.0
  export type * as VrwebTimersHost100 from 'vrweb:timers/host@1.0.0'; // import vrweb:timers/host@1.0.0
  /**
  * Creates guest-owned lifecycle state and returns its opaque guest id.
  */
  export function create(): number;
  /**
  * Mounts one component instance. Zero means success.
  */
  export function mount(instance: number): number;
  /**
  * Delivers one bounded serialized event envelope. Zero means success.
  */
  export function event(instance: number, envelope: Uint8Array): number;
  /**
  * Invalidates guest state. Zero means success.
  */
  export function unmount(instance: number): number;
}
