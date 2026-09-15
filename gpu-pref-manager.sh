#!/bin/bash

# ============================================
# 脚本名称：gpu-pref-manager.sh
# 功能：批量管理应用的「偏好非默认 GPU」标记
#       基于 freedesktop 标准 key：PrefersNonDefaultGPU
# 特色：不生成包装器、不改 Exec，只写一行标准标记
# 依赖：zenity（仅图形界面需要）
# 适用：GNOME 50+ / KDE Plasma 等支持该 key 的桌面
# ============================================

# ============================================
# 全局配置（可修改）
# ============================================

PROG_NAME="gpu-pref-manager"
VERSION="1.0.0"

# 用户级 desktop 目录（脚本只会写这里）
USER_APPS="${HOME}/.local/share/applications"
# 系统级 desktop 目录（只读，绝不修改）
SYSTEM_APPS="/usr/share/applications"

# freedesktop Desktop Entry Spec 1.4 定义的标准 key
KEY="PrefersNonDefaultGPU"

# 临时目录（退出时自动清理）
TEMP_DIR=$(mktemp -d)

# ============================================
# 以下代码无需修改
# ============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 本脚本用到 globstar 等 bash 4.0+ 特性
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
    echo "错误: 需要 bash 4.0 或更高版本（当前 ${BASH_VERSION:-未知}）" >&2
    exit 1
fi

cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# --------------------------------------------
# 基础检查
# --------------------------------------------

check_display() {
    if [ -z "$DISPLAY" ] && [ -z "$WAYLAND_DISPLAY" ]; then
        echo -e "${RED}错误: 未检测到图形界面${NC}"
        echo "请改用命令行模式，例如：${PROG_NAME} --list"
        exit 1
    fi
}

check_dependencies() {
    if ! command -v zenity &> /dev/null; then
        local install_cmd=""
        if command -v dnf &> /dev/null; then
            install_cmd="sudo dnf install zenity"
        elif command -v apt &> /dev/null; then
            install_cmd="sudo apt install zenity"
        elif command -v pacman &> /dev/null; then
            install_cmd="sudo pacman -S zenity"
        fi
        echo -e "${RED}错误: 缺少 zenity${NC}"
        echo "安装方法: $install_cmd"
        exit 1
    fi
}

# 检测当前桌面是否支持这个 key
detect_support() {
    # GNOME：检查 gnome-shell 二进制里是否有该字符串
    local lib
    for lib in /usr/bin/gnome-shell /usr/lib64/gnome-shell/libshell-*.so /usr/lib/gnome-shell/libshell-*.so; do
        [ -e "$lib" ] || continue
        if grep -qa "$KEY" "$lib" 2>/dev/null; then
            echo "gnome"
            return 0
        fi
    done

    # KDE：kglobalaccel/kservice 相关库
    for lib in /usr/lib64/libKF[0-9]*KService.so* /usr/lib/libKF[0-9]*KService.so*; do
        [ -e "$lib" ] || continue
        if grep -qa "$KEY" "$lib" 2>/dev/null; then
            echo "kde"
            return 0
        fi
    done

    # 通用回退：检查 GIO（虽然目前 GIO 不支持，留作将来）
    if grep -qa "$KEY" /usr/lib64/libgio-2.0.so.0 2>/dev/null; then
        echo "gio"
        return 0
    fi

    echo "unknown"
    return 1
}

# --------------------------------------------
# 应用扫描
# --------------------------------------------

