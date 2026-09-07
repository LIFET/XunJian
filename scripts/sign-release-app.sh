#!/bin/zsh
set -euo pipefail

# Sign the staged application inside-out without replacing vendor runtimes.
release_app=${1:?Provide the staged .app path}
release_root=${0:A:h:h}/Release
[[ -d "$release_app" && ! -L "$release_app" ]] || exit 1
release_app=${release_app:A}
[[ "$release_app" == "$release_root"/* && "$release_app" == *.app ]] || exit 1
release_identity='Developer ID Application: X H (76V7CQ4T45)'
release_requirement='anchor apple generic and certificate leaf[subject.OU] = "76V7CQ4T45"'
release_sparkle="$release_app/Contents/Frameworks/Sparkle.framework"
release_targets=(
  "$release_sparkle/Versions/B/Autoupdate"
  "$release_sparkle/Versions/B/Updater.app"
  "$release_sparkle/Versions/B/XPCServices/Downloader.xpc"
  "$release_sparkle/Versions/B/XPCServices/Installer.xpc"
  "$release_sparkle"
  "$release_app/Contents/XPCServices/XunJianOAuthBridge.xpc"
  "$release_app"
)
for release_target in "${release_targets[@]}"; do
  [[ -e "$release_target" && ! -L "$release_target" ]] || exit 1
done
for release_target in "${release_targets[@]}"; do
  /usr/bin/codesign --force --sign "$release_identity" --timestamp --options runtime \
    --preserve-metadata=identifier,entitlements "$release_target"
  /usr/bin/codesign --verify --strict -R="$release_requirement" "$release_target"
  /usr/bin/codesign -dvv "$release_target" 2>&1 | /usr/bin/grep '^Timestamp='
done
/usr/bin/codesign --verify --deep --strict "$release_app"
