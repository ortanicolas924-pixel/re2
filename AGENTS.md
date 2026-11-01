# AGENTS.md

Notes for agents working in this repository inside the Base44 sandbox. The
sandbox artifacts are `docker-compose.base44.yml` and `.base44/preview.sh`;
nothing else in the tree was changed to make it run.

## What is runnable here

RE2 is a C++ library, not a web app. The only user-visible UI in this repo is
the WebAssembly pattern inspector in `app/` (`app/app.ts` + `app/_re2.cc`,
rendered by `app/index.html`), so the preview serves that demo on host port
3000. Upstream builds it in `app/build.sh` and publishes it via
`.github/workflows/pages.yml`.

## Start / stop

```sh
docker compose -f docker-compose.base44.yml up -d
docker compose -f docker-compose.base44.yml logs -f web
```

## Non-obvious build requirements

- **Pin Bazel 8 (`USE_BAZEL_VERSION=8.8.2`).** Current Bazel 9 removed the
  native `cc_binary` rule; `BUILD.bazel` and `app/BUILD.bazel` still use it, so
  Bazel 9 fails with "This rule has been removed from Bazel". The harness
  installs `@bazel/bazelisk` and pins the version through the env var.
- **Build `//app:_re2.js`, not `//:re2`.** `//:re2` also links `libre2.so`,
  which emcc cannot produce (`wasm-ld: error: -r and --gc-sections may not be
  used together`). The demo target only needs the static archive.
- **Pin TypeScript 5.** `app/package.json` floats `"typescript": "*"`, and TS 6
  removed the `moduleResolution: node10` / `esModuleInterop: false` options that
  `app/tsconfig.json` sets (TS5108). The harness installs `typescript@5` with
  `--no-save` instead of editing the upstream tsconfig.
- **Keep Bazel out of the checkout.** The harness passes
  `--lockfile_mode=off` and `--symlink_prefix=/tmp/bazel-` so `MODULE.bazel.lock`
  and the `bazel-*` convenience symlinks are not created in the repo. Keep those
  flags if you change the build command.
- A cold start compiles RE2 for wasm (with googletest, because the target
  depends on `//:testing`) and takes a couple of minutes; bazel/npm caches live
  in the `re2_bazel_cache`, `re2_npm_cache` and `re2_bundle` volumes so later
  starts are fast. The compose healthcheck uses a 300s start period for this.

## Editing loop

The container builds from the bind-mounted checkout, not from a baked image.
`.base44/preview.sh` polls the mtimes of `app/{app.ts,index.html,_re2.d.ts,
package.json,rollup.config.js,tsconfig.json}` every 2s and re-runs `tsc` +
`rollup` into `/work/deploy`, so a browser refresh picks up frontend edits
within a few seconds. There is no HMR server here, so reload the preview after
an edit. Changes to `app/_re2.cc` or `re2/**` require rebuilding the wasm module
— restart the service:

```sh
docker compose -f docker-compose.base44.yml restart web
```

## Verifying it works

The page is a single static document (no router). `<re2-dev>` renders its input
inside a shadow root, so plain CSS selectors will not reach it — query
`document.querySelector('re2-dev').shadowRoot`. It updates on the input's
`change` event, not `input`. A working build shows
`pattern:`, `num_captures:`, `bytecode:` and `bytemap:` after entering a
pattern, and `error: failed to parse pattern: ...` for an invalid one.

Native library tests (not needed for the preview) go through Bazel or
`bash runtests`.
