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

# ==========================
# 增强的网络探测 (严格过滤 IPv4，解决粘连问题)
# ==========================
get_docker_network() {
    local net
    net=$(docker network inspect bridge --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}\b" | head -n 1)
    echo "${net:-172.17.0.0/16}"
}

get_docker_gateway() {
    local gw
    gw=$(docker network inspect bridge --format '{{range .IPAM.Config}}{{.Gateway}} {{end}}' 2>/dev/null | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b" | head -n 1)
    echo "${gw:-172.17.0.1}"
}

get_main_interface() {
    local interface
    interface=$(ip route | grep default | awk '{print $5}' | head -n 1)
    echo "${interface:-eth0}"
}

# ==========================
# 核心逻辑函数
# ==========================

# 1) 修复 Docker + UFW 环境
fix_ufw_docker() {
    echo "▶ 正在执行环境修复..."
    # 自动识别并切换到 nftables 兼容模式
    if [ -f /proc/sys/net/netfilter/nf_tables_api_version ]; then
        update-alternatives --set iptables /usr/sbin/iptables-nft >/dev/null 2>&1 || true
    fi
    apt update -y && apt install -y ufw nftables

    SSH_PORT=$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}' || echo "22")
    ufw allow "$SSH_PORT"/tcp >/dev/null 2>&1 || true

    mkdir -p "$BACKUP_DIR"
    [ -f "$UFW_AFTER" ] && cp "$UFW_AFTER" "$BACKUP_FILE"

    DOCKER_SUBNET=$(get_docker_network)
    DOCKER_GW=$(get_docker_gateway)
    
    sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

    cat > "$UFW_AFTER" <<EOF
*filter
:ufw-user-forward - [0:0]
:ufw-docker-logging-deny - [0:0]
:DOCKER-USER - [0:0]

# 宿主机 <-> 容器互通
-A DOCKER-USER -s $DOCKER_SUBNET -d $DOCKER_GW -j ACCEPT
-A DOCKER-USER -s $DOCKER_GW -d $DOCKER_SUBNET -j ACCEPT

# 局域网信任段
-A DOCKER-USER -s 10.0.0.0/8 -j RETURN
-A DOCKER-USER -s 172.16.0.0/12 -j RETURN
-A DOCKER-USER -s 192.168.0.0/16 -j RETURN
-A DOCKER-USER -p udp --sport 53 --dport 1024:65535 -j RETURN

# UFW 控制流
-A DOCKER-USER -j ufw-user-forward
-A DOCKER-USER -j ufw-docker-logging-deny
-A ufw-docker-logging-deny -m limit --limit 3/min --limit-burst 10 -j LOG --log-prefix "[UFW DOCKER BLOCK] "
-A ufw-docker-logging-deny -j DROP
COMMIT
EOF
    ufw --force enable
    systemctl restart docker && systemctl restart ufw
    echo "✔ 环境修复完成！"
}

# 端口管理通用函数
manage_ports() {
    local type=$1   # container_only | host_and_container
    local action=$2 # allow | delete
    local target_ip=$3

    read -rp "请输入端口 (空格分隔): " port_input
    for p in $port_input; do
        if [ "$action" == "allow" ]; then
            [ "$type" == "host_and_container" ] && ufw allow "$p"/tcp
            if [ "$target_ip" != "any" ]; then
                iptables -I DOCKER-USER 1 -p tcp -d "$target_ip" --dport "$p" -j ACCEPT
            fi
        else
            [ "$type" == "host_and_container" ] && ufw delete allow "$p"/tcp || true
            if [ "$target_ip" != "any" ]; then
                iptables -D DOCKER-USER -p tcp -d "$target_ip" --dport "$p" -j ACCEPT 2>/dev/null || true
            fi
        fi
    done
    echo "✔ 操作已执行"
}

