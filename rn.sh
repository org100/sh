#!/bin/bash
# ===============================================
# RackNerd IPv6 / Docker / UFW 全功能修复工具
# ===============================================

# ------------------------------
# 自动检测默认网卡
# ------------------------------
IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -n1)

# ------------------------------
# 自动获取主机 IPv6 前缀
# ------------------------------
IPV6_PREFIX=$(ip -6 addr show "$IFACE" scope global | awk '{print $2}' | head -n1 | cut -d':' -f1-4)
IPV6_CUSTOM="$IPV6_PREFIX::$(printf "%x:%x" $RANDOM $RANDOM)"
IPV6_GATEWAY=$(ip -6 route show default | awk '/default/ {print $3}' | head -n1)

# Docker 配置文件
DOCKER_CONF="/etc/docker/daemon.json"

# 获取 SSH 端口
SSH_PORT=$(ss -tnlp | grep sshd | awk '{print $4}' | awk -F':' '{print $NF}' | head -n1)

# ------------------------------
# 菜单显示
# ------------------------------
show_menu() {
    echo "=============================================="
    echo "RackNerd IPv6 / Docker / UFW 全功能修复工具"
    echo "=============================================="
    echo "1) 一键修复 RackNerd IPv6 并配置 UFW 与 Docker（清空 DOCKER 链）"
    echo "2) 放行指定 UFW 端口（多个端口空格分开）"
    echo "3) 关闭指定 UFW 端口（多个端口空格分开）"
    echo "4) 展示 UFW 端口防火墙状态"
    echo "0) 退出"
    echo "=============================================="
    read -p "请选择操作 [0-4]: " choice
}

# ------------------------------
# 函数：修复 IPv6 + Docker + 清空 DOCKER 链
# ------------------------------
fix_ipv6_docker() {
    echo "[*] 修复 RackNerd IPv6 ..."

    # 备份 interfaces
    cp /etc/network/interfaces "/etc/network/interfaces.bak_$(date +%F_%T)"
    echo "[*] 已备份 interfaces 文件"

    # 写入自定义 IPv6
    if grep -q "$IPV6_CUSTOM" /etc/network/interfaces; then
        echo "[*] 自定义 IPv6 已存在，跳过写入。"
    else
        cat >> /etc/network/interfaces <<EOF

# =========================
# RN 自定义 IPv6
auto $IFACE
iface $IFACE inet6 static
    address $IPV6_CUSTOM
    netmask 64
    gateway $IPV6_GATEWAY
# =========================
EOF
        echo "[*] 自定义 IPv6 已写入 interfaces 文件"
    fi

    echo "[⚠️] 注意：使用 ifdown/ifup 会断开远程 SSH 连接"
    read -p "确认继续？输入 y 回车继续: " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        echo "[*] 执行 ifdown/ifup 彻底刷新 IPv6 ..."
        ifdown $IFACE && ifup $IFACE
    else
        echo "[!] 已取消 ifdown/ifup，可手动刷新 IPv6"
    fi

    # ------------------------------
    # 配置 Docker 支持 IPv6
    # ------------------------------
    echo "[*] 配置 Docker 支持 IPv6 ..."
    DOCKER_JSON_CONTENT=$(cat <<EOF
{
  "ipv6": true,
  "fixed-cidr-v6": "$IPV6_PREFIX::/64",
  "iptables": false
}
EOF
)

    echo "$DOCKER_JSON_CONTENT" > $DOCKER_CONF
    echo "[*] Docker daemon.json 已更新为 IPv6 可用"

    # 清空 Docker 链
    echo "[*] 清空 Docker 链规则（IPv4/IPv6）..."
    iptables -F DOCKER-USER 2>/dev/null
    iptables -F DOCKER 2>/dev/null
    ip6tables -F DOCKER-USER 2>/dev/null
    ip6tables -F DOCKER-FORWARD 2>/dev/null

    # 重启 Docker
    echo "[*] 重启 Docker ..."
    systemctl restart docker
    systemctl status docker --no-pager

    echo "[✓] IPv6 + Docker 链修复完成，容器现在应可访问外部网络"
}

# ------------------------------
# 函数：安装并配置 UFW
# ------------------------------
setup_ufw() {
    if ! command -v ufw &>/dev/null; then
        echo "[*] 安装 UFW ..."
        apt update && apt install -y ufw
    fi

    systemctl enable ufw
    ufw --force enable
}

# ------------------------------
# 函数：一键修复 IPv6 + Docker + UFW
# ------------------------------
onekey_fix() {
    fix_ipv6_docker
    setup_ufw

    # 放行常用端口
    echo "[*] 放行 SSH、HTTP/HTTPS 等端口"
    ufw allow "$SSH_PORT"/tcp
    ufw allow 80/tcp
    ufw allow 81/tcp
    ufw allow 443/tcp
    ufw reload

    echo "[✓] 一键修复完成"
    ufw status verbose
}

# ------------------------------
# 函数：放行用户指定端口
# ------------------------------
ufw_allow_ports() {
    setup_ufw
    read -p "请输入要放行的端口（空格分隔）: " ports
    for p in $ports; do
        ufw allow "$p"/tcp
        echo "[*] 端口 $p 已放行"
    done
    ufw reload
    ufw status verbose
}

# ------------------------------
# 函数：关闭用户指定端口
# ------------------------------
ufw_deny_ports() {
    setup_ufw
    read -p "请输入要关闭的端口（空格分隔）: " ports
    for p in $ports; do
        ufw deny "$p"/tcp
        echo "[*] 端口 $p 已关闭"
    done
    ufw reload
    ufw status verbose
}

# ------------------------------
# 函数：展示 UFW 状态
# ------------------------------
ufw_status() {
    echo "========================"
    echo "[*] 当前 UFW 状态:"
    ufw status numbered
    echo "========================"
}

# ------------------------------
# 主逻辑
# ------------------------------
show_menu

case "$choice" in
1)
    onekey_fix
    ;;
2)
    ufw_allow_ports
    ;;
3)
    ufw_deny_ports
    ;;
4)
    ufw_status
    ;;
0)
    echo "[*] 退出"
    exit 0
    ;;
*)
    echo "[!] 无效选项"
    exit 1
    ;;
esac
