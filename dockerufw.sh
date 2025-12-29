#!/usr/bin/env bash
set -e

UFW_AFTER="/etc/ufw/after.rules"
BACKUP_FILE="/root/ufw-backup/after.rules.$(date +%Y%m%d_%H%M%S)"

require_root() { [ "$EUID" -eq 0 ] || { echo "❌ 请使用 root 运行"; exit 1; } }
pause() { echo ""; read -rp "按回车继续..." ; }

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
            echo "💡 Debian 13 默认配置，建议继续使用"
            return 0
        elif echo "$ipt_version" | grep -q "legacy"; then
            echo "⚠️  当前使用: iptables-legacy (传统模式)"
            echo "💡 建议切换到 iptables-nft 以获得更好的兼容性"
            read -rp "是否切换到 iptables-nft？(y/n): " switch
            if [ "$switch" == "y" ]; then
                update-alternatives --set iptables /usr/sbin/iptables-nft
                update-alternatives --set ip6tables /usr/sbin/ip6tables-nft
                echo "✔ 已切换到 iptables-nft，需要重启 Docker"
                systemctl restart docker
            fi
            return 0
        fi
    fi
    
    echo "ℹ️  传统 iptables 系统"
    return 0
}

# 验证规则是否真实生效
verify_rules_active() {
    echo ""
    echo "▶ 验证规则是否生效..."
    
    if command -v nft >/dev/null 2>&1; then
        echo "--- nftables 表列表 ---"
        nft list tables 2>/dev/null || echo "无 nftables 表"
        
        if nft list table ip filter 2>/dev/null | grep -q DOCKER; then
            echo "✔ Docker 规则已加载到 nftables"
        else
            echo "⚠️  未检测到 Docker nftables 规则"
        fi
    fi
    
    echo ""
    echo "--- iptables DOCKER-USER 链 ---"
    if iptables -L DOCKER-USER -n 2>/dev/null | grep -q "Chain DOCKER-USER"; then
        echo "✔ DOCKER-USER 链存在"
        iptables -L DOCKER-USER -n --line-numbers | head -n 10
    else
        echo "⚠️  DOCKER-USER 链不存在"
    fi
}

# 自动检测 SSH 端口
get_ssh_port() {
    local port
    port=$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}')
    echo "${port:-22}"
}

# 获取 Docker 网络段
get_docker_network() {
    docker network inspect bridge --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || echo "172.17.0.0/16"
}

get_docker_gateway() {
    docker network inspect bridge --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null || echo "172.17.0.1"
}

# ==========================
# 修复 Docker + UFW 环境
# ==========================
fix_ufw_docker() {
    echo "▶ 正在执行环境修复..."
    
    check_nftables_compat
    
    apt update -y && apt install -y ufw nftables

    SSH_PORT=$(get_ssh_port)
    echo "✔ 检测到 SSH 端口: $SSH_PORT，正在预放行..."
    ufw allow "$SSH_PORT"/tcp >/dev/null 2>&1 || true

    [ -f "$UFW_AFTER" ] && { mkdir -p "$(dirname "$BACKUP_FILE")"; cp "$UFW_AFTER" "$BACKUP_FILE"; echo "✔ 原配置已备份: $BACKUP_FILE"; }

    DOCKER_SUBNET=$(get_docker_network)
    DOCKER_GW=$(get_docker_gateway)
    echo "✔ 检测到 Docker 网络: $DOCKER_SUBNET (网关: $DOCKER_GW)"

    sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

    cat > "$UFW_AFTER" <<EOF
*filter
:ufw-user-forward - [0:0]
:ufw-docker-logging-deny - [0:0]
:DOCKER-USER - [0:0]

# 宿主机 <-> 容器互通
-A DOCKER-USER -s $DOCKER_SUBNET -d $DOCKER_GW -j ACCEPT
-A DOCKER-USER -s $DOCKER_GW -d $DOCKER_SUBNET -j ACCEPT

# 局域网全放行
-A DOCKER-USER -s 10.0.0.0/8 -j RETURN
-A DOCKER-USER -s 172.16.0.0/12 -j RETURN
-A DOCKER-USER -s 192.168.0.0/16 -j RETURN
-A DOCKER-USER -p udp --sport 53 --dport 1024:65535 -j RETURN

# 默认规则
-A DOCKER-USER -j ufw-user-forward
-A DOCKER-USER -j ufw-docker-logging-deny
-A ufw-docker-logging-deny -m limit --limit 3/min --limit-burst 10 -j LOG --log-prefix "[UFW DOCKER BLOCK] "
-A ufw-docker-logging-deny -j DROP
COMMIT
EOF

    ufw --force enable
    systemctl restart docker
    sleep 2
    systemctl restart ufw
    
    verify_rules_active
    
    echo ""
    echo "========================================="
    echo "✔ 修复完成！安全策略："
    echo "  - 后端: $(iptables --version | grep -o 'nf_tables\|legacy' || echo 'iptables')"
    echo "  - 内网（私有网段）: 完全放行"
    echo "  - 宿主机 ↔ 容器: 互通"
    echo "  - 外网访问: UFW 精确控制"
    echo "  - SSH端口 $SSH_PORT: 已放行"
    echo "========================================="
}

