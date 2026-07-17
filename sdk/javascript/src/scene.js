import * as sceneHost from "vrweb:scene/host@1.0.0";
import { sceneCatalog } from "../generated/catalog.js";
import { bytes, json } from "./codec.js";
export { value } from "./value.js";
import { value } from "./value.js";

let nextTransaction = 1n;

export class SceneTransaction {
  constructor() {
    this.id = nextTransaction++;
    this.closed = false;
    this.nextCreateToken = 0;
  }

  set(node, property, encodedValue) {
    this.#mutate({ op: "set", handle: node.handle.toString(), property, value: encodedValue });
    return this;
  }

  create(className, parent, initial = {}) {
    const token = `${this.id}:${this.nextCreateToken++}`;
    this.#mutate({ op: "create", token, class: className,
      parent: parent.handle.toString(), initial });
    return token;
  }

  setResource(node, property, resource) {
    this.#mutate({ op: "set_resource", handle: node.handle.toString(), property,
      resource: BigInt(resource).toString() });
    return this;
  }

  reparent(node, parent) {
    this.#mutate({ op: "reparent", handle: node.handle.toString(), parent: parent.handle.toString() });
    return this;
  }

  destroy(node) {
    this.#mutate({ op: "destroy", handle: node.handle.toString() });
    return this;
  }

  commit() {
    if (this.closed) throw new Error("VRWeb transaction is closed");
    this.closed = true;
    return json(sceneHost.commit(this.id));
  }

  #mutate(command) {
    if (this.closed) throw new Error("VRWeb transaction is closed");
    sceneHost.mutate(this.id, bytes(command));
  }
}

export class SceneNode {
  constructor(handle) { this.handle = BigInt(handle); }

  static root() {
    return new SceneNode(BigInt(json(sceneHost.query(0n, bytes({ op: "root" })))));
  }

  className() { return json(sceneHost.query(this.handle, bytes({ op: "class" }))); }
  name() { return json(sceneHost.query(this.handle, bytes({ op: "name" }))); }
  parent() {
    const handle = BigInt(json(sceneHost.query(this.handle, bytes({ op: "parent" }))));
    return handle === 0n ? null : new SceneNode(handle);
  }
  get(property) { return json(sceneHost.query(this.handle, bytes({ op: "property", property }))); }
  children() {
    return json(sceneHost.query(this.handle, bytes({ op: "children" })))
      .map((handle) => new SceneNode(handle));
  }
  call(method, args = []) { return json(sceneHost.call(this.handle, method, args.map(bytes))); }
  subscribe(signal) { return sceneHost.subscribe(this.handle, signal); }
}

export const scene = Object.freeze({
  root: SceneNode.root,
  node: (handle) => new SceneNode(handle),
  createResource: (className) => BigInt(json(sceneHost.query(0n,
    bytes({ op: "create_resource", class: className })))),
  transaction: () => new SceneTransaction(),
  catalog: sceneCatalog,
});
