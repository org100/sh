#!/usr/bin/env bash
set -e

UFW_AFTER="/etc/ufw/after.rules"
BACKUP_DIR="/root/ufw-backup"

require_root() { [ "$EUID" -eq 0 ] || { echo "❌ 请使用 root 运行"; exit 1; } }
pause() { echo ""; read -rp "按回车继续..." ; }

# ==========================
# SSH 端口检测
# ==========================
get_ssh_port() {
    local port
    if command -v sshd >/dev/null 2>&1; then
        port=$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}')
    fi
    [ -z "$port" ] && port=22
    echo "$port"
}

# ==========================
# 修复 Docker + UFW
# ==========================
fix_ufw_docker() {
    echo "▶ 修复 Docker + UFW"
    apt update -y
    apt install -y ufw
    mkdir -p "$BACKUP_DIR"
    cp -a /etc/ufw "$BACKUP_DIR/" 2>/dev/null || true

    SSH_PORT=$(get_ssh_port)
    echo "✔ 检测到 SSH 端口: $SSH_PORT"

    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "$SSH_PORT"/tcp

    # 写入 after.rules
    if ! grep -q "BEGIN UFW AND DOCKER" "$UFW_AFTER"; then
        cat > "$UFW_AFTER" <<'EOF'
# BEGIN UFW AND DOCKER
*filter
:ufw-user-forward - [0:0]
:ufw-docker-logging-deny - [0:0]
:DOCKER-USER - [0:0]

-A DOCKER-USER -j ufw-user-forward
-A DOCKER-USER -s 10.0.0.0/8 -j RETURN
-A DOCKER-USER -s 172.16.0.0/12 -j RETURN
-A DOCKER-USER -s 192.168.0.0/16 -j RETURN
-A DOCKER-USER -p udp --sport 53 --dport 1024:65535 -j RETURN
-A DOCKER-USER -j ufw-docker-logging-deny
-A ufw-docker-logging-deny -m limit --limit 3/min --limit-burst 10 -j LOG --log-prefix "[UFW DOCKER BLOCK] "
-A ufw-docker-logging-deny -j DROP
COMMIT
# END UFW AND DOCKER
EOF
        echo "✔ after.rules 已写入"
    fi

    ufw --force enable
    systemctl restart ufw
    echo "✔ Docker + UFW 修复完成"
}

# ==========================
# 容器端口交互函数 (修复显示问题)
# ==========================
select_container_ip() {
    echo "正在获取 Docker 容器列表..."
    echo "------------------------------------------------"
    printf "%-4s | %-20s | %-15s | %-10s\n" "ID" "容器名称" "IP地址" "状态"
    echo "------------------------------------------------"
    
    local tmp_map="/tmp/docker_map.txt"
    rm -f "$tmp_map"
    
    local i=1
    # 使用 Here-string 避免子进程问题，确保输出实时显示
    while IFS='|' read -r name state; do
        [ -z "$name" ] && continue
        
        # 实时通过 inspect 获取 IP
        local ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$name" | head -n 1)
        [ -z "$ip" ] && ip="Internal"
        
        printf "%-4d | %-20s | %-15s | %-10s\n" "$i" "$name" "$ip" "$state"
        
        # 将编号映射存入临时文件
        echo "$i|$ip|$name" >> "$tmp_map"
        i=$((i+1))
    done <<< "$(docker ps -a --format "{{.Names}}|{{.State}}")"

    if [ ! -f "$tmp_map" ]; then
        echo "❌ 当前没有 Docker 容器"
        echo "any"
        return
    fi

    echo " 0    | any (全部容器)"
    echo "------------------------------------------------"

    while true; do
        read -rp "请选择容器编号 (ID) 或直接输入名称 [默认 0]: " choice
        choice=${choice:-0}

        if [ "$choice" == "0" ] || [ "$choice" == "any" ]; then
            echo "any"
            rm -f "$tmp_map"
            return
        fi

        # 如果输入的是数字 ID
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            local target_ip=$(grep "^$choice|" "$tmp_map" | cut -d'|' -f2)
            if [ -n "$target_ip" ]; then
                echo "$target_ip"
                rm -f "$tmp_map"
                return
            fi
        fi

        # 如果输入的是容器名称
        if docker inspect "$choice" >/dev/null 2>&1; then
            local target_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$choice" | head -n 1)
            echo "${target_ip:-any}"
            rm -f "$tmp_map"
            return
        fi

        echo "❌ 输入无效，请重新选择编号或输入名称"
    done
}

