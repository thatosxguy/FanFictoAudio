#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
export CLANG_MODULE_CACHE_PATH="$project_root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$project_root/.build/module-cache"
extra_args=()
# The native engine also supports Command Line Tools installations without Xcode.
build_help="$(swift build --help)"
if [[ "${1:-}" == "build" && "$build_help" == *"native            - Native Build System"* ]]; then
    extra_args+=(--build-system native)
fi
if [[ "${1:-}" == "test" ]]; then
    extra_args+=(--disable-xctest)
    toolchain_bin="$(dirname "$(xcrun --find swiftc)")"
    testing_plugins="$toolchain_bin/../lib/swift/host/plugins/testing"
    if [[ -d "$testing_plugins" && -x "$toolchain_bin/swift-plugin-server" ]]; then
        extra_args+=(-Xswiftc -external-plugin-path -Xswiftc "$testing_plugins#$toolchain_bin/swift-plugin-server")
    fi
fi
swift "$@" "${extra_args[@]}" --disable-sandbox --cache-path "$project_root/.build/cache" --config-path "$project_root/.build/config" --security-path "$project_root/.build/security"
