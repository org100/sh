#!/bin/bash
# =====================================================
# RackNerd 安全 IPv6 / UFW / Docker 工具（Debian 13 发布级）
# =====================================================

UFW_AFTER="/etc/ufw/after.rules"

# -----------------------------------------------------
# 工具函数
# -----------------------------------------------------
get_ipv6_iface() {
    ip -6 route show default 2>/dev/null | awk '{print $5; exit}'
}

# -----------------------------------------------------
# 菜单
# -----------------------------------------------------
show_menu() {
    clear
    echo "================================================="
    echo "       RackNerd 安全 IPv6 / UFW / Docker 工具"
    echo "================================================="
    echo "1) 安全修复 RackNerd IPv6 并验证"
    echo "2) 放行宿主端口（普通 UFW）"
    echo "3) 关闭宿主端口（普通 UFW）"
    echo "4) 查看 UFW 状态"
    echo "5) 允许 Docker 容器端口外网访问"
    echo "6) 关闭 Docker 容器端口外网访问"
    echo "0) 退出"
    echo "================================================="
    read -p "请选择操作 [0-6]: " choice
}

# =====================================================
# 功能 1：安全修复 RackNerd IPv6 并自动验证（已修复）
# =====================================================
fix_ipv6() {
    echo "[*] 开始安全修复 RackNerd IPv6 配置..."

    SYSCTL_CUSTOM="/etc/sysctl.d/99-racknerd-ipv6.conf"
    IFACE=$(get_ipv6_iface)

    if [ -z "$IFACE" ]; then
        echo "[✗] 未检测到 IPv6 默认接口，无法继续"
        return
    fi

    echo "[✓] 检测到 IPv6 接口: $IFACE"

    # 备份旧配置
    if [ -f "$SYSCTL_CUSTOM" ]; then
        cp "$SYSCTL_CUSTOM" "${SYSCTL_CUSTOM}.bak_$(date +%F_%H-%M-%S)"
        echo "[*] 已备份旧 IPv6 配置"
    fi

    # 写入发布级 IPv6 配置
    cat > "$SYSCTL_CUSTOM" <<EOF
# RackNerd IPv6 Fix (Debian 13 Safe)
net.ipv6.conf.all.autoconf = 0
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.${IFACE}.autoconf = 0
net.ipv6.conf.${IFACE}.accept_ra = 0
EOF

    echo "[*] 已写入 IPv6 配置: $SYSCTL_CUSTOM"

    # 应用 sysctl
    echo "[*] 应用 sysctl 配置..."
    sysctl --system >/dev/null

    # 重启网络
    echo "[*] 重启网络服务..."
    systemctl restart networking || true

    # -------------------------
    # 自动验证
    # -------------------------
    echo "[*] 验证 IPv6 状态..."

    sysctl net.ipv6.conf.${IFACE}.autoconf
    ip -6 addr show "$IFACE" | grep inet6 || echo "[!] 接口未检测到 IPv6 地址"

    if ping6 -c 3 google.com >/dev/null 2>&1; then
        echo "[✓] IPv6 ping 测试成功"
    else
        echo "[⚠️] IPv6 ping 测试失败"
    fi

    if curl -6 -s --max-time 5 ipv6.ip.sb >/dev/null 2>&1; then
        echo "[✓] IPv6 curl 测试成功"
    else
        echo "[⚠️] IPv6 curl 测试失败"
    fi

    echo
    echo "[✓] IPv6 安全修复流程完成"
    echo "[*] 如仍异常，建议 reboot 一次实例"
}

# =====================================================
# 功能 2~6：UFW & Docker 管理（未改动）
# =====================================================
setup_ufw() {
    if ! command -v ufw >/dev/null 2>&1; then
        echo "[*] 安装 UFW"
        apt update && apt install -y ufw
    fi
    systemctl enable ufw >/dev/null 2>&1
    ufw --force enable
}

ufw_allow_ports() {
    setup_ufw
    read -p "输入宿主端口（空格分隔）: " ports
    for p in $ports; do
        ufw allow "$p"/tcp
    done
    ufw reload
}

ufw_delete_ports() {
    setup_ufw
    read -p "输入宿主端口（空格分隔）: " ports
    for port in $ports; do
        ufw delete allow "$port"/tcp
    done
    ufw reload
}

ufw_status() {
    ufw status verbose
}

docker_allow_ports() {
    read -p "输入容器端口（空格分隔）: " ports
    read -p "协议 tcp/udp [tcp]: " proto
    proto=${proto:-tcp}
    for p in $ports; do
        ufw route allow proto "$proto" from any to any port "$p"
    done
    ufw reload
}

docker_deny_ports() {
    read -p "输入容器端口（空格分隔）: " ports
    read -p "协议 tcp/udp [tcp]: " proto
    proto=${proto:-tcp}
    for p in $ports; do
        ufw route delete allow proto "$proto" from any to any port "$p"
    done
    ufw reload
}

# =====================================================
# 主逻辑
# =====================================================
show_menu
case "$choice" in
    1) fix_ipv6 ;;
    2) ufw_allow_ports ;;
    3) ufw_delete_ports ;;
    4) ufw_status ;;
    5) docker_allow_ports ;;
    6) docker_deny_ports ;;
    0) exit 0 ;;
    *) echo "无效选项" ;;
esac
