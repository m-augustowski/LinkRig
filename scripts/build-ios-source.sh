#!/bin/sh
# Independent compiler check when Xcode's SwiftPM manifest sandbox cannot run.
# Builds an unsigned arm64 iOS executable and typechecks test sources; never installs or runs.
set -eu
cd "$(dirname "$0")/.."
build_dir="${RIG_IOS_BUILD_DIR:-/tmp/connectionrig-ios-source}"
mkdir -p "$build_dir"
sdk_path=$(xcrun --sdk iphoneos --show-sdk-path)
developer_path=$(xcode-select -p)
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/connectionrig-clang}"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
swift build --disable-sandbox --scratch-path "$build_dir/package" --target ConnectionRig --triple arm64-apple-ios17.0 --sdk "$sdk_path" -j 4
module_dir="$build_dir/package/arm64-apple-ios/debug/Modules"
xcrun --sdk iphoneos swiftc -disable-sandbox -swift-version 6 -sdk "$sdk_path" -target arm64-apple-ios17.0 -parse-as-library -enable-testing -module-name DownloadLab -emit-module -emit-module-path "$build_dir/DownloadLab.swiftmodule" -emit-executable Examples/DownloadLab/Sources/App.swift Examples/DownloadLab/Sources/DownloadModel.swift -o "$build_dir/DownloadLab"
xcrun --sdk iphoneos swiftc -disable-sandbox -swift-version 6 -sdk "$sdk_path" -target arm64-apple-ios17.0 -plugin-path "$developer_path/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing" -typecheck -module-name DownloadLabTests -I "$build_dir" -I "$module_dir" -I "$developer_path/Platforms/iPhoneOS.platform/Developer/usr/lib" -F "$developer_path/Platforms/iPhoneOS.platform/Developer/Library/Frameworks" Examples/DownloadLab/Tests/DeviceTests.swift
xcrun --sdk iphoneos swiftc -disable-sandbox -swift-version 6 -sdk "$sdk_path" -target arm64-apple-ios17.0 -typecheck -module-name DownloadLabUITests -I "$module_dir" -I "$developer_path/Platforms/iPhoneOS.platform/Developer/usr/lib" -F "$developer_path/Platforms/iPhoneOS.platform/Developer/Library/Frameworks" Examples/DownloadLab/UITests/DownloadFlowUITests.swift
