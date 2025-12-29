#!/usr/bin/env bash
set -e

# ==========================
# 配置文件
# ==========================
UFW_AFTER="/etc/ufw/after.rules"
BACKUP_DIR="/root/ufw-backup"
BACKUP_FILE="$BACKUP_DIR/after.rules.$(date +%Y%m%d_%H%M%S)"

require_root() { [ "$EUID" -eq 0 ] || { echo "❌ 请使用 root 运行"; exit 1; } }
pause() { echo ""; read -rp "按回车继续..." ; }

# ==========================
# 网络检测工具 (严格过滤 IPv4)
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
# 环境修复逻辑
# ==========================
fix_ufw_docker() {
    echo "▶ 正在执行环境修复..."
    
    # 检测 nftables 兼容性
    if [ -f /proc/sys/net/netfilter/nf_tables_api_version ]; then
        local ipt_version
        ipt_version=$(iptables --version 2>/dev/null || echo "unknown")
        if echo "$ipt_version" | grep -q "legacy"; then
            echo "⚠️  检测到 legacy 模式，正在切换到 iptables-nft..."
            update-alternatives --set iptables /usr/sbin/iptables-nft >/dev/null 2>&1
            update-alternatives --set ip6tables /usr/sbin/ip6tables-nft >/dev/null 2>&1
        fi
    fi

    apt update -y && apt install -y ufw nftables

    SSH_PORT=$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}' || echo "22")
    ufw allow "$SSH_PORT"/tcp >/dev/null 2>&1 || true

    mkdir -p "$BACKUP_DIR"
    [ -f "$UFW_AFTER" ] && cp "$UFW_AFTER" "$BACKUP_FILE"

    DOCKER_SUBNET=$(get_docker_network)
    DOCKER_GW=$(get_docker_gateway)
    echo "✔ 识别到网络: $DOCKER_SUBNET (网关: $DOCKER_GW)"

    sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

    cat > "$UFW_AFTER" <<EOF
*filter
:ufw-user-forward - [0:0]
:ufw-docker-logging-deny - [0:0]
:DOCKER-USER - [0:0]

# 宿主机 <-> 容器互通
-A DOCKER-USER -s $DOCKER_SUBNET -d $DOCKER_GW -j ACCEPT
-A DOCKER-USER -s $DOCKER_GW -d $DOCKER_SUBNET -j ACCEPT

# 局域网放行
-A DOCKER-USER -s 10.0.0.0/8 -j RETURN
-A DOCKER-USER -s 172.16.0.0/12 -j RETURN
-A DOCKER-USER -s 192.168.0.0/16 -j RETURN
-A DOCKER-USER -p udp --sport 53 --dport 1024:65535 -j RETURN

# UFW 控制核心
-A DOCKER-USER -j ufw-user-forward
-A DOCKER-USER -j ufw-docker-logging-deny
-A ufw-docker-logging-deny -m limit --limit 3/min --limit-burst 10 -j LOG --log-prefix "[UFW DOCKER BLOCK] "
-A ufw-docker-logging-deny -j DROP
COMMIT
EOF

    ufw --force enable
    systemctl restart docker
    sleep 1
    systemctl restart ufw || { echo "❌ UFW 重启失败，正在尝试回滚..."; cp "$BACKUP_FILE" "$UFW_AFTER"; exit 1; }
    echo "✔ 环境修复完成"
}

# ==========================
# 端口管理逻辑
# ==========================
select_container_ip() {
    local map_file="/tmp/ufw_docker_map"
    rm -f "$map_file"
    local i=1
    printf "\033[32m%-3s | %-20s | %-15s | %s\033[0m\n" "ID" "NAMES" "IP" "STATUS" > /dev/tty
    docker ps -a --format "{{.Names}}" | while read -r name; do
        [ -z "$name" ] && continue
        local ip
        ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$name" | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b" | head -n 1)
        [ -z "$ip" ] && ip="no-ip"
        local status
        status=$(docker inspect -f '{{.State.Status}}' "$name")
        printf "%-3d | %-20s | %-15s | %s\n" "$i" "$name" "$ip" "$status" > /dev/tty
        echo "$i|$ip|$name" >> "$map_file"
        i=$((i+1))
    done
    echo " 0   | any (仅宿主机规则)" > /dev/tty
    
    local choice
    read -rp "请选择 ID: " choice
    choice=${choice:-0}
    if [ "$choice" == "0" ]; then echo "any"; else
        grep "^$choice|" "$map_file" | cut -d'|' -f2 || echo "any"
    fi
}

