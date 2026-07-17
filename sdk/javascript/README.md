# VRWeb JavaScript SDK

Creator-facing adapter for the language-neutral `vrweb:module@1` WIT world. The pinned local
toolchain compiles an ES module into a self-contained WebAssembly Component; Knossos does not
embed a special JavaScript API or JavaScript VM.

```bash
npm ci
npm run build:fixture
```

The generated component has no WASI imports. JavaScript receives only the `vrweb:*` interfaces
declared by WIT. Browser and Node globals are outside the runtime contract.

Content code imports the typed facade from `src/vrweb.js`. The fixture is TypeScript, is checked by
the pinned TypeScript compiler, and is then bundled by pinned `esbuild` before ComponentizeJS
creates the component. It exercises the facade against a real scoped scene root rather than
calling the raw WIT imports directly.

The adapter is experimental. Keep installation script-free (`npm ci --ignore-scripts`) and review
the lockfile before promoting it to a stable authoring toolchain: the current ComponentizeJS
dependency tree includes a known build-time archive-extraction advisory. It is not part of the
guest component or the Knossos runtime, but it still matters on a creator's build machine.
