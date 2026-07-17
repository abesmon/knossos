import * as structuredLogHost from "vrweb:log/host@1.0.0";
import { bytes } from "./codec.js";

export const log = Object.freeze({ write: (request) => structuredLogHost.write(bytes(request)) });
