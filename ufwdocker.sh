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
# 增强的网络检测 (严格过滤 IPv4，防止双栈粘连)
# ==========================
get_docker_network() {
    # 只提取标准的 IPv4 段格式，防止 IPv6 混入导致 UFW 配置文件语法错误
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
    # 动态获取主网卡名，适配 Debian 13 可能出现的 ens3/enp0s3 等命名
    local interface
    interface=$(ip route | grep default | awk '{print $5}' | head -n 1)
    echo "${interface:-eth0}"
}

# ==========================
# Debian 13 nftables 兼容性检测
# ==========================
check_nftables_compat() {
    echo "▶ 检测防火墙后端..."
    if [ -f /proc/sys/net/netfilter/nf_tables_api_version ]; then
        echo "✔ 系统支持 nftables"
        local ipt_version
        ipt_version=$(iptables --version 2>/dev/null || echo "unknown")
        if echo "$ipt_version" | grep -q "nf_tables"; then
            echo "✔ 当前使用: iptables-nft (兼容模式)"
        elif echo "$ipt_version" | grep -q "legacy"; then
            echo "⚠️  当前使用: iptables-legacy"
            echo "💡 正在自动切换到 iptables-nft 以获得更好的兼容性..."
            update-alternatives --set iptables /usr/sbin/iptables-nft >/dev/null 2>&1
            update-alternatives --set ip6tables /usr/sbin/ip6tables-nft >/dev/null 2>&1
            systemctl restart docker
        fi
    fi
}

# ==========================
# 核心功能逻辑
# ==========================

# 1) 修复环境
fix_ufw_docker() {
    echo "▶ 正在执行环境修复..."
    check_nftables_compat
    apt update -y && apt install -y ufw nftables grep awk

    SSH_PORT=$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}' || echo "22")
    echo "✔ SSH 端口: $SSH_PORT，已预放行..."
    ufw allow "$SSH_PORT"/tcp >/dev/null 2>&1 || true

    mkdir -p "$BACKUP_DIR"
    [ -f "$UFW_AFTER" ] && cp "$UFW_AFTER" "$BACKUP_FILE" && echo "✔ 原配置已备份: $BACKUP_FILE"

    DOCKER_SUBNET=$(get_docker_network)
    DOCKER_GW=$(get_docker_gateway)
    echo "✔ 识别到 Docker 网络: $DOCKER_SUBNET (网关: $DOCKER_GW)"

    sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

    cat > "$UFW_AFTER" <<EOF
*filter
:ufw-user-forward - [0:0]
:ufw-docker-logging-deny - [0:0]
:DOCKER-USER - [0:0]

# 宿主机 <-> 容器互通
-A DOCKER-USER -s $DOCKER_SUBNET -d $DOCKER_GW -j ACCEPT
-A DOCKER-USER -s $DOCKER_GW -d $DOCKER_SUBNET -j ACCEPT

# 局域网信任网段
-A DOCKER-USER -s 10.0.0.0/8 -j RETURN
-A DOCKER-USER -s 172.16.0.0/12 -j RETURN
-A DOCKER-USER -s 192.168.0.0/16 -j RETURN
-A DOCKER-USER -p udp --sport 53 --dport 1024:65535 -j RETURN

# 默认规则交由 UFW 控制
-A DOCKER-USER -j ufw-user-forward
-A DOCKER-USER -j ufw-docker-logging-deny
-A ufw-docker-logging-deny -m limit --limit 3/min --limit-burst 10 -j LOG --log-prefix "[UFW DOCKER BLOCK] "
-A ufw-docker-logging-deny -j DROP
COMMIT
EOF

    ufw --force enable
    systemctl restart docker
    sleep 1
    systemctl restart ufw || { echo "❌ UFW 重启失败，正在检查配置..."; exit 1; }
    echo "✔ 修复完成！"
}

