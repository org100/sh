#!/bin/bash
# =====================================================
# RackNerd 安全 IPv6 / UFW / Docker 端口管理工具
# =====================================================

# ------------------------------
# 菜单显示
# ------------------------------
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

# ------------------------------
# 安全修复 RackNerd IPv6
# ------------------------------
fix_ipv6() {
    echo "[*] 开始安全修复 RackNerd IPv6 配置..."

    SYSCTL_CONF="/etc/sysctl.conf"
    cp "$SYSCTL_CONF" "${SYSCTL_CONF}.bak_$(date +%F_%H-%M-%S)"
    echo "[*] 已备份 $SYSCTL_CONF"

    grep -q "RackNerd IPv6 Fix" "$SYSCTL_CONF" || cat >> "$SYSCTL_CONF" <<EOF

# RackNerd IPv6 Fix
net.ipv6.conf.all.autoconf = 0
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.eth0.autoconf = 0
net.ipv6.conf.eth0.accept_ra = 0
EOF

    echo "[*] 应用 sysctl 配置..."
    sysctl --system >/dev/null 2>&1

    echo "[*] 重启网络服务..."
    systemctl restart networking

    echo "[*] 验证 IPv6 连通性..."
    IPV6_TEST=$(ping6 -c 2 google.com >/dev/null 2>&1 && echo "success" || echo "fail")
    if [ "$IPV6_TEST" = "success" ]; then
        echo "[✓] IPv6 已生效，可以访问外部 IPv6 网络"
        echo "示例命令验证: ping6 google.com && curl ipv6.ip.sb"
    else
        echo "[⚠️] IPv6 配置可能未生效"
        echo "请检查网卡 IPv6 地址: ip -6 addr show eth0"
        echo "检查云平台安全组是否允许 IPv6"
        echo "若依旧无法访问，请尝试重启实例: sudo reboot"
    fi
}

# ------------------------------
# 安装并配置 UFW
# ------------------------------
setup_ufw() {
    if ! command -v ufw >/dev/null 2>&1; then
        echo "[*] 安装 UFW ..."
        apt update && apt install -y ufw
    fi
    systemctl enable ufw >/dev/null 2>&1
    ufw --force enable
}

# ------------------------------
# 普通宿主机端口管理
# ------------------------------
ufw_allow_ports() {
    setup_ufw
    read -p "输入宿主端口（空格分隔）: " ports
    for p in $ports; do
        ufw allow "$p"/tcp
        echo "[*] 端口 $p 已放行"
    done
    ufw reload
    ufw status verbose
}

ufw_delete_ports() {
    setup_ufw
    read -p "输入宿主端口（空格分隔）: " ports
    for p in $ports; do
        ufw delete allow "$p"/tcp
        echo "[*] 端口 $p 已关闭"
    done
    ufw reload
    ufw status verbose
}

ufw_status() {
    echo "========================"
    echo "[*] 当前 UFW 状态:"
    ufw status numbered
    echo "========================"
}

# ------------------------------
# Docker 容器端口外网访问控制
# ------------------------------
docker_allow_ports() {
    setup_ufw
    read -p "输入容器端口（空格分隔）: " ports
    read -p "协议 tcp/udp [tcp]: " proto
    proto=${proto:-tcp}
    for p in $ports; do
        ufw route allow proto "$proto" from any to any port "$p"
        echo "[*] Docker 端口 $p 对外已放行"
    done
    ufw reload
}

docker_deny_ports() {
    setup_ufw
    read -p "输入容器端口（空格分隔）: " ports
    read -p "协议 tcp/udp [tcp]: " proto
    proto=${proto:-tcp}
    for p in $ports; do
        ufw route delete allow proto "$proto" from any to any port "$p"
        echo "[*] Docker 端口 $p 已关闭外网访问"
    done
    ufw reload
}

# ------------------------------
# 主逻辑
# ------------------------------
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
