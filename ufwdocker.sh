#!/usr/bin/env bash
set -e

# ==========================
# 配置文件与全局变量
# ==========================
UFW_AFTER="/etc/ufw/after.rules"
BACKUP_DIR="/root/ufw-backup"
BACKUP_FILE="$BACKUP_DIR/after.rules.$(date +%Y%m%d_%H%M%S)"

require_root() { [ "$EUID" -eq 0 ] || { echo "❌ 请使用 root 运行"; exit 1; } }
pause() { echo ""; read -rp "按回车继续..." ; }

# --------------------------
# 辅助探测工具
# --------------------------
get_ssh_port() {
    local port
    port=$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}')
    echo "${port:-22}"
}

get_main_interface() {
    local interface
    interface=$(ip route | grep default | awk '{print $5}' | head -n 1)
    echo "${interface:-eth0}"
}

# =====================================================
# 11) 自动识别并放行 Docker 网桥
# =====================================================
auto_allow_docker_bridges() {
    echo "------------------------------------------------"
    echo "🔍 正在扫描 Docker bridge 网络..."
    local current_ufw_status=$(ufw status)
    local nets=$(docker network ls --filter driver=bridge --format "{{.Name}}")

    [ -z "$nets" ] && { echo "ℹ️ 未检测到 Docker bridge"; return; }

    echo "$nets" | while read -r net; do
        local iface subnet
        if [ "$net" = "bridge" ]; then
            iface="docker0"
        else
            iface=$(docker network inspect "$net" --format '{{index .Options "com.docker.network.bridge.name"}}' 2>/dev/null)
            [ -z "$iface" ] && iface="br-$(docker network inspect "$net" --format '{{.Id}}' | cut -c1-12)"
        fi

        subnet=$(docker network inspect "$net" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' | head -n1)

        if echo "$current_ufw_status" | grep -q "$iface"; then
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
# 端口管理
# =====================================================
select_container_ip() {
    local i=1 map="/tmp/ufw_map"
    rm -f "$map"
    printf "%-3s | %-20s | %-15s\n" ID NAME IPv4
    docker ps -a --format "{{.Names}}" | while read -r n; do
        ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$n")
        printf "%-3d | %-20s | %-15s\n" "$i" "$n" "${ip:-any}"
        echo "$i|${ip:-any}" >> "$map"
        i=$((i+1))
    done
    read -rp "选择 ID (0=any): " c
    [ "$c" = "0" ] && echo "any" || awk -F'|' "\$1==$c{print \$2}" "$map"
}

manage_ports() {
    local mode=$1 action=$2 ip=$3
    read -rp "端口: " ports
    for p in $ports; do
        [ "$action" = "allow" ] && ufw allow "$p"/tcp || ufw delete allow "$p"/tcp || true
        [ "$ip" != "any" ] && iptables -I DOCKER-USER -p tcp -d "$ip" --dport "$p" -j ACCEPT 2>/dev/null || true
    done
}

# =====================================================
# 菜单
# =====================================================
menu() {
    clear
    echo "Docker + UFW 管理脚本 (Debian 13)"
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
    echo "0) 退出"
    read -rp "选择: " c

    case $c in
        1) fix_ufw_docker ;;
        2) manage_ports container allow "$(select_container_ip)" ;;
        3) manage_ports container delete "$(select_container_ip)" ;;
        4) manage_ports host allow "$(select_container_ip)" ;;
        5) manage_ports host delete "$(select_container_ip)" ;;
        6) ufw status numbered; iptables -L DOCKER-USER -n ;;
        7) apt install -y iptables-persistent && netfilter-persistent save ;;
        8) ufw status; docker network ls; ip addr ;;
        9) ufw --force disable; apt purge -y ufw ;;
        10)
            echo "🔧 修复 RackNerd IPv6"
            cp /etc/sysctl.conf /etc/sysctl.conf.bak.$(date +%s)

            sed -i '/racknerd ipv6 fix/d;/net.ipv6.conf.*autoconf/d;/net.ipv6.conf.*accept_ra/d' /etc/sysctl.conf

            cat >> /etc/sysctl.conf <<'EOF'

# racknerd ipv6 fix
net.ipv6.conf.all.autoconf = 0
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.eth0.autoconf = 0
net.ipv6.conf.eth0.accept_ra = 0
EOF
            sysctl -p
            systemctl restart networking
            read -rp "是否立即 reboot？(yes/no): " r
            [ "$r" = "yes" ] && reboot
            ;;
        11) auto_allow_docker_bridges ;;
        0) exit ;;
    esac
    pause
    menu
}

require_root
menu
