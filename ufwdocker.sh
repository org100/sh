#!/usr/bin/env bash
set -e

# ==========================
# 配置文件与全局变量
# ==========================
UFW_AFTER="/etc/ufw/after.rules"
BACKUP_DIR="/root/ufw-backup"
BACKUP_FILE="$BACKUP_DIR/after.rules.$(date +%Y%m%d_%H%M%S)"
SYSCTL_CONF="/etc/sysctl.conf"
DOCKER_DAEMON="/etc/docker/daemon.json"

require_root() { [ "$EUID" -eq 0 ] || { echo "❌ 请使用 root 运行"; exit 1; } }
pause() { echo ""; read -rp "按回车继续..." ; }

# --------------------------
# 辅助探测工具
# --------------------------
get_ssh_port() {
    sshd -T 2>/dev/null | awk '/^port / {print $2; exit}' || echo 22
}

get_main_interface() {
    ip route | awk '/default/ {print $5; exit}' || echo eth0
}

# =====================================================
# 11) 自动识别并放行 Docker bridge
# =====================================================
auto_allow_docker_bridges() {
    echo "------------------------------------------------"
    echo "🔍 扫描 Docker bridge 网络..."
    local status=$(ufw status)
    docker network ls --filter driver=bridge --format "{{.Name}}" | while read -r net; do
        [ -z "$net" ] && continue
        if [ "$net" = "bridge" ]; then
            iface="docker0"
        else
            iface=$(docker network inspect "$net" --format '{{index .Options "com.docker.network.bridge.name"}}' 2>/dev/null)
            [ -z "$iface" ] && iface="br-$(docker network inspect "$net" --format '{{.Id}}' | cut -c1-12)"
        fi
        subnet=$(docker network inspect "$net" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' | head -n1)
        if echo "$status" | grep -q "$iface"; then
            echo "⏭️ 已存在: $iface ($subnet)"
        else
            ufw allow in on "$iface" from "$subnet" >/dev/null 2>&1
            echo "✅ 放行: $iface ($subnet)"
        fi
    done
}

# =====================================================
# 1) 修复 Docker + UFW
# =====================================================
fix_ufw_docker() {
    apt update -y && apt install -y ufw nftables

    local SSH_PORT=$(get_ssh_port)
    ufw allow "$SSH_PORT"/tcp >/dev/null 2>&1 || true

    auto_allow_docker_bridges

    sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

    mkdir -p "$BACKUP_DIR"
    [ -f "$UFW_AFTER" ] && cp "$UFW_AFTER" "$BACKUP_FILE"

    cat > "$UFW_AFTER" <<EOF
*filter
:ufw-user-forward - [0:0]
:ufw-docker-logging-deny - [0:0]
:DOCKER-USER - [0:0]

-A DOCKER-USER -s 10.0.0.0/8 -j RETURN
-A DOCKER-USER -s 172.16.0.0/12 -j RETURN
-A DOCKER-USER -s 192.168.0.0/16 -j RETURN

-A DOCKER-USER -j ufw-user-forward
-A DOCKER-USER -j ufw-docker-logging-deny
-A ufw-docker-logging-deny -m limit --limit 3/min --limit-burst 10 -j LOG --log-prefix "[UFW DOCKER BLOCK] "
-A ufw-docker-logging-deny -j DROP
COMMIT
EOF

    ufw --force enable
    systemctl restart docker ufw
    echo "🎉 Docker + UFW 修复完成"
}

# =====================================================
# 🧪 IPv6 生效检测
# =====================================================
check_ipv6_status() {
    echo "------------------------------------------------"
    echo "🧪 IPv6 生效检测"
    echo "------------------------------------------------"

    local fail=0

    for k in net.ipv6.conf.eth0.autoconf net.ipv6.conf.eth0.accept_ra; do
        [ "$(sysctl -n "$k" 2>/dev/null)" = "0" ] || fail=1
    done

    ip -6 addr show eth0 | grep -q inet6 || fail=1
    ip -6 route | grep -q default || fail=1

    if [ "$fail" -eq 0 ]; then
        echo "✅ IPv6 已真正生效"
    else
        echo "❌ IPv6 未完全生效（强烈建议 reboot）"
    fi
}

# =====================================================
# 🐳 Docker IPv6 启用（闭环）
# =====================================================
enable_docker_ipv6() {
    echo "------------------------------------------------"
    echo "🐳 启用 Docker IPv6（ULA 闭环）"
    echo "------------------------------------------------"

    mkdir -p /etc/docker
    [ -f "$DOCKER_DAEMON" ] && cp "$DOCKER_DAEMON" "$DOCKER_DAEMON.bak.$(date +%s)"

    cat > "$DOCKER_DAEMON" <<'EOF'
{
  "ipv6": true,
  "fixed-cidr-v6": "fd00:dead:beef::/48",
  "iptables": true,
  "ip6tables": true
}
EOF

    systemctl restart docker
    auto_allow_docker_bridges
    echo "✅ Docker IPv6 已启用"
}

check_docker_ipv6() {
    echo "------------------------------------------------"
    echo "🐳 Docker IPv6 状态检测"
    echo "------------------------------------------------"
    docker info 2>/dev/null | grep -E "IPv6|ip6tables" || echo "❌ Docker IPv6 未启用"
}

# =====================================================
# 菜单
# =====================================================
menu() {
    clear
    echo "Docker + UFW 防火墙管理脚本 (Debian 13 · 发布级)"
    echo "1) 修复 Docker + UFW"
    echo "2) 开放容器端口"
    echo "3) 关闭容器端口"
    echo "4) 开放宿主机+容器端口"
    echo "5) 关闭宿主机+容器端口"
    echo "6) 查看规则"
    echo "7) 持久化规则"
    echo "8) 诊断"
    echo "9) 完全还原"
    echo "10) 修复 RackNerd IPv6"
    echo "11) 放行 Docker 新网桥"
    echo "12) 🧪 IPv6 生效检测"
    echo "13) 🐳 启用 Docker IPv6（闭环）"
    echo "14) 🐳 Docker IPv6 状态检测"
    echo "0) 退出"
    read -rp "选择: " c

    case "$c" in
        1) fix_ufw_docker ;;
        10)
            if [ ! -f "$SYSCTL_CONF" ]; then
                touch "$SYSCTL_CONF"
            else
                cp "$SYSCTL_CONF" "$SYSCTL_CONF.bak.$(date +%s)"
            fi

            sed -i '/racknerd ipv6 fix/d;/net.ipv6.conf.*autoconf/d;/net.ipv6.conf.*accept_ra/d' "$SYSCTL_CONF"

            cat >> "$SYSCTL_CONF" <<'EOF'

# racknerd ipv6 fix
net.ipv6.conf.all.autoconf = 0
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.eth0.autoconf = 0
net.ipv6.conf.eth0.accept_ra = 0
EOF
            sysctl -p
            systemctl restart networking
            check_ipv6_status
            ;;
        11) auto_allow_docker_bridges ;;
        12) check_ipv6_status ;;
        13) enable_docker_ipv6 ;;
        14) check_docker_ipv6 ;;
        0) exit ;;
    esac
    pause
    menu
}

require_root
menu
