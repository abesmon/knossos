import { readFileSync } from "node:fs";

export function create() {
  return readFileSync("/etc/passwd").length;
}