# 列出所有可配置的桌面应用
# 每行输出: 显示名<TAB>desktop路径<TAB>on|off
collect_apps() {
    # globstar: 让 ** 递归子目录（GLib 也会扫描子目录，
    # desktop ID 形如 子目录名-文件名）
    shopt -s nullglob globstar
    local files=("$USER_APPS"/**/*.desktop "$SYSTEM_APPS"/**/*.desktop)
    shopt -u nullglob globstar

    [ ${#files[@]} -eq 0 ] && return 0

    awk '
        function flush() {
            if (name != "" && ex != "" && nodisp != "true" && !(base in seen)) {
                seen[base] = 1
                if (name in used) {
                    used[name]++
                    name = name " (" used[name] ")"
                } else {
                    used[name] = 1
                }
                printf "%s\t%s\t%s\n", name, file, pref
            }
        }
        FNR == 1 {
            flush()
            name = ""; ex = ""; nodisp = ""; pref = "off"
            file = FILENAME
            base = FILENAME; sub(/.*\//, "", base)
        }
        /^Name=/                 && name == "" { name = substr($0, 6) }
        /^Exec=/                 && ex   == "" { ex   = substr($0, 6) }
        /^NoDisplay=/                           { nodisp = substr($0, 11) }
        /^PrefersNonDefaultGPU=/ {
            v = substr($0, 22)
            gsub(/[ \t\r]/, "", v)
            pref = (tolower(v) == "true") ? "on" : "off"
        }
        END { flush() }
    ' "${files[@]}" | sort
}

# 统计: 输出 "已标记数量 未标记数量"
count_apps() {
    local on=0 off=0 st
    while IFS=$'\t' read -r _ _ st; do
        [ -z "$st" ] && continue
        if [ "$st" = "on" ]; then on=$((on + 1)); else off=$((off + 1)); fi
    done < <(collect_apps)
    echo "$on $off"
}

# --------------------------------------------
# 核心操作
# --------------------------------------------

# 为应用设置或移除标记
# 用法: set_pref <desktop路径> on|off
set_pref() {
    local src="$1" want="$2"
    local base target

    if [[ "$src" == "$USER_APPS"/* ]]; then
        # 已在用户级目录（含子目录）→ 原地修改，避免产生重复条目
        target="$src"
    else
        # 系统级 → 复制到用户级根目录（用户级优先，系统文件保持原样）
        base=$(basename "$src")
        target="$USER_APPS/$base"
        if [ ! -f "$target" ]; then
            mkdir -p "$USER_APPS"
            cp "$src" "$target" 2>/dev/null || return 1
        fi
    fi

    [ -f "$target" ] || return 1

    # 1) 先移除已有的标记行（无论值是什么）
    sed -i "/^${KEY}=/d" "$target" 2>/dev/null || return 1

    # 2) 需要时重新插入到 [Desktop Entry] 段内
    #    （必须插在段内，追加到文件末尾会落进 [Desktop Action …] 段而失效）
    if [ "$want" = "on" ]; then
        if ! grep -q '^\[Desktop Entry\]' "$target"; then
            return 1
        fi
        sed -i "/^\[Desktop Entry\]/a ${KEY}=true" "$target" 2>/dev/null || return 1
    fi

    return 0
}

update_cache() {
    if command -v update-desktop-database &> /dev/null; then
        update-desktop-database "$USER_APPS" &> /dev/null
    fi
    return 0
}

# --------------------------------------------
# 命令行模式
# --------------------------------------------

usage_cli() {
    cat <<EOF
${PROG_NAME} v${VERSION} — 批量管理应用的「偏好非默认 GPU」标记

用法:
  ${PROG_NAME} [选项]

不带选项时启动图形界面。

选项:
  -h, --help            显示本帮助
  -V, --version         显示版本
  -l, --list            列出已标记的应用
  -a, --all             列出全部可配置应用及其标记状态
      --on  <应用...>   为指定应用加上标记
      --off <应用...>   移除指定应用的标记
      --check           检查桌面环境是否支持该标记

「应用」可以是 desktop 文件名（可省略 .desktop）

示例:
  ${PROG_NAME} --list
  ${PROG_NAME} --on steam hmcl
  ${PROG_NAME} --off steam
  ${PROG_NAME} --check

原理:
  往应用的 .desktop 文件里写入 freedesktop 标准键
  ${KEY}=true
  桌面环境读取后，从启动器启动该应用时会自动 offload 到独显。
  只写 ~/.local/share/applications/，系统文件不受影响。
EOF
}

# 把用户输入的应用名解析为 desktop 路径
resolve_app() {
    local name="$1" d f
    [ -f "$name" ] && { printf '%s\n' "$name"; return 0; }
    case "$name" in *.desktop) ;; *) name="$name.desktop" ;; esac
    for d in "$USER_APPS" "$SYSTEM_APPS"; do
        [ -f "$d/$name" ] && { printf '%s\n' "$d/$name"; return 0; }
    done
    f=$(find "$USER_APPS" "$SYSTEM_APPS" -maxdepth 2 -name "$name" 2>/dev/null | head -1)
    [ -n "$f" ] && { printf '%s\n' "$f"; return 0; }
    return 1
}

cli_list() {
    local n=0 name path st
    while IFS=$'\t' read -r name path st; do
        [ -z "$name" ] && continue
        [ "$st" = "on" ] || continue
        n=$((n + 1))
        printf "  %-34s (%s)\n" "$name" "$(basename "$path")"
    done < <(collect_apps)
    if [ "$n" -eq 0 ]; then
        echo "  （没有应用被标记为偏好非默认 GPU）"
    else
        echo
        echo "共 $n 个应用已标记。"
    fi
}

cli_all() {
    local name path st
    while IFS=$'\t' read -r name path st; do
        [ -z "$name" ] && continue
        if [ "$st" = "on" ]; then
            printf "  [x] %-38s %s\n" "$name" "$(basename "$path")"
        else
            printf "  [ ] %-38s %s\n" "$name" "$(basename "$path")"
        fi
    done < <(collect_apps)
}

cli_check() {
    echo "环境检查"
    echo "  脚本版本 : ${PROG_NAME} v${VERSION}"
    echo "  bash     : $BASH_VERSION"
    echo "  标准键   : ${KEY}"
    echo
    printf "  zenity   : "
    command -v zenity > /dev/null 2>&1 && echo "✅ $(command -v zenity)" || echo "❌ 未安装（图形界面不可用）"
    printf "  更新缓存 : "
    command -v update-desktop-database > /dev/null 2>&1 && echo "✅ 可用" || echo "⚠️  缺失（不影响功能）"
    printf "  用户目录 : "
    [ -d "$USER_APPS" ] && echo "✅ $USER_APPS" || echo "⚠️  不存在（首次写入时自动创建）"
    echo
    printf "  桌面支持 : "
    case "$(detect_support)" in
        gnome)
            echo "✅ GNOME（gnome-shell 已实现该 key）"
            echo "             从应用网格启动时生效；右键菜单会显示反向选项"
            ;;
        kde)
            echo "✅ KDE（KService 已实现该 key）"
            ;;
        gio)
            echo "✅ GLib/GIO（文件关联启动也可生效）"
            ;;
        *)
            echo "⚠️  未能确认当前桌面支持该 key"
            echo "             要求 GNOME 50+ 或 KDE Plasma；"
            echo "             旧版桌面可能忽略该标记。"
            echo "             可用 ${PROG_NAME} --list 先写入，升级桌面后自动生效。"
            ;;
    esac
    echo
    local counts on off
    counts=$(count_apps)
    on="${counts%% *}"
    off="${counts##* }"
    echo "  应用统计 : 共 $((on + off)) 个可配置，其中 $on 个已标记"
}

# --------------------------------------------
# 图形界面
# --------------------------------------------

show_help() {
    local support_note
    case "$(detect_support)" in
        gnome|kde|gio) support_note="当前桌面：<b>已支持</b>该标记" ;;
        *)             support_note="⚠️ 当前桌面<b>未能确认支持</b>该标记（需 GNOME 50+ 或 KDE）" ;;
    esac

    zenity --info \
        --title="使用说明" \
        --width=640 --height=600 \
        --text="<b>这个脚本做什么</b>\n\n\
批量给应用加上「偏好非默认 GPU」标记，\n\
标记后从启动器启动该应用时会自动使用独显。\n\n\
<b>原理</b>\n\n\
往应用的 .desktop 文件里写一行标准键：\n\
<tt>${KEY}=true</tt>\n\
这是 freedesktop Desktop Entry 规范 1.4 定义的，\n\
GNOME 与 KDE 都会读取。\n\n\
<b>与「改 Exec」方案的区别</b>\n\n\
  • 不生成任何包装器，不修改 Exec\n\
  • 完全依赖桌面环境原生支持\n\
  • 无法指定具体是哪一块显卡（只能表达「非默认」）\n\n\
<b>安全性</b>\n\n\
  • 只写 ${USER_APPS}\n\
  • 系统目录 ${SYSTEM_APPS} 不会被改动\n\
  • 取消勾选即恢复原样\n\n\
<b>注意</b>\n\n\
改完需要<b>重启对应应用</b>；\n\
部分桌面环境可能需要注销重登才刷新应用信息。\n\n\
${support_note}"
}

# 勾选式批量管理
do_manage() {
    local rows=() name path st count=0 on_count=0
    while IFS=$'\t' read -r name path st; do
        [ -z "$name" ] && continue
        count=$((count + 1))
        if [ "$st" = "on" ]; then
            on_count=$((on_count + 1))
            rows+=(TRUE "$name" "已标记")
        else
            rows+=(FALSE "$name" "默认")
        fi
    done < <(collect_apps)

    if [ "$count" -eq 0 ]; then
        zenity --error --width=380 --title="没有可用应用" \
            --text="没有找到可配置的桌面应用。"
        return
    fi

    local selected
    selected=$(zenity --list --checklist \
        --title="偏好独显的应用（共 ${count} 个，已标记 ${on_count} 个）" \
        --text="<b>勾选</b> = 偏好非默认 GPU（通常是独显）\n<b>不勾选</b> = 使用默认 GPU\n\n选好后点「应用更改」" \
        --column="偏好独显" --column="应用" --column="当前状态" \
        --width=820 --height=640 \
        --separator="|" \
        --ok-label="应用更改" \
        --cancel-label="返回" \
        "${rows[@]}" 2>/dev/null)
    [ $? -ne 0 ] && return

    # 解析勾选结果
    local -A want
    local -a sel_arr=()
    local oldifs="$IFS"
    IFS='|' read -r -a sel_arr <<< "$selected"
    IFS="$oldifs"
    local s
    for s in "${sel_arr[@]}"; do
        [ -n "$s" ] && want["$s"]=1
    done

    # 只处理状态发生变化的
    local -a todo=()
    local target
    while IFS=$'\t' read -r name path st; do
        [ -z "$name" ] && continue
        target="off"
        [ -n "${want[$name]:-}" ] && target="on"
        [ "$st" != "$target" ] && todo+=("${path}|${target}")
    done < <(collect_apps)

    if [ ${#todo[@]} -eq 0 ]; then
        zenity --info --width=360 --title="没有变化" \
            --text="配置没有发生变化。"
        return
    fi

    # 变更摘要 + 二次确认（防止误操作把标记全清空）
    local summary="" item p m nm
    for item in "${todo[@]}"; do
        p="${item%|*}"
        m="${item##*|}"
        nm=$(basename "$p" .desktop)
        if [ "$m" = "on" ]; then
            summary+="   ${nm}  →  偏好独显\n"
        else
            summary+="   ${nm}  →  恢复默认\n"
        fi
    done

    local preview
    if [ ${#todo[@]} -gt 15 ]; then
        preview=$(printf '%b' "$summary" | head -15)
        preview+="\n   … 其余 $(( ${#todo[@]} - 15 )) 个省略"
    else
        preview=$(printf '%b' "$summary")
    fi

    if ! zenity --question \
        --width=600 --height=520 \
        --title="确认更改" \
        --text="即将修改 <b>${#todo[@]}</b> 个应用：\n\n${preview}\n\n确定继续吗？" \
        --ok-label="确认执行" \
        --cancel-label="取消"; then
        return
    fi

    local ok=0 fail=0
    for item in "${todo[@]}"; do
        p="${item%|*}"
        m="${item##*|}"
        if set_pref "$p" "$m"; then
            ok=$((ok + 1))
        else
            fail=$((fail + 1))
        fi
    done
    update_cache

    local msg="✅ 已更新 <b>${ok}</b> 个应用"
    if [ "$fail" -gt 0 ]; then
        msg+="\n\n⚠️ 有 <b>${fail}</b> 个失败（可能是权限问题）"
    fi
    msg+="\n\n<b>重启对应应用</b>后生效；\n若启动器未刷新，注销重登一次。"

    zenity --info --width=460 --title="完成" --text="$msg"
}

# 查看当前配置
do_view() {
    local name path st
    local lines=""
    local on=0 off=0

    while IFS=$'\t' read -r name path st; do
        [ -z "$name" ] && continue
        if [ "$st" = "on" ]; then
            on=$((on + 1))
            lines+="   ${on}. ${name}\n"
        else
            off=$((off + 1))
        fi
    done < <(collect_apps)

    local text="<b>偏好非默认 GPU 的应用</b>\n\n"
    if [ "$on" -eq 0 ]; then
        text+="<b>暂无</b>\n"
    else
        text+="${lines}"
    fi
    text+="\n共 <b>${on}</b> 个已标记，其余 <b>${off}</b> 个使用默认 GPU。"
    text+="\n\n💡 标记内容：<tt>${KEY}=true</tt>"

    zenity --info \
        --title="当前配置" \
        --width=620 --height=560 \
        --text="$text"
}

# 主菜单
main_menu() {
    zenity --list --radiolist \
        --title="GPU 偏好管理" \
        --text="批量管理应用的「偏好非默认 GPU」标记" \
        --column="选择" --column="操作" --column="说明" \
        --width=720 --height=400 \
        --ok-label="确定" \
        --cancel-label="退出" \
        TRUE  "批量管理"     "勾选式设置哪些应用偏好独显" \
        FALSE "查看当前配置" "列出已标记的应用" \
        FALSE "使用说明"     "原理、与改 Exec 方案的区别" \
        FALSE "退出"         "关闭窗口" 2>/dev/null
}

# --------------------------------------------
# 主程序
# --------------------------------------------

main() {
    # 命令行模式：不需要图形界面
    case "${1:-}" in
        -h|--help)    usage_cli; exit 0 ;;
        -V|--version) echo "${PROG_NAME} ${VERSION}"; exit 0 ;;
        -l|--list)    cli_list;  exit 0 ;;
        -a|--all)     cli_all;   exit 0 ;;
        --check)      cli_check; exit 0 ;;
        --on|--off)
            local mode="$1"; shift
            [ $# -gt 0 ] || { echo "错误: $mode 需要至少一个应用名" >&2; exit 2; }
            local want="on"
            [ "$mode" = "--off" ] && want="off"
            local app path ok=0 fail=0
            for app in "$@"; do
                if path=$(resolve_app "$app"); then
                    if set_pref "$path" "$want"; then
                        printf "  %-8s %s\n" "✅" "$(basename "$path")"
                        ok=$((ok + 1))
                    else
                        printf "  %-8s %s（写入失败）\n" "❌" "$(basename "$path")"
                        fail=$((fail + 1))
                    fi
                else
                    printf "  %-8s %s（未找到）\n" "❌" "$app"
                    fail=$((fail + 1))
                fi
            done
            update_cache
            echo
            echo "完成：成功 ${ok} 个，失败 ${fail} 个"
            [ "$fail" -gt 0 ] && exit 1
            exit 0
            ;;
        "")  ;;
        *)   echo "未知参数: $1" >&2; echo; usage_cli >&2; exit 2 ;;
    esac

    check_display
    check_dependencies

    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  GPU 偏好管理 (${PROG_NAME} v${VERSION})${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "标准键    : ${YELLOW}${KEY}${NC}"
    echo -e "用户目录  : ${YELLOW}${USER_APPS}${NC}"

    case "$(detect_support)" in
        gnome) echo -e "桌面支持  : ${GREEN}✅ GNOME${NC}" ;;
        kde)   echo -e "桌面支持  : ${GREEN}✅ KDE${NC}" ;;
        gio)   echo -e "桌面支持  : ${GREEN}✅ GLib/GIO${NC}" ;;
        *)     echo -e "桌面支持  : ${YELLOW}⚠️  未能确认（需 GNOME 50+ 或 KDE）${NC}" ;;
    esac

    local counts on off
    counts=$(count_apps)
    on="${counts%% *}"
    off="${counts##* }"
    echo -e "应用统计  : ${YELLOW}$((on + off))${NC} 个可配置，${GREEN}${on}${NC} 个已标记"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    while true; do
        local choice
        choice=$(main_menu)
        [ $? -ne 0 ] && break
        [ -z "$choice" ] && break

        case "$choice" in
            "批量管理")       do_manage ;;
            "查看当前配置")   do_view ;;
            "使用说明")       show_help ;;
            "退出")           break ;;
        esac
    done
}

main "$@"
