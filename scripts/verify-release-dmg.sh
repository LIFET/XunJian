#!/bin/zsh
set -euo pipefail

release_dmg=${1:?Provide a notarized DMG}
release_arch=${2:?Provide universal, arm64 or x86_64}
[[ -f "$release_dmg" && ! -L "$release_dmg" ]] || exit 1
case "$release_arch" in universal|arm64|x86_64) ;; *) exit 1;; esac
xcrun stapler validate "$release_dmg"
hdiutil verify "$release_dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$release_dmg"
release_mount=$(mktemp -d /tmp/XunJian-release-check.XXXXXX)
[[ -n "$release_mount" && "$release_mount" == /tmp/XunJian-release-check.* && -d "$release_mount" && ! -L "$release_mount" ]] || exit 1
hdiutil attach "$release_dmg" -readonly -nobrowse -mountpoint "$release_mount" >/dev/null
trap 'hdiutil detach "$release_mount" >/dev/null && rmdir "$release_mount"' EXIT
release_app="$release_mount/寻简.app"
[[ $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$release_app/Contents/Info.plist") == 0.1.8 ]]
[[ $(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$release_app/Contents/Info.plist") == 9 ]]
release_bridge="$release_app/Contents/XPCServices/XunJianOAuthBridge.xpc"
[[ $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$release_bridge/Contents/Info.plist") == 0.1.8 ]]
[[ $(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$release_bridge/Contents/Info.plist") == 9 ]]
codesign --verify --deep --strict "$release_app"
spctl --assess --type execute --verbose=2 "$release_app"
for release_binary in "$release_app/Contents/MacOS/寻简" "$release_app/Contents/XPCServices/XunJianOAuthBridge.xpc/Contents/MacOS/XunJianOAuthBridge"; do
  release_actual=$(lipo -archs "$release_binary")
  if [[ "$release_arch" == universal ]]; then
    [[ "$release_actual" == 'x86_64 arm64' || "$release_actual" == 'arm64 x86_64' ]]
  else
    [[ "$release_actual" == "$release_arch" ]]
  fi
done
release_sparkle="$release_app/Contents/Frameworks/Sparkle.framework"
for release_target in "$release_app" "$release_bridge" "$release_sparkle" "$release_sparkle/Versions/B/Autoupdate" "$release_sparkle/Versions/B/Updater.app" "$release_sparkle/Versions/B/XPCServices/Downloader.xpc" "$release_sparkle/Versions/B/XPCServices/Installer.xpc"; do
  codesign --verify --strict -R='anchor apple generic and certificate leaf[subject.OU] = "76V7CQ4T45"' "$release_target"
  codesign -dvv "$release_target" 2>&1 | grep '^Timestamp='
done
release_resources="$release_app/Contents/XPCServices/XunJianOAuthBridge.xpc/Contents/Resources"
for release_runtime_arch in arm64 x86_64; do
  codesign --verify --strict -R='anchor apple generic and identifier "codex-app-server" and certificate leaf[subject.OU] = "2DC432GLL2"' "$release_resources/CodexAppServer/$release_runtime_arch/codex-app-server"
  codesign --verify --strict -R='anchor apple generic and identifier "xai-grok-pager" and certificate leaf[subject.OU] = "5Y6N3AJ54S"' "$release_resources/GrokRuntime/$release_runtime_arch/grok"
done
stat -f 'size=%z' "$release_dmg"
shasum -a 256 "$release_dmg"
