#!/usr/bin/env bash
# Coworld replay-viewer build hook: invoked by `coworld build` with one
# argument, the absolute path of the static bundle directory to produce
# (<manifest-dir>/static-replay-viewer, which must end up containing
# index.html).
#
# Committed mode 100755 — `coworld build` hard-requires os.X_OK on this hook
# and refuses to package a source replay-viewer bundle without it.
#
# Paintbot's safety checks are kept: the target must be absolute, must be
# named static-replay-viewer, must lie inside the repo, and must not be a
# symlink.
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$#" -ne 1 ]]; then
  echo "usage: $0 /absolute/path/to/static-replay-viewer" >&2
  exit 1
fi

requested_output="$1"
if [[ "${requested_output}" != /* || \
      "$(basename "${requested_output}")" != "static-replay-viewer" ]]; then
  echo "unsafe bundle output: ${requested_output}" >&2
  exit 1
fi

mkdir -p "$(dirname "${requested_output}")"
output_parent="$(cd "$(dirname "${requested_output}")" && pwd -P)"
output_dir="${output_parent}/static-replay-viewer"
if [[ "${output_dir}" != "${repo_dir}"/* || -L "${output_dir}" ]]; then
  echo "unsafe bundle output: ${requested_output}" >&2
  exit 1
fi

rm -rf "${output_dir}"
mkdir -p "${output_dir}"

export PATH="$HOME/.nimby/nim/bin:$PATH"

if command -v emcc >/dev/null 2>&1 && command -v nim >/dev/null 2>&1; then
  # Local toolchain: build in place with the same recipe the container uses.
  (cd "${repo_dir}" && nim c --hints:off -d:emscripten \
    replay-viewer/gridlock_replay.nim)
  # Compile, THEN run: `nim c -r ... > file` sends nim's own error text into
  # the redirect and a broken build looks silent.
  (cd "${repo_dir}" && nim c --hints:off --path:src \
    -o:/tmp/gridlock_gen_wire tools/gen_wire_constants.nim)
  /tmp/gridlock_gen_wire > "${repo_dir}/replay-viewer/dist/wire_constants.js"
  cp "${repo_dir}/client/broadcast_core.js" \
    "${repo_dir}/client/chrome_common.js" \
    "${repo_dir}/replay-viewer/static_replay.js" \
    "${repo_dir}/replay-viewer/static_replay_worker.js" \
    "${repo_dir}/replay-viewer/dist/"
  cp "${repo_dir}/data/font.ttf" "${repo_dir}/replay-viewer/dist/font.ttf"
  mkdir -p "${repo_dir}/replay-viewer/dist/art/walls"
  cp "${repo_dir}"/client/art/*.png "${repo_dir}"/client/art/*.jpg \
    "${repo_dir}/replay-viewer/dist/art/"
  cp "${repo_dir}"/client/art/walls/*.jpg \
    "${repo_dir}/replay-viewer/dist/art/walls/"
  sed -e 's|<!-- WIRE_CONSTANTS -->|<script src="./wire_constants.js"></script>|' \
      -e 's|<!-- CHROME_COMMON -->|<script src="./chrome_common.js"></script>|' \
      -e 's|<!-- BROADCAST_CORE -->|<script src="./static_replay.js"></script>|' \
    "${repo_dir}/client/replay_broadcast.html" \
    > "${repo_dir}/replay-viewer/dist/index.html"
  rm -rf "${repo_dir}/replay-viewer/dist/nimcache"
  cp -R "${repo_dir}/replay-viewer/dist/." "${output_dir}"
else
  # No local emcc (the CI runner, and the coworld-builder sandbox): build in
  # the pinned emscripten/emsdk container.
  image_tag="coworld-gridlock-replay-viewer-build:$$"
  container_id=""
  cleanup() {
    if [[ -n "${container_id}" ]]; then
      docker rm "${container_id}" >/dev/null 2>&1 || true
    fi
    docker image rm "${image_tag}" >/dev/null 2>&1 || true
  }
  trap cleanup EXIT

  build_args=(
    --platform linux/amd64
    --file "${repo_dir}/Dockerfile.replay-viewer"
    --target replay-viewer-builder
    --tag "${image_tag}"
    "${repo_dir}"
  )
  if docker buildx version >/dev/null 2>&1; then
    docker buildx build --load "${build_args[@]}"
  else
    docker build "${build_args[@]}"
  fi
  container_id="$(docker create --platform linux/amd64 "${image_tag}")"
  docker cp "${container_id}:/workspace/gridlock/replay-viewer/dist/." \
    "${output_dir}"
fi

test -f "${output_dir}/index.html"
test -s "${output_dir}/gridlock_replay.wasm"
test -s "${output_dir}/static_replay_worker.js"
grep -q 'data-replay-loaded' "${output_dir}/static_replay.js"
grep -q 'data-replay-error' "${output_dir}/static_replay.js"
echo "gridlock replay viewer bundle: ${output_dir}"
