#!/usr/bin/env bash
# ============================================
# gpu-pref-manager 安装脚本
#
# 用法:
#   ./install.sh                              装到 ~/.local/bin
#   ./install.sh --prefix /usr/local/bin      自定义位置
# ============================================

set -euo pipefail

SCRIPT_NAME="gpu-pref-manager"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SRC_DIR}/${SCRIPT_NAME}.sh"
BIN_DIR="${HOME}/.local/bin"

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)
            [ -n "${2:-}" ] || { echo "错误: --prefix 需要一个目录参数" >&2; exit 2; }
            BIN_DIR="$2"
            shift 2
            ;;
        -h|--help)
            cat <<EOF
用法: $(basename "$0") [--prefix <安装目录>]

把 ${SCRIPT_NAME} 安装到 <安装目录>（默认 ~/.local/bin）。
EOF
            exit 0
            ;;
        *)
            echo "未知参数: $1" >&2
            exit 2
            ;;
    esac
done

if [ ! -f "$SRC" ]; then
    echo "错误: 找不到 ${SCRIPT_NAME}.sh" >&2
    echo "请在解压后的目录内运行本脚本。" >&2
    exit 1
fi

if ! command -v zenity > /dev/null 2>&1; then
    echo "⚠️  未检测到 zenity，图形界面无法启动（命令行模式仍可用）。"
    echo "   安装方法（按发行版选择）："
    echo "     Fedora        sudo dnf install zenity"
    echo "     Debian/Ubuntu sudo apt install zenity"
    echo "     Arch          sudo pacman -S zenity"
    echo
fi

mkdir -p "$BIN_DIR"
install -m 755 "$SRC" "${BIN_DIR}/${SCRIPT_NAME}"
echo "✅ 已安装: ${BIN_DIR}/${SCRIPT_NAME}"

case ":${PATH}:" in
    *":${BIN_DIR}:"*)
        ;;
    *)
        echo
        echo "⚠️  ${BIN_DIR} 不在 PATH 中，请把下面这行加进 ~/.bashrc 或 ~/.zshrc："
        echo "     export PATH=\"${BIN_DIR}:\$PATH\""
        ;;
esac

echo
echo "接下来："
echo "  ${SCRIPT_NAME}            # 打开图形界面"
echo "  ${SCRIPT_NAME} --check    # 检查桌面是否支持"
echo "  ${SCRIPT_NAME} --list     # 查看已标记的应用"
echo
echo "原理：往 .desktop 写入一行标准键 PrefersNonDefaultGPU=true"
