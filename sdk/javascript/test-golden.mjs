import assert from "node:assert/strict";
import fs from "node:fs";
import { value } from "./src/value.js";

const golden = JSON.parse(fs.readFileSync(new URL("../../spec/value-codec-golden.json", import.meta.url)));
const actual = {
  null: value.null(), bool: value.bool(true), i64: value.int(42), f64: value.float(3.5),
  string: value.string("VRWeb ✓"), bytes: value.bytes(new Uint8Array([0, 1, 2, 255])),
  array: value.array([value.bool(true), value.int(7)]),
  map: value.map({ b: value.string("two"), a: value.int(1) }),
  vec2: value.vec2(1, 2), vec3: value.vec3(1, 2, 3), vec4: value.vec4(1, 2, 3, 4),
  quat: value.quat(0, 0, 0, 1), color: value.color(0.1, 0.2, 0.3, 0.4),
  basis: value.basis(1, 0, 0, 0, 1, 0, 0, 0, 1),
  transform3d: value.transform3d(1, 0, 0, 0, 1, 0, 0, 0, 1, 4, 5, 6),
};
for (const fixture of golden) assert.deepEqual(actual[fixture.name], fixture.wire, fixture.name);
console.log("JavaScript value codec golden vectors: PASS");