ask_port() {
    local port
    while true; do
        read -rp "请输入端口 (例如 80, 留空默认为 any): " port
        port=${port:-any}
        [[ -n "$port" ]] && break
    done
    echo "$port"
}

# ==========================
# 操作函数
# ==========================
allow_docker() {
    echo "▶ 只开放 Docker 容器端口 (不影响宿主机)"
    local ip port
    ip=$(select_container_ip)
    port=$(ask_port)
    
    if [ "$ip" == "any" ] && [ "$port" == "any" ]; then
        ufw route allow from any to any
    elif [ "$ip" == "any" ]; then
        ufw route allow proto tcp from any to any port "$port"
    elif [ "$port" == "any" ]; then
        ufw route allow from any to "$ip"
    else
        ufw route allow proto tcp from any to "$ip" port "$port"
    fi
    echo "✔ 规则已成功添加: To: $ip Port: $port"
}

deny_docker() {
    echo "▶ 只关闭 Docker 容器端口 (不影响宿主机)"
    local ip port
    ip=$(select_container_ip)
    port=$(ask_port)
    
    if [ "$ip" == "any" ] && [ "$port" == "any" ]; then
        ufw route delete allow from any to any 2>/dev/null || true
    elif [ "$ip" == "any" ]; then
        ufw route delete allow proto tcp from any to any port "$port" 2>/dev/null || true
    elif [ "$port" == "any" ]; then
        ufw route delete allow from any to "$ip" 2>/dev/null || true
    else
        ufw route delete allow proto tcp from any to "$ip" port "$port" 2>/dev/null || true
    fi
    echo "✔ 尝试删除规则完成"
}

allow_all() {
    echo "▶ 同时开放宿主机 + 容器端口"
    read -rp "请输入端口（空格分隔）: " ports
    for p in $ports; do ufw allow "$p"; done
}

deny_all() {
    echo "▶ 同时关闭宿主机 + 容器端口"
    read -rp "请输入端口（空格分隔）: " ports
    for p in $ports; do ufw delete allow "$p" 2>/dev/null || true; done
}

reset_all() {
    echo "▶ 完全还原系统"
    ufw --force disable || true
    apt purge -y ufw || true
    rm -rf /etc/ufw
    systemctl restart docker
    echo "✔ 已完全还原"
}

# ==========================
# 菜单
# ==========================
menu() {
    clear
    echo "========================================"
    echo "      Docker + UFW 防火墙管理脚本"
    echo "========================================"
    echo "1) 修复 Docker + UFW 环境"
    echo "2) 只开放 Docker 容器端口 (不影响宿主机)"
    echo "3) 只关闭 Docker 容器端口 (不影响宿主机)"
    echo "4) 同时开放宿主机 + 容器端口"
    echo "5) 同时关闭宿主机 + 容器端口"
    echo "6) 完全还原（卸载 ufw / 清空规则）"
    echo "0) 退出"
    echo "========================================"
    read -rp "请选择 [0-6]: " choice
    case "$choice" in
        1) fix_ufw_docker ;;
        2) allow_docker ;;
        3) deny_docker ;;
        4) allow_all ;;
        5) deny_all ;;
        6) reset_all ;;
        0) exit 0 ;;
        *) echo "❌ 无效选择" ;;
    esac
    pause
    menu
}

require_root
menu