# 11) 网桥识别
auto_allow_bridges() {
    echo "▶ 自动识别自定义网桥..."
    docker network ls --filter driver=bridge --format "{{.Name}}" | while read -r net; do
        [ "$net" == "bridge" ] && continue
        local sub=$(docker network inspect "$net" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}\b" | head -n 1)
        [ -n "$sub" ] && ufw allow in on "$net" from "$sub" && echo "✔ 已放行网桥: $net ($sub)"
    done
}

# 10) RackNerd IPv6 修复
fix_ipv6() {
    echo "[*] 正在执行 IPv6 修复..."
    local iface=$(get_main_interface)
    cat > "/etc/sysctl.d/99-racknerd-ipv6.conf" <<EOF
net.ipv6.conf.all.autoconf = 0
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.$iface.autoconf = 0
net.ipv6.conf.$iface.accept_ra = 0
EOF
    sysctl --system
    echo "✔ IPv6 修复配置已应用。"
}

# ==========================
# 容器选择器
# ==========================
select_container_ip() {
    local i=1
    local map_file="/tmp/ufw_docker_map"
    rm -f "$map_file"
    printf "\033[32m%-3s | %-20s | %-15s\033[0m\n" "ID" "NAME" "IP"
    docker ps --format "{{.Names}}" | while read -r name; do
        local ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$name" | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b" | head -n 1)
        printf "%-3d | %-20s | %-15s\n" "$i" "$name" "${ip:-no-ip}"
        echo "$i|${ip:-any}|$name" >> "$map_file"
        i=$((i+1))
    done
    read -rp "请选择 ID (0 为 any): " choice
    [ "${choice:-0}" == "0" ] && echo "any" || (grep "^$choice|" "$map_file" | cut -d'|' -f2 || echo "any")
}

# ==========================
# 菜单 (补全至 11 项)
# ==========================
menu() {
    clear
    echo "========================================"
    echo "    Docker + UFW 防火墙管理脚本"
    echo "    (Debian 13 十一项全功能版)"
    echo "========================================"
    echo "1) 修复 Docker + UFW 环境 (自动检测)"
    echo "2) 开放容器端口 (仅外网→容器)"
    echo "3) 关闭容器端口 (仅外网→容器)"
    echo "4) 开放宿主机+容器端口 (外网→全通)"
    echo "5) 关闭宿主机+容器端口 (外网→全封)"
    echo "6) 查看当前防火墙规则 (UFW+Docker)"
    echo "7) 持久化规则 (防止重启丢失)"
    echo "8) 诊断工具 (排查环境与兼容性)"
    echo "9) 完全还原 (卸载 UFW 并清理)"
    echo "10) 安全修复 RackNerd IPv6"
    echo "11) 自动识别并放行所有 Docker 网桥"
    echo "0) 退出"
    echo "========================================"
    read -rp "请选择 [0-11]: " choice
    case "$choice" in
        1) fix_ufw_docker ;;
        2) manage_ports "container_only" "allow" "$(select_container_ip)" ;;
        3) manage_ports "container_only" "delete" "$(select_container_ip)" ;;
        4) manage_ports "host_and_container" "allow" "$(select_container_ip)" ;;
        5) manage_ports "host_and_container" "delete" "$(select_container_ip)" ;;
        6) ufw status numbered; echo "--- DOCKER-USER Chain ---"; iptables -L DOCKER-USER -n --line-numbers ;;
        7) apt install -y iptables-persistent && netfilter-persistent save ;;
        8) iptables --version; ufw status verbose; docker network ls ;;
        9) 
            read -rp "⚠️ 确认完全卸载 UFW？(yes/no): " confirm
            if [ "$confirm" == "yes" ]; then
                ufw --force disable && apt purge -y ufw && rm -rf /etc/ufw
                systemctl restart docker && echo "✔ UFW 已清理。"
            fi ;;
        10) fix_ipv6 ;;
        11) auto_allow_bridges ;;
        0) exit 0 ;;
        *) echo "❌ 无效选择" ;;
    esac
    pause
    menu
}

require_root
menu
