function finiteList(tag, values, size) {
  if (values.length !== size || values.some((item) => !Number.isFinite(item))) {
    throw new TypeError(`VRWeb ${tag} requires ${size} finite numbers`);
  }
  return { t: tag, v: values };
}

function base64(bytes) {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  let result = "";
  for (let index = 0; index < bytes.length; index += 3) {
    const a = bytes[index];
    const hasB = index + 1 < bytes.length;
    const hasC = index + 2 < bytes.length;
    const b = hasB ? bytes[index + 1] : 0;
    const c = hasC ? bytes[index + 2] : 0;
    result += alphabet[a >> 2];
    result += alphabet[((a & 3) << 4) | (b >> 4)];
    result += hasB ? alphabet[((b & 15) << 2) | (c >> 6)] : "=";
    result += hasC ? alphabet[c & 63] : "=";
  }
  return result;
}

export const value = Object.freeze({
  null: () => ({ t: "null" }),
  bool: (v) => ({ t: "bool", v: Boolean(v) }),
  int: (v) => ({ t: "i64", v: BigInt(v).toString() }),
  float: (v) => {
    if (!Number.isFinite(v)) throw new TypeError("VRWeb float must be finite");
    return { t: "f64", v };
  },
  string: (v) => ({ t: "string", v: String(v) }),
  bytes: (v) => ({ t: "bytes", v: base64(v) }),
  array: (v) => ({ t: "array", v }),
  map: (v) => ({ t: "map", v: Object.entries(v).sort(([a], [b]) => a.localeCompare(b)) }),
  vec2: (x, y) => finiteList("vec2", [x, y], 2),
  vec3: (x, y, z) => finiteList("vec3", [x, y, z], 3),
  vec4: (x, y, z, w) => finiteList("vec4", [x, y, z, w], 4),
  quat: (x, y, z, w) => finiteList("quat", [x, y, z, w], 4),
  color: (r, g, b, a = 1) => finiteList("color", [r, g, b, a].map(Math.fround), 4),
  basis: (...v) => finiteList("basis", v, 9),
  transform3d: (...v) => finiteList("transform3d", v, 12),
});
