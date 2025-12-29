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
# 辅助探测工具 (严格 IPv4 过滤)
# --------------------------
get_ssh_port() {
    local port
    port=$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}')
    echo "${port:-22}"
}

get_docker_network() {
    local net
    net=$(docker network inspect bridge --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}\b" | head -n 1)
    echo "${net:-172.17.0.0/16}"
}

get_main_interface() {
    local interface
    interface=$(ip route | grep default | awk '{print $5}' | head -n 1)
    echo "${interface:-eth0}"
}

# =====================================================
# 11) 自动识别并放行所有 Docker 真实网桥卡 (提取为独立函数供合并调用)
# =====================================================
auto_allow_docker_bridges() {
    echo "▶ 正在识别 Docker 真实网桥卡并放行..."
    local current_ufw_status=$(ufw status)
    
    docker network ls --filter driver=bridge --format "{{.Name}}" | while read -r net; do
        local iface subnet
        if [ "$net" == "bridge" ]; then
            iface="docker0"
        else
            # 提取真实的 Bridge 名称 (如 br-xxxx)
            iface=$(docker network inspect "$net" --format '{{index .Options "com.docker.network.bridge.name"}}' 2>/dev/null || echo "")
            [ -z "$iface" ] && iface="br-$(docker network inspect "$net" --format '{{.Id}}' | cut -c1-12)"
        fi
        
        subnet=$(docker network inspect "$net" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}\b" | head -n 1)
        
        if [ -n "$iface" ] && [ -n "$subnet" ]; then
            if echo "$current_ufw_status" | grep -q "$iface"; then
                echo "ℹ️  网卡 $iface ($subnet) 规则已存在，跳过。"
            else
                ufw allow in on "$iface" from "$subnet" >/dev/null 2>&1 && echo "✔ 已放行真实网卡: $iface ($subnet)"
            fi
        fi
    done
}

# =====================================================
# 1) 修复 Docker + UFW 环境 (合并 11 项网桥放行逻辑)
# =====================================================
fix_ufw_docker() {
    echo "▶ 正在执行环境修复..."
    apt update -y && apt install -y ufw nftables

    # 【1】放行 SSH 端口
    SSH_PORT=$(get_ssh_port)
    echo "------------------------------------------------"
    echo "🛡️  安全检测：检测到 SSH 端口为: $SSH_PORT"
    echo "🛡️  正在自动执行: ufw allow $SSH_PORT/tcp"
    echo "------------------------------------------------"
    ufw allow "$SSH_PORT"/tcp >/dev/null 2>&1 || true

    # 【2】自动识别并放行所有 Docker 网桥 (合并选项11)
    auto_allow_docker_bridges

    # 【3】设置 UFW 默认允许转发
    sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

    # 【4】写入 DOCKER-USER 核心劫持规则
    mkdir -p "$BACKUP_DIR"
    [ -f "$UFW_AFTER" ] && cp "$UFW_AFTER" "$BACKUP_FILE" && echo "✔ 原配置已备份: $BACKUP_FILE"

    cat > "$UFW_AFTER" <<EOF
*filter
:ufw-user-forward - [0:0]
:ufw-docker-logging-deny - [0:0]
:DOCKER-USER - [0:0]

# 局域网信任域 (放行私有网段直通)
-A DOCKER-USER -s 10.0.0.0/8 -j RETURN
-A DOCKER-USER -s 172.16.0.0/12 -j RETURN
-A DOCKER-USER -s 192.168.0.0/16 -j RETURN

# UFW 拦截核心
-A DOCKER-USER -j ufw-user-forward
-A DOCKER-USER -j ufw-docker-logging-deny
-A ufw-docker-logging-deny -m limit --limit 3/min --limit-burst 10 -j LOG --log-prefix "[UFW DOCKER BLOCK] "
-A ufw-docker-logging-deny -j DROP
COMMIT
EOF

    ufw --force enable
    systemctl restart docker && systemctl restart ufw
    echo ""
    echo "✅ 环境修复完成！SSH 端口 $SSH_PORT 及所有 Docker 网桥已放行。"
}

