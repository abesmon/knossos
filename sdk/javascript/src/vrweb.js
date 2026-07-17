// Side-effect-free barrel. Each capability lives in its own module so unused WIT imports are
// removed from the resulting Component instead of silently widening creator scope.
export { core } from "./core.js";
export { SceneNode, SceneTransaction, scene, value } from "./scene.js";
export { state } from "./state.js";
export { assets } from "./assets.js";
export { timers } from "./timers.js";
export { input } from "./input.js";
export { features } from "./features.js";
export { log } from "./log.js";
export { sdkVersion } from "../generated/catalog.js";