# 容器/宿主机端口管理
manage_ports() {
    local type=$1    # host_container or container_only
    local action=$2  # allow or delete
    local target_ip=$3

    read -rp "请输入端口 (空格分隔): " port_input
    local ports=(${port_input// / })
    [ ${#ports[@]} -eq 0 ] && { echo "❌ 端口不能为空"; return 1; }

    for p in "${ports[@]}"; do
        if [ "$action" == "allow" ]; then
            [ "$type" == "host_container" ] && ufw allow "$p"/tcp >/dev/null 2>&1
            if [ "$target_ip" != "any" ] && [ "$target_ip" != "no-ip" ]; then
                iptables -C DOCKER-USER -p tcp -d "$target_ip" --dport "$p" -j ACCEPT 2>/dev/null || \
                iptables -I DOCKER-USER 1 -p tcp -d "$target_ip" --dport "$p" -j ACCEPT
            fi
            echo "✔ 已开放: $p"
        else
            [ "$type" == "host_container" ] && ufw delete allow "$p"/tcp >/dev/null 2>&1 || true
            if [ "$target_ip" != "any" ]; then
                iptables -D DOCKER-USER -p tcp -d "$target_ip" --dport "$p" -j ACCEPT 2>/dev/null || true
            fi
            echo "✔ 已关闭: $p"
        fi
    done
}

# 11) 自动识别网桥
auto_allow_docker_bridges() {
    echo "▶ 扫描自定义网桥..."
    docker network ls --filter driver=bridge --format "{{.Name}}" | while read -r net; do
        [ "$net" == "bridge" ] && continue
        local subnet gw
        subnet=$(docker network inspect "$net" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}\b" | head -n 1)
        gw=$(docker network inspect "$net" --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b" | head -n 1)
        [ -z "$subnet" ] && continue
        echo "✔ 网络: $net ($subnet)"
        ufw allow in on "$net" from "$subnet" >/dev/null 2>&1 || true
        iptables -I DOCKER-USER 1 -s "$subnet" -d "$gw" -j ACCEPT 2>/dev/null || true
        iptables -I DOCKER-USER 1 -s "$gw" -d "$subnet" -j ACCEPT 2>/dev/null || true
    done
}

# 10) RackNerd IPv6 修复
fix_ipv6() {
    echo "[*] 修复 RackNerd IPv6..."
    local interface=$(get_main_interface)
    [ -f /etc/sysctl.conf ] && cp /etc/sysctl.conf /etc/sysctl.conf.bak
    cat > "/etc/sysctl.d/99-racknerd-ipv6.conf" <<EOF
net.ipv6.conf.all.autoconf = 0
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.$interface.autoconf = 0
net.ipv6.conf.$interface.accept_ra = 0
EOF
    sysctl --system
    systemctl restart networking || echo "💡 重启后生效"
}

# ==========================
# 菜单
# ==========================
menu() {
    clear
    echo "========================================"
    echo "    Docker + UFW 防火墙管理脚本"
    echo "    (Debian 13 IPv4/v6 稳定版)"
    echo "========================================"
    echo "1) 修复 Docker + UFW 环境 (自动检测)"
    echo "2) 开放容器端口 (仅外网→容器)"
    echo "3) 关闭容器端口 (仅外网→容器)"
    echo "4) 开放宿主机+容器端口 (外网→全通)"
    echo "5) 关闭宿主机+容器端口 (外网→全封)"
    echo "6) 查看当前防火墙规则"
    echo "7) 持久化规则 (防止重启丢失)"
    echo "8) 诊断工具 (排查环境问题)"
    echo "9) 完全还原 (卸载 UFW)"
    echo "10) 安全修复 RackNerd IPv6 并验证"
    echo "11) 自动识别并放行所有 Docker 网桥"
    echo "0) 退出"
    echo "========================================"
    read -rp "请选择 [0-11]: " choice
    case "$choice" in
        1) fix_ufw_docker ;;
        2) manage_ports "container_only" "allow" "$(select_container_ip)" ;;
        3) manage_ports "container_only" "delete" "$(select_container_ip)" ;;
        4) manage_ports "host_container" "allow" "$(select_container_ip)" ;;
        5) manage_ports "host_container" "delete" "$(select_container_ip)" ;;
        6) ufw status numbered; echo ""; iptables -L DOCKER-USER -n --line-numbers ;;
        7) apt install -y iptables-persistent && netfilter-persistent save ;;
        8) iptables --version; ufw status; docker network ls ;;
        9) read -rp "确认卸载？(yes/no): " res; [ "$res" == "yes" ] && { ufw --force disable; apt purge -y ufw; systemctl restart docker; } ;;
        10) fix_ipv6 ;;
        11) auto_allow_docker_bridges ;;
        0) exit 0 ;;
        *) echo "❌ 无效选择" ;;
    esac
    pause
    menu
}

# 补全缺少的 select_container_ip 函数
select_container_ip() {
    local map_file="/tmp/ufw_docker_map"
    rm -f "$map_file"
    local i=1
    printf "\033[32m%-3s | %-20s | %-15s | %s\033[0m\n" "ID" "NAMES" "IP" "STATUS" > /dev/tty
    docker ps -a --format "{{.Names}}" | while read -r name; do
        local ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$name" | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b" | head -n 1)
        [ -z "$ip" ] && ip="no-ip"
        printf "%-3d | %-20s | %-15s | %s\n" "$i" "$name" "$ip" "$(docker inspect -f '{{.State.Status}}' "$name")" > /dev/tty
        echo "$i|$ip|$name" >> "$map_file"
        i=$((i+1))
    done
    echo " 0   | any (仅操作宿主机规则)" > /dev/tty
    read -rp "请选择 ID: " choice
    choice=${choice:-0}
    [ "$choice" == "0" ] && echo "any" || (grep "^$choice|" "$map_file" | cut -d'|' -f2 || echo "any")
}

require_root
menu
