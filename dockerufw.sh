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
    
    # 检查是否是 nftables 系统
    if [ -f /proc/sys/net/netfilter/nf_tables_api_version ]; then
        echo "✔ 系统支持 nftables"
        
        # 检查 iptables 实现
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

# 验证规则是否真实生效（nftables 兼容性检查）
verify_rules_active() {
    echo ""
    echo "▶ 验证规则是否生效..."
    
    # 检查 nftables 表
    if command -v nft >/dev/null 2>&1; then
        echo "--- nftables 表列表 ---"
        nft list tables 2>/dev/null || echo "无 nftables 表"
        
        # 检查是否有 Docker 相关的表
        if nft list table ip filter 2>/dev/null | grep -q DOCKER; then
            echo "✔ Docker 规则已加载到 nftables"
        else
            echo "⚠️  未检测到 Docker nftables 规则"
        fi
    fi
    
    # 检查 iptables 规则
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

# 获取 Docker 网络段（自动检测）
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
    
    # 先检查兼容性
    check_nftables_compat
    
    apt update -y && apt install -y ufw nftables

    SSH_PORT=$(get_ssh_port)
    echo "✔ 检测到 SSH 端口: $SSH_PORT，正在预放行..."
    ufw allow "$SSH_PORT"/tcp >/dev/null 2>&1 || true

    # 备份原配置
    [ -f "$UFW_AFTER" ] && { mkdir -p "$(dirname "$BACKUP_FILE")"; cp "$UFW_AFTER" "$BACKUP_FILE"; echo "✔ 原配置已备份: $BACKUP_FILE"; }

    # 自动检测 Docker 网络
    DOCKER_SUBNET=$(get_docker_network)
    DOCKER_GW=$(get_docker_gateway)
    echo "✔ 检测到 Docker 网络: $DOCKER_SUBNET (网关: $DOCKER_GW)"

    # 设置 UFW 默认允许转发
    sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

    # DOCKER-USER 链规则（兼容 iptables-nft）
    cat > "$UFW_AFTER" <<EOF
*filter
:ufw-user-forward - [0:0]
:ufw-docker-logging-deny - [0:0]
:DOCKER-USER - [0:0]

# 宿主机 <-> 容器互通（自动检测的网络）
-A DOCKER-USER -s $DOCKER_SUBNET -d $DOCKER_GW -j ACCEPT
-A DOCKER-USER -s $DOCKER_GW -d $DOCKER_SUBNET -j ACCEPT

# 局域网全放行（内网信任域）
-A DOCKER-USER -s 10.0.0.0/8 -j RETURN
-A DOCKER-USER -s 172.16.0.0/12 -j RETURN
-A DOCKER-USER -s 192.168.0.0/16 -j RETURN
-A DOCKER-USER -p udp --sport 53 --dport 1024:65535 -j RETURN

# 默认规则（外网流量交由 UFW 控制）
-A DOCKER-USER -j ufw-user-forward
-A DOCKER-USER -j ufw-docker-logging-deny
-A ufw-docker-logging-deny -m limit --limit 3/min --limit-burst 10 -j LOG --log-prefix "[UFW DOCKER BLOCK] "
-A ufw-docker-logging-deny -j DROP
COMMIT
EOF

    # 重启服务（确保 nftables 兼容层正确加载）
    ufw --force enable
    systemctl restart docker
    sleep 2
    systemctl restart ufw
    
    # 验证规则
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
    echo ""
    echo "💡 提示：如遇到规则不生效，执行选项 9 进行诊断"
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

# 检查 iptables 规则是否存在（兼容 nftables）
check_iptables_rule_exists() {
    local target_ip=$1
    local port=$2
    iptables -C DOCKER-USER -p tcp -d "$target_ip" --dport "$port" -j ACCEPT 2>/dev/null
}

# ==========================
# 只操作容器端口 (仅 DOCKER-USER 链)
# ==========================
manage_container_only() {
    local action=$1
    local target_ip=$2
    local port_input

    [ -z "$target_ip" ] || [ "$target_ip" == "any" ] || [ "$target_ip" == "no-ip" ] && {
        echo "❌ 必须选择具体的容器 IP，不能使用 'any'"
        return 1
    }

    read -rp "请输入端口 (空格分隔, 如: 80 443): " port_input
    local ports=(${port_input// / })
    [ ${#ports[@]} -eq 0 ] && { echo "❌ 端口不能为空"; return 1; }

    for p in "${ports[@]}"; do
        [ -z "$p" ] && continue
        
        if ! [[ "$p" =~ ^[0-9]+$ ]] || [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
            echo "❌ 无效端口: $p (必须是 1-65535)"
            continue
        fi

        if [ "$action" == "allow" ]; then
            if check_iptables_rule_exists "$target_ip" "$p"; then
                echo "⚠️  容器规则已存在，跳过: $target_ip:$p"
            else
                iptables -I DOCKER-USER 1 -p tcp -d "$target_ip" --dport "$p" -j ACCEPT
                echo "✔ 已添加容器规则: $target_ip:$p"
            fi
        else
            if iptables -D DOCKER-USER -p tcp -d "$target_ip" --dport "$p" -j ACCEPT 2>/dev/null; then
                echo "✔ 已删除容器规则: $target_ip:$p"
            else
                echo "⚠️  容器规则不存在，跳过: $target_ip:$p"
            fi
        fi
    done
    
    echo ""
    echo "💡 提示：容器规则仅控制外网→容器，内网访问始终放行"
}

# ==========================
# 同时操作宿主机+容器端口
# ==========================
manage_host_and_container() {
    local action=$1
    local target_ip=$2
    local port_input

    SSH_PORT=$(get_ssh_port)
    ufw allow "$SSH_PORT"/tcp >/dev/null 2>&1 || true

    read -rp "请输入端口 (空格分隔, 如: 80 443 8080): " port_input
    local ports=(${port_input// / })
    [ ${#ports[@]} -eq 0 ] && { echo "❌ 端口不能为空"; return 1; }

    for p in "${ports[@]}"; do
        [ -z "$p" ] && continue
        
        if ! [[ "$p" =~ ^[0-9]+$ ]] || [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
            echo "❌ 无效端口: $p"
            continue
        fi

        echo "正在处理: $p ..."

        if [ "$action" == "allow" ]; then
            # UFW 宿主机规则
            if ufw allow "$p"/tcp >/dev/null 2>&1; then
                echo "  ✔ 宿主机规则: $p/tcp"
            fi
            
            # DOCKER-USER 容器规则（如果指定了 IP）
            if [ "$target_ip" != "any" ] && [ "$target_ip" != "no-ip" ] && [ -n "$target_ip" ]; then
                if check_iptables_rule_exists "$target_ip" "$p"; then
                    echo "  ⚠️  容器规则已存在: $target_ip:$p"
                else
                    iptables -I DOCKER-USER 1 -p tcp -d "$target_ip" --dport "$p" -j ACCEPT
                    echo "  ✔ 容器规则: $target_ip:$p"
                fi
            fi
        else
            # 删除 UFW 规则（精确匹配）
            local deleted=0
            while true; do
                rule_num=$(ufw status numbered 2>/dev/null | grep -E "^\[[0-9]+\].*ALLOW.*$p/tcp" | head -n 1 | awk -F'[][]' '{print $2}')
                [ -z "$rule_num" ] && break
                echo "y" | ufw delete "$rule_num" >/dev/null 2>&1 && deleted=1
            done
            [ "$deleted" -eq 1 ] && echo "  ✔ 已删除宿主机规则: $p/tcp" || echo "  ⚠️  宿主机无规则: $p/tcp"
            
            # 删除 DOCKER-USER 规则
            if [ "$target_ip" != "any" ] && [ "$target_ip" != "no-ip" ] && [ -n "$target_ip" ]; then
                if iptables -D DOCKER-USER -p tcp -d "$target_ip" --dport "$p" -j ACCEPT 2>/dev/null; then
                    echo "  ✔ 已删除容器规则: $target_ip:$p"
                else
                    echo "  ⚠️  容器无规则: $target_ip:$p"
                fi
            fi
        fi
    done
    
    echo ""
    echo "✔ 操作完成！"
}

# ==========================
# 持久化规则（兼容 nftables）
# ==========================
save_iptables_rules() {
    echo "▶ 正在持久化防火墙规则..."
    
    # 检查是否使用 nftables
    if iptables --version 2>/dev/null | grep -q "nf_tables"; then
        echo "ℹ️  检测到 nftables 后端"
        
        # nftables 持久化
        if command -v nft >/dev/null 2>&1; then
            mkdir -p /etc/nftables
            nft list ruleset > /etc/nftables/ruleset.nft 2>/dev/null || true
            echo "✔ nftables 规则已保存到 /etc/nftables/ruleset.nft"
        fi
    fi
    
    # iptables 持久化
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save
        echo "✔ 规则已通过 netfilter-persistent 保存"
    elif command -v iptables-save >/dev/null 2>&1; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        echo "✔ iptables 规则已保存到 /etc/iptables/rules.v4"
    fi
    
    echo ""
    echo "💡 建议安装持久化工具："
    echo "   apt install iptables-persistent netfilter-persistent"
}

# ==========================
# 查看规则
# ==========================
show_rules() {
    echo "========== 系统信息 =========="
    echo "iptables 版本: $(iptables --version)"
    echo "Docker 网络: $(get_docker_network) (网关: $(get_docker_gateway))"
    echo ""
    
    echo "========== UFW 规则 =========="
    ufw status numbered
    echo ""
    
    echo "========== DOCKER-USER 链 =========="
    iptables -L DOCKER-USER -n -v --line-numbers 2>/dev/null || echo "DOCKER-USER 链不存在"
    echo ""
    
    # 如果是 nftables，显示额外信息
    if command -v nft >/dev/null 2>&1 && iptables --version | grep -q "nf_tables"; then
        echo "========== nftables 表 (底层) =========="
        nft list tables 2>/dev/null || echo "无 nftables 表"
    fi
}

# ==========================
# 诊断工具（针对 nftables 兼容性问题）
# ==========================
diagnose_firewall() {
    echo "========================================="
    echo "       防火墙诊断工具 (Debian 13)"
    echo "========================================="
    echo ""
    
    echo "▶ 1. 检测 iptables 后端"
    iptables --version
    echo ""
    
    echo "▶ 2. 检测 alternatives 配置"
    update-alternatives --display iptables 2>/dev/null | grep "link currently" || echo "无 alternatives 配置"
    echo ""
    
    echo "▶ 3. 检测 Docker 是否运行"
    systemctl is-active docker && echo "✔ Docker 运行中" || echo "❌ Docker 未运行"
    echo ""
    
    echo "▶ 4. 检测 UFW 状态"
    ufw status verbose
    echo ""
    
    echo "▶ 5. 检测 DOCKER-USER 链"
    if iptables -L DOCKER-USER -n 2>/dev/null | grep -q "Chain DOCKER-USER"; then
        echo "✔ DOCKER-USER 链存在"
        iptables -L DOCKER-USER -n -v --line-numbers
    else
        echo "❌ DOCKER-USER 链不存在（可能需要重启 Docker）"
    fi
    echo ""
    
    echo "▶ 6. 检测 nftables 规则（如果使用 nf_tables）"
    if command -v nft >/dev/null 2>&1 && iptables --version | grep -q "nf_tables"; then
        echo "当前使用 nftables 后端"
        nft list ruleset 2>/dev/null | grep -A 5 "DOCKER" || echo "未找到 Docker 相关规则"
    else
        echo "使用传统 iptables 后端"
    fi
    echo ""
    
    echo "▶ 7. 常见问题修复建议"
    echo "问题1: 规则不生效"
    echo "  解决: systemctl restart docker && systemctl restart ufw"
    echo ""
    echo "问题2: iptables 命令报错"
    echo "  解决: update-alternatives --set iptables /usr/sbin/iptables-nft"
    echo ""
    echo "问题3: DOCKER-USER 链消失"
    echo "  解决: docker network ls (触发 Docker 重建链)"
    echo ""
    echo "========================================="
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
    echo "4) 开放宿主机+容器端口 (外网→宿主机+容器)"
    echo "5) 关闭宿主机+容器端口 (外网→宿主机+容器)"
    echo "6) 查看当前防火墙规则"
    echo "7) 持久化规则 (防止重启丢失)"
    echo "8) 诊断工具 (排查 nftables 兼容性问题)"
    echo "9) 完全还原 (卸载 UFW)"
    echo "0) 退出"
    echo "========================================"
    read -rp "请选择 [0-9]: " choice
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
            read -rp "⚠️  确认卸载 UFW 并重置防火墙？(yes/no): " confirm
            if [ "$confirm" == "yes" ]; then
                ufw --force disable
                apt purge -y ufw
                rm -rf /etc/ufw
                systemctl restart docker
                echo "✔ UFW 已完全卸载"
            else
                echo "❌ 已取消"
            fi
            ;;
        0) exit 0 ;;
        *) echo "❌ 无效选择" ;;
    esac
    pause
    menu
}

require_root
menu
