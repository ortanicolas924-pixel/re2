#!/bin/bash
# Copyright 2022 The RE2 Authors.  All Rights Reserved.
# Use of this source code is governed by a BSD-style
# license that can be found in the LICENSE file.
#
# Base44 sandbox preview harness (sandbox only; upstream builds and CI use
# app/build.sh and the GitHub Pages workflow instead).
#
# Builds the repo's WebAssembly demo (app/) from the bind-mounted checkout,
# bundles the Lit frontend, rebuilds it when the app sources change, and serves
# the result on 0.0.0.0:${PORT}.

set -euo pipefail

SRC=/src
APP_SRC="${SRC}/app"
WORK=/work
PORT=5173

# Bazel 9 removed the native cc_binary rule that app/BUILD.bazel and BUILD.bazel
# still rely on, so the demo is built with Bazel 8.
export USE_BAZEL_VERSION=8.8.2
export PATH="/emsdk:/emsdk/upstream/emscripten:/emsdk/node/20.18.0_64bit/bin:${PATH}"

SOURCES=(app.ts index.html _re2.d.ts package.json rollup.config.js tsconfig.json)

log() { printf '[base44] %s\n' "$*"; }

sync_sources() {
  local f
  for f in "${SOURCES[@]}"; do
    cp -f "${APP_SRC}/${f}" "${WORK}/${f}"
  done
}

# Content stamp of the frontend sources, used to detect edits while serving.
stamp() {
  cd "${APP_SRC}" && md5sum "${SOURCES[@]}" | md5sum
}

build_bundle() {
  sync_sources
  cd "${WORK}"
  npx tsc
  npx rollup -c rollup.config.js -d deploy
}

# 1: wasm module. emcc/emar drive Bazel exactly as app/build.sh does.
# --lockfile_mode=off and --symlink_prefix keep Bazel from writing into the
# checkout (MODULE.bazel.lock and the bazel-* convenience symlinks).
# Only //app:_re2.js is built: the shared-library form of //:re2 cannot be
# linked by emcc ("-r and --gc-sections may not be used together").
log "building //app:_re2.js (Bazel ${USE_BAZEL_VERSION} + Emscripten)"
if ! command -v bazel >/dev/null 2>&1; then
  log "installing bazelisk"
  npm install --global --no-audit --no-fund --loglevel=error @bazel/bazelisk
fi
mkdir -p "${WORK}"
cd "${SRC}"
AR=emar CC=emcc bazel build \
  --lockfile_mode=off \
  --symlink_prefix=/tmp/bazel- \
  --copt=-fno-stack-protector \
  --compilation_mode=opt \
  -- //app:_re2.js
cp -f /tmp/bazel-bin/app/_re2.js "${WORK}/_re2.js"

# 2: frontend dependencies. app/package.json floats most versions ("*"), and
# TypeScript 6 removed the moduleResolution=node10 / esModuleInterop=false
# options that app/tsconfig.json still sets, so the major is pinned here
# rather than editing the upstream tsconfig.
log "installing frontend dependencies"
sync_sources
cd "${WORK}"
npm install --no-audit --no-fund --loglevel=error
npm install --no-save --no-audit --no-fund --loglevel=error typescript@5

# 3: bundle
build_bundle
log "bundle ready"

# 4: rebuild the bundle on app source edits, so a browser refresh picks them up
(
  last="$(stamp)"
  while sleep 2; do
    cur="$(stamp)" || continue
    if [ "${cur}" != "${last}" ]; then
      last="${cur}"
      log "app sources changed; rebuilding bundle"
      if build_bundle; then
        log "bundle rebuilt"
      else
        log "bundle rebuild FAILED"
      fi
    fi
  done
) &

# 5: serve
log "serving deploy/ on 0.0.0.0:${PORT}"
exec python3 -m http.server "${PORT}" --bind 0.0.0.0 --directory "${WORK}/deploy"
