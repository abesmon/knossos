import * as stateHost from "vrweb:state/host@1.0.0";
import { bytes, json } from "./codec.js";

export const state = Object.freeze({
  read: (key) => json(stateHost.read(key)),
  command: (request) => stateHost.command(bytes(request)),
  subscribe: stateHost.subscribe,
  unsubscribe: stateHost.unsubscribe,
});
