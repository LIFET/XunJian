#!/bin/zsh

set -euo pipefail

project_root="${SRCROOT:-${0:A:h:h}}"

verify_runtime() {
    local relative_path="$1"
    local expected_size="$2"
    local expected_architecture="$3"
    local expected_digest="$4"
    local signing_identifier="$5"
    local team_identifier="$6"
    local runtime_path="${project_root}/${relative_path}"

    if [[ ! -f "$runtime_path" || -L "$runtime_path" ]]; then
        print -u2 -- "error: 缺少安全的内置 OAuth Runtime：${relative_path}"
        return 1
    fi

    local actual_size
    actual_size=$(/usr/bin/stat -f '%z' "$runtime_path")
    if [[ "$actual_size" != "$expected_size" ]]; then
        if /usr/bin/head -n 1 "$runtime_path" 2>/dev/null \
            | /usr/bin/grep -Fq 'version https://git-lfs.github.com/spec/v1'; then
            print -u2 -- "error: ${relative_path} 仍是 Git LFS 指针。请先执行 git lfs pull 或 git lfs checkout，再重新构建。"
        else
            print -u2 -- "error: ${relative_path} 大小异常（${actual_size}，期望 ${expected_size}）。"
        fi
        return 1
    fi

    if [[ ! -x "$runtime_path" ]]; then
        print -u2 -- "error: ${relative_path} 缺少可执行权限。"
        return 1
    fi

    local actual_architecture
    actual_architecture=$(/usr/bin/lipo -archs "$runtime_path")
    if [[ "$actual_architecture" != "$expected_architecture" ]]; then
        print -u2 -- "error: ${relative_path} 架构为 ${actual_architecture}，期望 ${expected_architecture}。"
        return 1
    fi

    local actual_digest
    actual_digest=$(/usr/bin/shasum -a 256 "$runtime_path" | /usr/bin/awk '{print $1}')
    if [[ "$actual_digest" != "$expected_digest" ]]; then
        print -u2 -- "error: ${relative_path} SHA-256 不匹配。"
        return 1
    fi

    local requirement
    requirement="anchor apple generic and identifier \"${signing_identifier}\" and certificate leaf[subject.OU] = \"${team_identifier}\""
    if ! /usr/bin/codesign --verify --strict --verbose=0 -R="$requirement" "$runtime_path"; then
        print -u2 -- "error: ${relative_path} 未通过官方 Developer ID 签名校验。"
        return 1
    fi
}

verify_runtime \
    'XunJianOAuthBridge/Resources/CodexAppServer/arm64/codex-app-server' \
    '182846768' 'arm64' \
    'b1a7e99d3dba6cef9bb3785097321041a6b6594600a520bb320a9d80b35fd65c' \
    'codex-app-server' '2DC432GLL2'
verify_runtime \
    'XunJianOAuthBridge/Resources/CodexAppServer/x86_64/codex-app-server' \
    '196617296' 'x86_64' \
    'f0da5ac98055516180a480bafd684f6003df1ad64a07c99006389f1e07e2ef3c' \
    'codex-app-server' '2DC432GLL2'
verify_runtime \
    'XunJianOAuthBridge/Resources/GrokRuntime/arm64/grok' \
    '131817232' 'arm64' \
    '13c7f4f0b9abb00bf38216302ea4bab31f03e13555e3576620eca1de572a8d21' \
    'xai-grok-pager' '5Y6N3AJ54S'
verify_runtime \
    'XunJianOAuthBridge/Resources/GrokRuntime/x86_64/grok' \
    '147358000' 'x86_64' \
    'a82210a961deac9f0cb72ec6c334196abf76a587be4593bc59db2deab85ee6dc' \
    'xai-grok-pager' '5Y6N3AJ54S'
