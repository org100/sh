#!/usr/bin/env bash
set -e

UFW_AFTER="/etc/ufw/after.rules"
BACKUP_DIR="/root/ufw-backup"

require_root() { [ "$EUID" -eq 0 ] || { echo "❌ 请使用 root 运行"; exit 1; } }
pause() { echo ""; read -rp "按回车继续..." ; }

# 自动检测 SSH 端口
get_ssh_port() {
    local port
    port=$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}')
    echo "${port:-22}"
}

# ==========================
# 修复 Docker + UFW 环境 (宿主机 ↔ 容器 ↔ 局域网全放行)
# ==========================
fix_ufw_docker() {
    echo "▶ 正在执行环境修复..."
    apt update -y && apt install -y ufw

    SSH_PORT=$(get_ssh_port)
    echo "✔ 检测到 SSH 端口: $SSH_PORT，正在预放行..."
    ufw allow "$SSH_PORT"/tcp >/dev/null 2>&1 || true

    # 设置 UFW 默认允许转发
    sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

    # DOCKER-USER 链规则（宿主机 <-> 容器 <-> 局域网全放行）
    cat > "$UFW_AFTER" <<'EOF'
*filter
:ufw-user-forward - [0:0]
:ufw-docker-logging-deny - [0:0]
:DOCKER-USER - [0:0]

# 宿主机 <-> 容器互通
-A DOCKER-USER -s 172.18.0.0/16 -d 172.18.0.1 -j ACCEPT
-A DOCKER-USER -s 172.18.0.1 -d 172.18.0.0/16 -j ACCEPT

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
    systemctl restart ufw
    echo "✔ 修复完成，宿主机 ↔ 容器 ↔ 局域网全放行，SSH端口 $SSH_PORT 已放行。"
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
        [ -z "$ip" ] && ip="any"
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
        echo "❌ 无效输入。"
    done
}

# ==========================
# 多端口处理逻辑 (支持 any 或多端口一次操作)
# ==========================
process_ports() {
    local action=$1
    local target_ip=$2
    local port_input

    SSH_PORT=$(get_ssh_port)
    ufw allow "$SSH_PORT"/tcp >/dev/null 2>&1 || true
    [ -z "$target_ip" ] && target_ip="any"

    read -rp "请输入端口 (空格分隔, 或 any 表示全部端口): " port_input
    local ports=(${port_input// / })
    [ ${#ports[@]} -eq 0 ] && ports=("any")

    for p in "${ports[@]}"; do
        [ -z "$p" ] && p="any"
        echo "正在处理端口: $p -> $target_ip ..."

        if [ "$action" == "allow" ]; then
            # ufw
            if [ "$p" == "any" ]; then
                ufw allow from any to any
            else
                ufw allow "$p"/tcp
            fi
            # DOCKER-USER
            if [ "$target_ip" != "any" ] && [ "$p" != "any" ]; then
                iptables -I DOCKER-USER 1 -p tcp -d "$target_ip" --dport "$p" -j ACCEPT || true
            fi
        else
            # ufw 删除
            if [ "$p" == "any" ]; then
                ufw route delete from any to any || true
            else
                while true; do
                    rule_num=$(ufw status numbered | grep "ALLOW.*$p" | awk -F'[][]' '{print $2}' | head -n 1)
                    [ -z "$rule_num" ] && break
                    ufw delete "$rule_num" || true
                done
            fi
            # DOCKER-USER 删除
            if [ "$target_ip" != "any" ] && [ "$p" != "any" ]; then
                iptables -D DOCKER-USER -p tcp -d "$target_ip" --dport "$p" -j ACCEPT || true
            fi
        fi
    done
    echo "✔ 端口处理完成。"
}

# ==========================
# 菜单
# ==========================
menu() {
    clear
    echo "========================================"
    echo "      Docker + UFW 防火墙管理脚本"
    echo "========================================"
    echo "1) 修复 Docker + UFW 环境 (宿主机 ↔ 容器 ↔ 局域网全放行)"
    echo "2) 只开放 Docker 容器端口 (ufw route + DOCKER-USER)"
    echo "3) 只关闭 Docker 容器端口 (ufw route + DOCKER-USER)"
    echo "4) 同时开放宿主机 + 容器端口 (ufw + DOCKER-USER)"
    echo "5) 同时关闭宿主机 + 容器端口 (ufw + DOCKER-USER)"
    echo "6) 完全还原 (卸载 UFW)"
    echo "0) 退出"
    echo "========================================"
    read -rp "请选择 [0-6]: " choice
    case "$choice" in
        1) fix_ufw_docker ;;
        2) process_ports "allow" "$(select_container_ip)" ;;
        3) process_ports "delete" "$(select_container_ip)" ;;
        4) process_ports "allow" "$(select_container_ip)" ;;
        5) process_ports "delete" "$(select_container_ip)" ;;
        6) ufw --force disable && apt purge -y ufw && rm -rf /etc/ufw && systemctl restart docker ;;
        0) exit 0 ;;
    esac
    pause
    menu
}

require_root
menu
