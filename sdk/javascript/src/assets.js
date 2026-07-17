import * as assetsHost from "vrweb:assets/host@1.0.0";
import { json } from "./codec.js";

export const assets = Object.freeze({ lookup: (name) => json(assetsHost.lookup(name)) });