# --------------------------
# 端口管理模块 (2-5 项)
# --------------------------
select_container_ip() {
    local i=1
    local map_file="/tmp/ufw_docker_map"
    rm -f "$map_file"
    printf "\033[32m%-3s | %-20s | %-15s\033[0m\n" "ID" "NAME" "IPv4"
    docker ps -a --format "{{.Names}}" | while read -r name; do
        local ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$name" | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b" | head -n 1)
        printf "%-3d | %-20s | %-15s\n" "$i" "$name" "${ip:-no-ip}"
        echo "$i|${ip:-any}|$name" >> "$map_file"
        i=$((i+1))
    done
    read -rp "请选择 ID (0 为 any): " choice
    [ "${choice:-0}" == "0" ] && echo "any" || (grep "^$choice|" "$map_file" | cut -d'|' -f2 || echo "any")
}

manage_ports() {
    local mode=$1 
    local action=$2 
    local target_ip=$3
    read -rp "请输入端口 (如 80 443): " port_input
    for p in $port_input; do
        if [ "$action" == "allow" ]; then
            [ "$mode" == "host_and_container" ] && ufw allow "$p"/tcp
            if [ "$target_ip" != "any" ]; then
                iptables -I DOCKER-USER 1 -p tcp -d "$target_ip" --dport "$p" -j ACCEPT
            fi
        else
            [ "$mode" == "host_and_container" ] && ufw delete allow "$p"/tcp || true
            if [ "$target_ip" != "any" ]; then
                iptables -D DOCKER-USER -p tcp -d "$target_ip" --dport "$p" -j ACCEPT 2>/dev/null || true
            fi
        fi
    done
    echo "✔ 操作执行完成。"
}

# ==========================
# 菜单定义 (11 项全部补全)
# ==========================
menu() {
    clear
    echo "========================================"
    echo "    Docker + UFW 防火墙管理脚本"
    echo "    (Debian 13 十一项全功能版)"
    echo "========================================"
    echo "1) 修复 Docker + UFW 环境 (含自动网桥放行)"
    echo "2) 开放容器端口 (仅外网→容器)"
    echo "3) 关闭容器端口 (仅外网→容器)"
    echo "4) 开放宿主机+容器端口 (外网→全通)"
    echo "5) 关闭宿主机+容器端口 (外网→全封)"
    echo "6) 查看规则 (UFW + DOCKER-USER)"
    echo "7) 持久化规则 (防止重启丢失)"
    echo "8) 诊断工具 (排查环境问题)"
    echo "9) 完全还原 (卸载 UFW 并清理)"
    echo "10) 修复 RackNerd IPv6"
    echo "11) 自动识别并放行所有新 Docker 网桥"
    echo "0) 退出"
    echo "========================================"
    read -rp "请选择 [0-11]: " choice
    case "$choice" in
        1) fix_ufw_docker ;;
        2) manage_ports "container_only" "allow" "$(select_container_ip)" ;;
        3) manage_ports "container_only" "delete" "$(select_container_ip)" ;;
        4) manage_ports "host_and_container" "allow" "$(select_container_ip)" ;;
        5) manage_ports "host_and_container" "delete" "$(select_container_ip)" ;;
        6) ufw status numbered; echo "--- DOCKER-USER ---"; iptables -L DOCKER-USER -n --line-numbers ;;
        7) apt install -y iptables-persistent && netfilter-persistent save ;;
        8) iptables --version; ufw status; docker network ls; ip addr ;;
        9) 
            read -rp "确认完全卸载？(yes/no): " res; [ "$res" == "yes" ] && { ufw --force disable; apt purge -y ufw; rm -rf /etc/ufw; systemctl restart docker; } ;;
        10) 
            local iface=$(get_main_interface); cat > "/etc/sysctl.d/99-racknerd-ipv6.conf" <<EOF
net.ipv6.conf.all.autoconf = 0
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.$iface.autoconf = 0
net.ipv6.conf.$iface.accept_ra = 0
EOF
            sysctl --system && echo "✔ IPv6 修复完成" ;;
        11) auto_allow_docker_bridges ;;
        0) exit 0 ;;
        *) echo "❌ 无效选择" ;;
    esac
    pause
    menu
}

require_root
menu