# ==========================
# 容器选择逻辑
# ==========================
select_container_ip() {
    local map_file="/tmp/ufw_docker_map"
    rm -f "$map_file"
    local i=1

    printf "\033[32m--- 实时 Docker 容器列表 ---\033[0m\n" > /dev/tty
    printf "\033[33m%-3s | %-20s | %-15s | %s\033[0m\n" "ID" "NAMES" "IP" "STATUS" > /dev/tty

    while read -r name; do
        [ -z "$name" ] && continue
        local ip
        ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$name" | head -n 1)
        [ -z "$ip" ] && ip="no-ip"
        ip=$(echo "$ip" | tr -d '[:space:]')
        local status
        status=$(docker inspect -f '{{.State.Status}}' "$name")
        printf "%-3d | %-20s | %-15s | %s\n" "$i" "$name" "$ip" "$status" > /dev/tty
        echo "$i|$ip|$name" >> "$map_file"
        i=$((i+1))
    done <<< "$(docker ps -a --format "{{.Names}}")"

    printf " 0   | any (全部容器)\n" > /dev/tty
    printf "\033[32m----------------------------\033[0m\n" > /dev/tty

    local choice res
    while true; do
        read -rp "请选择 ID 或输入容器名 [默认 0 = any]: " choice
        choice=${choice:-0}
        if [ "$choice" == "0" ] || [ "$choice" == "any" ]; then
            rm -f "$map_file"; echo "any"; return
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            res=$(grep "^$choice|" "$map_file" | cut -d'|' -f2 || true)
            [ -z "$res" ] && res="any"
            res=$(echo "$res" | tr -d '[:space:]')
            if [ -n "$res" ]; then rm -f "$map_file"; echo "$res"; return; fi
        fi
        if docker inspect "$choice" >/dev/null 2>&1; then
            res=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$choice" | head -n 1)
            [ -z "$res" ] && res="any"
            res=$(echo "$res" | tr -d '[:space:]')
            rm -f "$map_file"; echo "$res"; return
        fi
        echo "❌ 无效输入，请重新选择。"
    done
}

check_iptables_rule_exists() {
    local target_ip=$1
    local port=$2
    iptables -C DOCKER-USER -p tcp -d "$target_ip" --dport "$port" -j ACCEPT 2>/dev/null
}

