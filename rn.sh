#!/bin/bash
# =====================================================
# RackNerd 安全 IPv6 / UFW / Docker 工具
# =====================================================

UFW_AFTER="/etc/ufw/after.rules"

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
# 功能 1：安全修复 RackNerd IPv6 并验证
# =====================================================
fix_ipv6() {
    echo "[*] 开始安全修复 RackNerd IPv6 配置..."

    SYSCTL_CONF="/etc/sysctl.conf"
    CUSTOM_CONF="/etc/sysctl.d/99-racknerd-ipv6.conf"

    # 备份原文件
    if [ -f "$SYSCTL_CONF" ]; then
        cp "$SYSCTL_CONF" "${SYSCTL_CONF}.bak_$(date +%F_%H-%M-%S)"
        echo "[*] 已备份 $SYSCTL_CONF"
    else
        echo "[!] /etc/sysctl.conf 不存在，将使用 $CUSTOM_CONF 创建自定义配置"
    fi

    # 写入 IPv6 配置
    cat > "$CUSTOM_CONF" <<EOF
# RackNerd IPv6 Fix
net.ipv6.conf.all.autoconf = 0
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.eth0.autoconf = 0
net.ipv6.conf.eth0.accept_ra = 0

# 注释可能禁用 IPv6 的配置
# net.ipv6.conf.all.disable_ipv6 = 1
# net.ipv6.conf.default.disable_ipv6 = 1
# net.ipv6.conf.lo.disable_ipv6 = 1
EOF

    echo "[*] 已写入自定义 IPv6 配置到 $CUSTOM_CONF"

    # 应用配置
    echo "[*] 应用 sysctl 配置..."
    sysctl --system

    # 重启网络服务
    echo "[*] 重启网络服务..."
    systemctl restart networking

    # 提示验证
    echo
    echo "[✓] IPv6 配置已应用完成"
    echo "[*] 可通过以下命令验证 IPv6 网络连通性:"
    echo "  ping6 google.com -c 3"
    echo "  curl ipv6.ip.sb"
    echo "[⚠️] 若网络异常，请考虑 reboot 实例"
}

# =====================================================
# 功能 2~6：UFW & Docker 管理
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
