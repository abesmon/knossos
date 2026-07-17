#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
crate="$root/native/vrweb_wasm_runtime"
out="$root/addons/vrweb_wasm_runtime"
cargo_bin="${CARGO:-$HOME/.cargo/bin/cargo}"
rustc_bin="${RUSTC:-$HOME/.cargo/bin/rustc}"
rustup_bin="${RUSTUP:-$HOME/.cargo/bin/rustup}"
rust_toolchain="${RUST_TOOLCHAIN:-1.94.0}"
profile="${1:-debug}"

case "$profile" in
	debug) cargo_profile=(--profile dev); cargo_dir=debug ;;
	release) cargo_profile=(--release); cargo_dir=release ;;
	*) echo "usage: $0 [debug|release]" >&2; exit 2 ;;
esac

mkdir -p "$out/bin"
cp "$crate/vrweb_wasm_runtime.gdextension.template" "$out/vrweb_wasm_runtime.gdextension"
cp "$crate/LICENSES.md" "$out/LICENSES.md"

case "$(uname -s)" in
	Darwin)
		"$rustup_bin" target add --toolchain "$rust_toolchain" \
			aarch64-apple-darwin x86_64-apple-darwin
		for target in aarch64-apple-darwin x86_64-apple-darwin; do
			RUSTC="$rustc_bin" "$cargo_bin" build --locked --lib "${cargo_profile[@]}" \
				--target "$target" --manifest-path "$crate/Cargo.toml"
		done
		lipo -create \
			"$crate/target/aarch64-apple-darwin/$cargo_dir/libvrweb_wasm_runtime.dylib" \
			"$crate/target/x86_64-apple-darwin/$cargo_dir/libvrweb_wasm_runtime.dylib" \
			-output "$out/bin/libvrweb_wasm_runtime.dylib"
		;;
	Linux)
		RUSTC="$rustc_bin" "$cargo_bin" build --locked --lib "${cargo_profile[@]}" \
			--manifest-path "$crate/Cargo.toml"
		cp "$crate/target/$cargo_dir/libvrweb_wasm_runtime.so" "$out/bin/"
		;;
	MINGW*|MSYS*|CYGWIN*)
		RUSTC="$rustc_bin" "$cargo_bin" build --locked --lib "${cargo_profile[@]}" \
			--manifest-path "$crate/Cargo.toml"
		cp "$crate/target/$cargo_dir/vrweb_wasm_runtime.dll" "$out/bin/"
		;;
	*) echo "unsupported host platform" >&2; exit 2 ;;
esac

echo "VRWeb WASM runtime installed into $out"
