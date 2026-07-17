const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });

export function bytes(value) {
  return encoder.encode(JSON.stringify(value));
}

export function json(value) {
  return JSON.parse(decoder.decode(value));
}
