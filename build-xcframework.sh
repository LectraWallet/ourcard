#!/bin/bash
# build-xcframework.sh
# Builds AirliftFFI.xcframework from rust-core/ (source) for iOS + simulator.
# Used by CI so the 127 MB prebuilt xcframework never has to live in git
# (GitHub blocks files over 100 MB on push). Locally, run this once after
# cloning, or keep using the prebuilt copy if you already have it.
set -euo pipefail
set -x

echo "==> Preflight pwd=$(pwd) HOME=${HOME:-<unset>}"
ls -la
command -v cargo rustup xcodebuild || true

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT/rust-core"

# cargo/rustup are already on PATH on the GitHub macOS runner (Homebrew rustup),
# so sourcing ~/.cargo/env is optional. It must never kill the build: source
# it with errexit off, because a failing command inside that file would
# otherwise exit this script from within the sourced file (the `|| true`
# on the source line does not protect against that).
if [ -f "$HOME/.cargo/env" ]; then
  set +e
  # shellcheck disable=SC1091
  source "$HOME/.cargo/env" 2>/dev/null
  set -e
fi
export PATH="$HOME/.cargo/bin:/opt/homebrew/opt/rustup/bin:$PATH"

export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=${HOME}=/build"
export CFLAGS="${CFLAGS:-} -ffile-prefix-map=${HOME}=/build"
export TARGET_CFLAGS="${TARGET_CFLAGS:-} -ffile-prefix-map=${HOME}=/build"

echo "==> Installing iOS targets (if needed)"
rustup target add aarch64-apple-ios aarch64-apple-ios-sim 2>/dev/null || true

echo "==> Building Rust static libs (release)"
cargo build --release --target aarch64-apple-ios
cargo build --release --target aarch64-apple-ios-sim

cd "$ROOT"
echo "==> Packaging AirliftFFI.xcframework"
rm -rf "$ROOT/AirliftFFI.xcframework"
xcodebuild -create-xcframework \
  -library rust-core/target/aarch64-apple-ios/release/libairlift_ffi.a \
  -headers rust-core/include \
  -library rust-core/target/aarch64-apple-ios-sim/release/libairlift_ffi.a \
  -headers rust-core/include \
  -output "$ROOT/AirliftFFI.xcframework"

echo "==> Done."
