#!/usr/bin/env bash
set -e

UFW_AFTER="/etc/ufw/after.rules"
BACKUP_DIR="/root/ufw-backup"

require_root() { [ "$EUID" -eq 0 ] || { echo "❌ 请使用 root 运行"; exit 1; } }
pause() { echo ""; read -rp "按回车继续..." ; }

get_ssh_port() {
    local port=$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}')
    echo "${port:-22}"
}

# ==========================
# 1) 修复 Docker + UFW 环境
# ==========================
fix_ufw_docker() {
    echo "▶ 正在执行环境修复..."
    apt update -y && apt install -y ufw
    SSH_PORT=$(get_ssh_port)
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "$SSH_PORT"/tcp
    
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
    ufw --force enable
    systemctl restart ufw
    echo "✔ 修复完成。"
}

# ==========================
# 统一的容器选择逻辑 (强制显示 + 编号映射)
# ==========================
select_container_ip() {
    echo -e "\n\033[32m--- 实时 Docker 容器列表 ---\033[0m"
    local map_file="/tmp/ufw_docker_map"
    rm -f "$map_file"
    local i=1
    printf "\033[33m%-3s | %-20s | %-15s | %s\033[0m\n" "ID" "NAMES" "IP" "STATUS"
    
    while read -r name; do
        [ -z "$name" ] && continue
        local ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$name" | head -n 1)
        [ -z "$ip" ] && ip="Internal"
        local status=$(docker inspect -f '{{.State.Status}}' "$name")
        printf "%-3d | %-20s | %-15s | %s\n" "$i" "$name" "$ip" "$status" > /dev/tty
        echo "$i|$ip|$name" >> "$map_file"
        i=$((i+1))
    done <<< "$(docker ps -a --format "{{.Names}}")"

    echo " 0   | any (全部容器)"
    echo -e "\033[32m----------------------------\033[0m"

    local choice
    while true; do
        read -rp "请选择编号 (ID) 或直接输入容器名 [默认 0 = any]: " choice
        choice=${choice:-0}
        if [ "$choice" == "0" ] || [ "$choice" == "any" ]; then
            rm -f "$map_file"; echo "any"; return
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            local res=$(grep "^$choice|" "$map_file" | cut -d'|' -f2 || true)
            if [ -n "$res" ]; then
                rm -f "$map_file"; echo "$res"; return
            fi
        fi
        if docker inspect "$choice" >/dev/null 2>&1; then
            local res=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$choice" | head -n 1)
            rm -f "$map_file"; echo "${res:-any}"; return
        fi
        echo "❌ 输入无效，请重新输入。"
    done
}

# ==========================
# 核心处理：多端口循环执行
# ==========================
handle_ports() {
    local action=$1  # allow 或 delete
    local ip=$2
    local raw_ports
    
    read -rp "请输入端口 (支持空格分隔，如 80 81 443，留空为 any): " raw_ports
    # 将输入转换为数组，处理多空格情况
    read -ra port_array <<< "$raw_ports"
    
    # 如果输入为空，则处理为 any
    if [ ${#port_array[@]} -eq 0 ]; then
        port_array=("any")
    fi

    for port in "${port_array[@]}"; do
        if [ "$action" == "allow" ]; then
            if [ "$ip" == "any" ] && [ "$port" == "any" ]; then
                ufw route allow from any to any
            elif [ "$ip" == "any" ]; then
                ufw route allow proto tcp from any to any port "$port"
            elif [ "$port" == "any" ]; then
                ufw route allow from any to "$ip"
            else
                ufw route allow proto tcp from any to "$ip" port "$port"
            fi
            echo "✔ 已添加规则: To: $ip Port: $port"
        else
            if [ "$ip" == "any" ] && [ "$port" == "any" ]; then
                ufw route delete allow from any to any 2>/dev/null || true
            elif [ "$ip" == "any" ]; then
                ufw route delete allow proto tcp from any to any port "$port" 2>/dev/null || true
            elif [ "$port" == "any" ]; then
                ufw route delete allow from any to "$ip" 2>/dev/null || true
            else
                ufw route delete allow proto tcp from any to "$ip" port "$port" 2>/dev/null || true
            fi
            echo "✔ 已处理删除: To: $ip Port: $port"
        fi
    done
}

# ==========================
# 选项函数
# ==========================
allow_docker() {
    echo "▶ 只开放 Docker 容器端口"
    local ip=$(select_container_ip)
    handle_ports "allow" "$ip"
}

deny_docker() {
    echo "▶ 只关闭 Docker 容器端口"
    local ip=$(select_container_ip)
    handle_ports "deny" "$ip"
}

allow_all() {
    echo "▶ 同时开放宿主机 + 容器端口"
    read -rp "请输入端口 (空格分隔): " -a ports
    for p in "${ports[@]}"; do
        ufw allow "$p"
        echo "✔ 开放宿主机端口: $p"
    done
}

deny_all() {
    echo "▶ 同时关闭宿主机 + 容器端口"
    read -rp "请输入端口 (空格分隔): " -a ports
    for p in "${ports[@]}"; do
        ufw delete allow "$p" 2>/dev/null || true
        echo "✔ 删除宿主机端口: $p"
    done
}

reset_all() {
    echo "▶ 正在卸载 UFW 并还原规则..."
    ufw --force disable || true
    apt purge -y ufw || true
    rm -rf /etc/ufw
    systemctl restart docker
    echo "✔ 系统已还原。"
}

menu() {
    clear
    echo "========================================"
    echo "      Docker + UFW 防火墙管理脚本"
    echo "========================================"
    echo "1) 修复 Docker + UFW 环境"
    echo "2) 只开放 Docker 容器端口 (ufw route)"
    echo "3) 只关闭 Docker 容器端口 (ufw route)"
    echo "4) 同时开放宿主机 + 容器端口 (ufw allow)"
    echo "5) 同时关闭宿主机 + 容器端口 (ufw delete)"
    echo "6) 完全还原 (卸载 UFW)"
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
