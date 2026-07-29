#!/bin/bash

set -e

REPOSITORY="Rczlin/Hysteria2EazyInstaller"
CORE_FILE="Hy2InstallerCore.sh"
CORE_URL="https://raw.githubusercontent.com/${REPOSITORY}/refs/heads/main/${CORE_FILE}"

red(){
    echo -e "\033[31m\033[01m$1\033[0m"
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)"
tmp_script="$(mktemp /tmp/hy2-installer.XXXXXX.sh)"

cleanup(){
    rm -f "$tmp_script"
}
trap cleanup EXIT INT TERM

if [[ -f "$script_dir/$CORE_FILE" ]]; then
    cp -f "$script_dir/$CORE_FILE" "$tmp_script"
elif command -v curl >/dev/null 2>&1; then
    curl -fsSL "$CORE_URL" -o "$tmp_script"
elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp_script" "$CORE_URL"
else
    red "需要 curl 或 wget 才能下载安装器核心文件"
    exit 1
fi

# Hysteria 2 官方同时支持 hy2:// 和 hysteria2://。
# 使用 hy2:// 可兼容更多第三方客户端，并按官方结构补上 /?；
# security=tls 不是官方 Hysteria 2 URI 参数，因此移除。
sed -i \
    -e 's#hysteria2://#hy2://#g' \
    -e 's#?security=tls&insecure=#/?insecure=#g' \
    "$tmp_script"

if grep -q 'security=tls' "$tmp_script"; then
    red "Hysteria 2 URI 兼容修正失败：仍检测到 security=tls"
    exit 1
fi

if ! grep -q 'client_url_output="hy2://' "$tmp_script"; then
    red "Hysteria 2 URI 兼容修正失败：未生成 hy2:// 链接"
    exit 1
fi

bash -n "$tmp_script"
chmod +x "$tmp_script"

set +e
bash "$tmp_script" "$@"
status=$?
set -e
exit "$status"
