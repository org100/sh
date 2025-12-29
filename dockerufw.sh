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
# 增强的网络检测 (修正 IPv4/IPv6 粘连)
# ==========================
get_docker_network() {
    # 只提取标准的 IPv4 段格式 (如 172.17.0.0/16)
    local net
    net=$(docker network inspect bridge --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}\b" | head -n 1)
    echo "${net:-172.17.0.0/16}"
}

get_docker_gateway() {
    # 只提取标准的 IPv4 地址格式
    local gw
    gw=$(docker network inspect bridge --format '{{range .IPAM.Config}}{{.Gateway}} {{end}}' 2>/dev/null | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b" | head -n 1)
    echo "${gw:-172.17.0.1}"
}

# 动态获取主网卡名 (防止 Debian 13 并非 eth0)
get_main_interface() {
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
            echo "💡 建议切换到 iptables-nft"
            read -rp "是否切换？(y/n): " switch
            if [ "$switch" == "y" ]; then
                update-alternatives --set iptables /usr/sbin/iptables-nft
                update-alternatives --set ip6tables /usr/sbin/ip6tables-nft
                systemctl restart docker
            fi
        fi
    fi
}

# ==========================
# 修复 Docker + UFW 环境
# ==========================
fix_ufw_docker() {
    echo "▶ 正在执行环境修复..."
    check_nftables_compat
    apt update -y && apt install -y ufw nftables

    SSH_PORT=$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}' || echo "22")
    echo "✔ SSH 端口: $SSH_PORT，已预放行..."
    ufw allow "$SSH_PORT"/tcp >/dev/null 2>&1 || true

    mkdir -p "$BACKUP_DIR"
    [ -f "$UFW_AFTER" ] && cp "$UFW_AFTER" "$BACKUP_FILE" && echo "✔ 原配置已备份: $BACKUP_FILE"

    DOCKER_SUBNET=$(get_docker_network)
    DOCKER_GW=$(get_docker_gateway)
    echo "✔ 识别到 Docker 网络: $DOCKER_SUBNET (网关: $DOCKER_GW)"

    # 修改默认转发策略
    sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

    # 写入正确的 after.rules
    cat > "$UFW_AFTER" <<EOF
*filter
:ufw-user-forward - [0:0]
:ufw-docker-logging-deny - [0:0]
:DOCKER-USER - [0:0]

# 宿主机 <-> 容器互通 (IPv4)
-A DOCKER-USER -s $DOCKER_SUBNET -d $DOCKER_GW -j ACCEPT
-A DOCKER-USER -s $DOCKER_GW -d $DOCKER_SUBNET -j ACCEPT

# 局域网全放行
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

    echo "▶ 正在重启服务并应用规则..."
    ufw --force enable
    systemctl restart docker
    sleep 1
    systemctl restart ufw || { echo "❌ UFW 启动失败，请检查 /etc/ufw/after.rules"; exit 1; }

    echo "========================================="
    echo "✔ 环境修复完成！"
    echo "========================================="
}

# ==========================
# 功能 10: RackNerd IPv6 修复
# ==========================
fix_ipv6() {
    echo "[*] 开始安全修复 RackNerd IPv6 配置..."
    local interface
    interface=$(get_main_interface)
    echo "[*] 检测到主网卡: $interface"

    CUSTOM_CONF="/etc/sysctl.d/99-racknerd-ipv6.conf"
    cat > "$CUSTOM_CONF" <<EOF
# RackNerd IPv6 Fix for $interface
net.ipv6.conf.all.autoconf = 0
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.$interface.autoconf = 0
net.ipv6.conf.$interface.accept_ra = 0
EOF
    sysctl --system
    systemctl restart networking || echo "⚠️  网络重启失败，通常重启实例(reboot)后生效"
    echo "[✓] IPv6 配置已写入，尝试测试中..."
    ping6 -c 3 google.com >/dev/null 2>&1 && echo "[✓] IPv6 连通性测试成功" || echo "[⚠️] IPv6 仍不通，建议重启实例"
}

# ... (此处省略 select_container_ip, manage_host_and_container 等原本正常的函数) ...

# 由于篇幅，我这里直接放菜单和之前正常的管理函数 (已补齐)

select_container_ip() {
    local map_file="/tmp/ufw_docker_map"
    rm -f "$map_file"
    local i=1
    printf "\033[32m--- 实时 Docker 容器列表 ---\033[0m\n" > /dev/tty
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
    echo " 0   | any (全部容器)" > /dev/tty
    
    local choice
    read -rp "请选择 ID [默认 0]: " choice
    choice=${choice:-0}
    if [ "$choice" == "0" ]; then echo "any"; else
        grep "^$choice|" "$map_file" | cut -d'|' -f2 || echo "any"
    fi
}

manage_host_and_container() {
    local action=$1
    local target_ip=$2
    read -rp "请输入端口 (如 80 443): " port_input
    for p in $port_input; do
        if [ "$action" == "allow" ]; then
            ufw allow "$p"/tcp
            [ "$target_ip" != "any" ] && iptables -I DOCKER-USER 1 -p tcp -d "$target_ip" --dport "$p" -j ACCEPT
        else
            ufw delete allow "$p"/tcp || true
            [ "$target_ip" != "any" ] && iptables -D DOCKER-USER -p tcp -d "$target_ip" --dport "$p" -j ACCEPT 2>/dev/null || true
        fi
    done
    echo "✔ 操作完成"
}

menu() {
    clear
    echo "========================================"
    echo "    Docker + UFW 防火墙管理脚本"
    echo "    (Debian 13 IPv4/v6 修复版)"
    echo "========================================"
    echo "1) 修复 Docker + UFW 环境 (解决报错)"
    echo "2) 开放端口 (宿主机 + 容器)"
    echo "3) 关闭端口 (宿主机 + 容器)"
    echo "6) 查看当前规则"
    echo "10) 修复 RackNerd IPv6"
    echo "0) 退出"
    echo "========================================"
    read -rp "请选择: " choice
    case "$choice" in
        1) fix_ufw_docker ;;
        2) manage_host_and_container "allow" "$(select_container_ip)" ;;
        3) manage_host_and_container "delete" "$(select_container_ip)" ;;
        6) ufw status numbered; iptables -L DOCKER-USER -n --line-numbers ;;
        10) fix_ipv6 ;;
        0) exit 0 ;;
    esac
    pause
    menu
}

require_root
menu
