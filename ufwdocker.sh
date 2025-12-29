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
# 容器端口交互函数 (修复了变量丢失问题)
# ==========================
select_container_ip() {
    echo "正在获取 Docker 容器列表..."
    local containers=()
    local ips=()
    local status=()
    
    # 使用进程替换 < <() 避免子 Shell 导致数组失效
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        name=$(echo "$line" | awk '{print $1}')
        st=$(echo "$line" | awk '{print $2}')
        # 获取容器 IP
        ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$name")
        [ -z "$ip" ] && ip="Internal"

        containers+=("$name")
        ips+=("$ip")
        status+=("$st")
    done < <(docker ps -a --format '{{.Names}} {{.State}}')

    if [ ${#containers[@]} -eq 0 ]; then
        echo "❌ 当前没有发现 Docker 容器"
        read -rp "请输入目标 IP (或输入 'any'): " choice
        echo "${choice:-any}"
        return
    fi

    echo "------------------------------------------------"
    echo "ID | 容器名称           | IP 地址         | 状态"
    echo "------------------------------------------------"
    for i in "${!containers[@]}"; do
        printf "%2d | %-18s | %-15s | %s\n" "$((i+1))" "${containers[$i]}" "${ips[$i]}" "${status[$i]}"
    done
    echo " 0 | any (全部容器)"
    echo "------------------------------------------------"

    while true; do
        read -rp "请选择容器编号 [0-${#containers[@]}] (默认 0): " choice
        choice=${choice:-0}
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 0 && choice <= ${#containers[@]} )); then
            if [ "$choice" -eq 0 ]; then
                echo "any"
            else
                echo "${ips[$((choice-1))]}"
            fi
            break
        else
            echo "❌ 输入无效，请重新输入"
        fi
    done
}

ask_port() {
    local port
    read -rp "请输入端口 (例如 80, 留空或输入 any 表示全部): " port
    port=${port:-any}
    echo "$port"
}

# ==========================
# 操作函数
# ==========================
allow_docker() {
    echo "▶ 开放容器访问权限"
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
    echo "✔ 已添加允许规则: To: $ip Port: $port"
}

deny_docker() {
    echo "▶ 关闭容器访问权限"
    local ip port
    ip=$(select_container_ip)
    port=$(ask_port)
    
    if [ "$ip" == "any" ] && [ "$port" == "any" ]; then
        ufw route delete allow from any to any || true
    elif [ "$ip" == "any" ]; then
        ufw route delete allow proto tcp from any to any port "$port" || true
    elif [ "$port" == "any" ]; then
        ufw route delete allow from any to "$ip" || true
    else
        ufw route delete allow proto tcp from any to "$ip" port "$port" || true
    fi
    echo "✔ 已尝试删除对应规则"
}

allow_all() {
    read -rp "请输入要开放的宿主机端口: " ports
    for p in $ports; do ufw allow "$p"; done
}

deny_all() {
    read -rp "请输入要关闭的宿主机端口: " ports
    for p in $ports; do ufw delete allow "$p" || true; done
}

reset_all() {
    echo "▶ 正在卸载 UFW 并还原网络..."
    ufw --force disable || true
    apt purge -y ufw || true
    rm -rf /etc/ufw
    systemctl restart docker
    echo "✔ 还原完成"
}

# ==========================
# 主菜单
# ==========================
menu() {
    clear
    echo "========================================"
    echo "      Docker + UFW 自动化管理脚本"
    echo "========================================"
    echo "1) 修复 Docker + UFW 环境 (首选执行)"
    echo "2) 开放指定容器端口 (ufw route)"
    echo "3) 关闭指定容器端口"
    echo "4) 开放宿主机服务端口 (ufw allow)"
    echo "5) 关闭宿主机服务端口"
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
