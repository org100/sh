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
# 修复 Docker + UFW 环境 (严格控制端口)
# ==========================
fix_ufw_docker() {
    echo "▶ 正在执行环境修复..."
    apt update -y && apt install -y ufw

    SSH_PORT=$(get_ssh_port)
    echo "✔ 检测到 SSH 端口: $SSH_PORT，正在预放行..."
    ufw allow "$SSH_PORT"/tcp >/dev/null 2>&1 || true

    # 设置 UFW 默认允许转发
    sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

    # DOCKER-USER 链规则
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
    echo "✔ 环境修复完成，Docker 对外端口已严格控制，SSH端口 $SSH_PORT 已安全放行。"
}

# ==========================
# 获取容器 IP 和端口映射
# ==========================
select_container() {
    local map_file="/tmp/ufw_docker_map"
    rm -f "$map_file"
    local i=1

    printf "\033[32m--- 实时 Docker 容器列表 ---\033[0m\n" > /dev/tty
    printf "\033[33m%-3s | %-20s | %-15s | %s\033[0m\n" "ID" "NAMES" "IP" "STATUS" > /dev/tty

    while read -r name; do
        [ -z "$name" ] && continue
        local ip
        ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$name" | head -n1)
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
            res=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$choice" | head -n1)
            [ -z "$res" ] && res="any"
            res=$(echo "$res" | tr -d '[:space:]')
            rm -f "$map_file"; echo "$res"; return
        fi
        echo "❌ 无效输入。"
    done
}

# ==========================
# 获取容器映射端口
# ==========================
get_container_ports() {
    local container=$1
    local ports=()
    while read -r line; do
        [[ "$line" =~ ([0-9]+)(->([0-9]+))?/tcp ]] && ports+=("${BASH_REMATCH[3]:-${BASH_REMATCH[1]}}")
    done <<< "$(docker port "$container")"
    echo "${ports[@]}"
}

# ==========================
# 处理端口规则
# ==========================
process_ports() {
    local action=$1
    local target_ip=$2
    local container_name
    [ "$target_ip" != "any" ] && container_name=$(docker ps --format "{{.Names}}" | grep -w "$target_ip")

    SSH_PORT=$(get_ssh_port)
    ufw allow "$SSH_PORT"/tcp >/dev/null 2>&1 || true

    local ports=()
    if [ -n "$container_name" ]; then
        ports=($(get_container_ports "$container_name"))
    else
        read -rp "请输入端口 (空格分隔，如 80 443 81): " port_input
        ports=(${port_input// / })
        [ ${#ports[@]} -eq 0 ] && ports=("any")
    fi

    for p in "${ports[@]}"; do
        [ -z "$p" ] && p="any"
        echo "正在处理端口: $p -> $target_ip ..."

        if [ "$action" == "allow" ]; then
            if [ "$target_ip" == "any" ]; then
                [ "$p" == "any" ] && ufw route allow from any to any || ufw route allow proto tcp from any to any port "$p"
            else
                [ "$p" == "any" ] && ufw route allow from any to "$target_ip" || ufw route allow proto tcp from any to "$target_ip" port "$p"
                # DOCKER-USER 链插入 ACCEPT
                iptables -C DOCKER-USER -p tcp -d "$target_ip" --dport "$p" -j ACCEPT 2>/dev/null || \
                    iptables -I DOCKER-USER 1 -p tcp -d "$target_ip" --dport "$p" -j ACCEPT
            fi
        else
            # 删除规则
            if [ "$target_ip" == "any" ]; then
                [ "$p" == "any" ] && ufw route delete from any to any || ufw route delete proto tcp from any to any port "$p" || true
            else
                [ "$p" == "any" ] && ufw route delete from any to "$target_ip" || ufw route delete proto tcp from any to "$target_ip" port "$p" || true
                iptables -D DOCKER-USER -p tcp -d "$target_ip" --dport "$p" -j ACCEPT 2>/dev/null || true
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
    echo "1) 修复 Docker + UFW 环境 (严格控制端口)"
    echo "2) 只开放 Docker 容器端口 (ufw route + DOCKER-USER ACCEPT)"
    echo "3) 只关闭 Docker 容器端口 (ufw route + DOCKER-USER DELETE)"
    echo "4) 同时开放宿主机 + 容器端口 (ufw allow)"
    echo "5) 同时关闭宿主机 + 容器端口 (ufw delete)"
    echo "6) 完全还原 (卸载 UFW)"
    echo "0) 退出"
    echo "========================================"
    read -rp "请选择 [0-6]: " choice
    case "$choice" in
        1) fix_ufw_docker ;;
        2) process_ports "allow" "$(select_container)" ;;
        3) process_ports "delete" "$(select_container)" ;;
        4) read -rp "输入端口: " ps; for p in $ps; do ufw allow "$p"; done ;;
        5) read -rp "输入端口: " ps; for p in $ps; do ufw delete allow "$p" || true; done ;;
        6) ufw --force disable && apt purge -y ufw && rm -rf /etc/ufw && systemctl restart docker ;;
        0) exit 0 ;;
    esac
    pause
    menu
}

require_root
menu