# ==========================
# 端口管理逻辑
# ==========================
manage_container_only() {
    local action=$1
    local target_ip=$2
    local port_input

    [ -z "$target_ip" ] || [ "$target_ip" == "any" ] || [ "$target_ip" == "no-ip" ] && {
        echo "❌ 必须选择具体的容器 IP，不能使用 'any'"
        return 1
    }

    read -rp "请输入端口 (空格分隔): " port_input
    local ports=(${port_input// / })
    [ ${#ports[@]} -eq 0 ] && { echo "❌ 端口不能为空"; return 1; }

    for p in "${ports[@]}"; do
        if [ "$action" == "allow" ]; then
            if check_iptables_rule_exists "$target_ip" "$p"; then
                echo "⚠️  容器规则已存在: $target_ip:$p"
            else
                iptables -I DOCKER-USER 1 -p tcp -d "$target_ip" --dport "$p" -j ACCEPT
                echo "✔ 已添加容器规则: $target_ip:$p"
            fi
        else
            if iptables -D DOCKER-USER -p tcp -d "$target_ip" --dport "$p" -j ACCEPT 2>/dev/null; then
                echo "✔ 已删除容器规则: $target_ip:$p"
            fi
        fi
    done
}

manage_host_and_container() {
    local action=$1
    local target_ip=$2
    local port_input

    read -rp "请输入端口 (空格分隔): " port_input
    local ports=(${port_input// / })
    [ ${#ports[@]} -eq 0 ] && { echo "❌ 端口不能为空"; return 1; }

    for p in "${ports[@]}"; do
        if [ "$action" == "allow" ]; then
            ufw allow "$p"/tcp >/dev/null 2>&1
            if [ "$target_ip" != "any" ] && [ -n "$target_ip" ]; then
                iptables -I DOCKER-USER 1 -p tcp -d "$target_ip" --dport "$p" -j ACCEPT
            fi
            echo "✔ 已开放: $p"
        else
            # 删除宿主机规则
            while true; do
                rule_num=$(ufw status numbered | grep -E "^\[[0-9]+\].*$p/tcp" | head -n 1 | awk -F'[][]' '{print $2}')
                [ -z "$rule_num" ] && break
                echo "y" | ufw delete "$rule_num" >/dev/null 2>&1
            done
            # 删除容器规则
            if [ "$target_ip" != "any" ]; then
                iptables -D DOCKER-USER -p tcp -d "$target_ip" --dport "$p" -j ACCEPT 2>/dev/null || true
            fi
            echo "✔ 已关闭: $p"
        fi
    done
}

# ==========================
# 规则持久化与查看
# ==========================
save_iptables_rules() {
    echo "▶ 正在持久化防火墙规则..."
    if iptables --version | grep -q "nf_tables"; then
        if command -v nft >/dev/null 2>&1; then
            mkdir -p /etc/nftables
            nft list ruleset > /etc/nftables/ruleset.nft
            echo "✔ nftables 规则已保存"
        fi
    fi
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save
        echo "✔ 规则已通过 netfilter-persistent 保存"
    fi
}

show_rules() {
    echo "========== UFW 规则 =========="
    ufw status numbered
    echo ""
    echo "========== DOCKER-USER 链 =========="
    iptables -L DOCKER-USER -n -v --line-numbers 2>/dev/null
}

diagnose_firewall() {
    echo "--- 防火墙诊断 ---"
    iptables --version
    ufw status
    iptables -L DOCKER-USER -n | head -n 5
}

# ==========================
# 功能 10: RackNerd IPv6 修复
# ==========================
fix_ipv6() {
    echo "[*] 开始安全修复 RackNerd IPv6 配置..."
    SYSCTL_CONF="/etc/sysctl.conf"
    CUSTOM_CONF="/etc/sysctl.d/99-racknerd-ipv6.conf"
    
    if [ -f "$SYSCTL_CONF" ]; then
        cp "$SYSCTL_CONF" "${SYSCTL_CONF}.bak_$(date +%F_%H-%M-%S)"
        echo "[*] 已备份 $SYSCTL_CONF"
    fi

    cat > "$CUSTOM_CONF" <<EOF
# RackNerd IPv6 Fix
net.ipv6.conf.all.autoconf = 0
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.eth0.autoconf = 0
net.ipv6.conf.eth0.accept_ra = 0
EOF
    echo "[*] 已写入自定义 IPv6 配置到 $CUSTOM_CONF"
    echo "[*] 应用 sysctl 配置..."
    sysctl --system
    echo "[*] 重启网络服务..."
    systemctl restart networking || echo "⚠️  网络服务重启失败，建议手动 reboot"
    
    echo "[*] 验证 IPv6 连通性..."
    if ping6 -c 3 google.com >/dev/null 2>&1; then
        echo "[✓] IPv6 ping 测试成功"
    else
        echo "[⚠️] IPv6 ping 测试失败"
    fi
    
    if curl -6 -s --max-time 5 ipv6.ip.sb >/dev/null 2>&1; then
        echo "[✓] IPv6 curl 测试成功"
    else
        echo "[⚠️] IPv6 curl 测试失败"
    fi
    echo "[✓] IPv6 配置处理完成"
}

# ==========================
# 菜单
# ==========================
menu() {
    clear
    echo "========================================"
    echo "    Docker + UFW 防火墙管理脚本"
    echo "    (Debian 13 nftables 优化版)"
    echo "========================================"
    echo "1) 修复 Docker + UFW 环境 (自动检测)"
    echo "2) 开放容器端口 (仅外网→容器)"
    echo "3) 关闭容器端口 (仅外网→容器)"
    echo "4) 开放宿主机+容器端口 (外网→全通)"
    echo "5) 关闭宿主机+容器端口 (外网→全封)"
    echo "6) 查看当前防火墙规则"
    echo "7) 持久化规则 (防止重启丢失)"
    echo "8) 诊断工具 (排查兼容性问题)"
    echo "9) 完全还原 (卸载 UFW)"
    echo "10) 安全修复 RackNerd IPv6 并验证"
    echo "0) 退出"
    echo "========================================"
    read -rp "请选择 [0-10]: " choice
    case "$choice" in
        1) fix_ufw_docker ;;
        2) manage_container_only "allow" "$(select_container_ip)" ;;
        3) manage_container_only "delete" "$(select_container_ip)" ;;
        4) manage_host_and_container "allow" "$(select_container_ip)" ;;
        5) manage_host_and_container "delete" "$(select_container_ip)" ;;
        6) show_rules ;;
        7) save_iptables_rules ;;
        8) diagnose_firewall ;;
        9) 
            read -rp "⚠️  确认卸载 UFW？(yes/no): " confirm
            [ "$confirm" == "yes" ] && { ufw --force disable; apt purge -y ufw; systemctl restart docker; }
            ;;
        10) fix_ipv6 ;;
        0) exit 0 ;;
        *) echo "❌ 无效选择" ;;
    esac
    pause
    menu
}

require_root
menu
