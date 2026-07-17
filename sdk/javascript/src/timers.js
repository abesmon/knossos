import * as timersHost from "vrweb:timers/host@1.0.0";

export const timers = Object.freeze({ start: timersHost.start, cancel: timersHost.cancel });