manage_host_and_container() {
    local action=$1
    local target_ip=$2
    read -rp "请输入端口 (空格分隔): " port_input
    for p in $port_input; do
        if [ "$action" == "allow" ]; then
            ufw allow "$p"/tcp >/dev/null 2>&1
            if [ "$target_ip" != "any" ] && [ "$target_ip" != "no-ip" ]; then
                # 检查是否已存在，防止重复插入
                iptables -C DOCKER-USER -p tcp -d "$target_ip" --dport "$p" -j ACCEPT 2>/dev/null || \
                iptables -I DOCKER-USER 1 -p tcp -d "$target_ip" --dport "$p" -j ACCEPT
            fi
            echo "✔ 已开放端口: $p"
        else
            # 删除 UFW 规则
            ufw delete allow "$p"/tcp >/dev/null 2>&1 || true
            # 删除 DOCKER-USER 规则
            if [ "$target_ip" != "any" ]; then
                iptables -D DOCKER-USER -p tcp -d "$target_ip" --dport "$p" -j ACCEPT 2>/dev/null || true
            fi
            echo "✔ 已关闭端口: $p"
        fi
    done
}

# ==========================
# 自动放行所有自定义网桥
# ==========================
auto_allow_bridges() {
    echo "▶ 扫描自定义网桥..."
    docker network ls --filter driver=bridge --format "{{.Name}}" | while read -r net; do
        [ "$net" == "bridge" ] && continue
        local subnet
        subnet=$(docker network inspect "$net" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}\b" | head -n 1)
        [ -z "$subnet" ] && continue
        echo "✔ 允许网桥: $net ($subnet)"
        ufw allow in on "$net" from "$subnet" >/dev/null 2>&1 || true
    done
}

# ==========================
# 规则持久化
# ==========================
save_rules() {
    echo "▶ 正在持久化规则..."
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save
    else
        apt install -y iptables-persistent
    fi
    echo "✔ 规则已保存至 /etc/iptables/rules.v4"
}

# ==========================
# IPv6 修复
# ==========================
fix_ipv6() {
    echo "[*] 修复 RackNerd IPv6..."
    local interface=$(get_main_interface)
    cat > "/etc/sysctl.d/99-racknerd-ipv6.conf" <<EOF
net.ipv6.conf.all.autoconf = 0
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.$interface.autoconf = 0
net.ipv6.conf.$interface.accept_ra = 0
EOF
    sysctl --system
    echo "✔ 配置已应用，若仍不通请手动 reboot"
}

menu() {
    clear
    echo "========================================"
    echo "    Docker + UFW 防火墙管理脚本"
    echo "    (Debian 13 IPv4/v6 修正版)"
    echo "========================================"
    echo "1) 修复 Docker + UFW 环境 (必选)"
    echo "2) 开放端口 (宿主机 + 容器)"
    echo "3) 关闭端口 (宿主机 + 容器)"
    echo "4) 自动放行所有 Docker 自定义网桥"
    echo "6) 查看规则 (UFW + DOCKER-USER)"
    echo "7) 持久化规则 (防止重启丢失)"
    echo "10) 修复 RackNerd IPv6"
    echo "0) 退出"
    echo "========================================"
    read -rp "请选择: " choice
    case "$choice" in
        1) fix_ufw_docker ;;
        2) manage_host_and_container "allow" "$(select_container_ip)" ;;
        3) manage_host_and_container "delete" "$(select_container_ip)" ;;
        4) auto_allow_bridges ;;
        6) ufw status numbered; echo ""; iptables -L DOCKER-USER -n --line-numbers ;;
        7) save_rules ;;
        10) fix_ipv6 ;;
        0) exit 0 ;;
    esac
    pause
    menu
}

require_root
menu
