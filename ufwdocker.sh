#!/usr/bin/env bash
set -e

UFW_AFTER="/etc/ufw/after.rules"
BACKUP_DIR="/root/ufw-backup"

require_root() {
    [ "$EUID" -eq 0 ] || { echo "❌ 请使用 root 运行"; exit 1; }
}

pause() {
    read -rp "按回车继续..."
}

# ===============================
# SSH 端口检测（最终稳定版）
# 直接读取 sshd 配置，确保端口准确
# ===============================
get_ssh_port() {
    local port
    if command -v sshd >/dev/null 2>&1; then
        port=$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}')
    fi

    # fallback
    if [ -z "$port" ]; then
        echo "⚠️ 未检测到 SSH 端口，使用 22 兜底"
        port=22
    fi

    echo "$port"
}

fix_ufw_docker() {
    echo "▶ 修复 Docker + UFW"

    apt update -y
    apt install -y ufw

    mkdir -p "$BACKUP_DIR"
    cp -a /etc/ufw "$BACKUP_DIR/" 2>/dev/null || true

    SSH_PORT=$(get_ssh_port)
    echo "✔ 检测到 SSH 端口: $SSH_PORT"

    echo "▶ 重置 UFW 规则"
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing

    echo "▶ 放行 SSH 端口 $SSH_PORT"
    ufw allow "$SSH_PORT"/tcp

    # 写入 Docker + UFW after.rules（兼容 ufw-init）
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
    else
        echo "✔ after.rules 已存在，跳过写入"
    fi

    ufw --force enable
    systemctl restart ufw

    echo "✔ Docker + UFW 修复完成"
}

allow_docker() {
    for p in "$@"; do
        ufw route allow proto tcp to any port "$p"
    done
}

deny_docker() {
    for p in "$@"; do
        ufw route delete allow proto tcp to any port "$p" 2>/dev/null || true
    done
}

allow_all() {
    for p in "$@"; do
        ufw allow "$p"
    done
}

deny_all() {
    for p in "$@"; do
        ufw delete allow "$p" 2>/dev/null || true
    done
}

reset_all() {
    echo "▶ 完全还原系统"

    ufw --force disable || true
    apt purge -y ufw || true
    rm -rf /etc/ufw

    systemctl restart docker

    echo "✔ 已完全还原"
}

menu() {
    clear
    echo "Docker + UFW 防火墙管理脚本（最终稳定版）"
    echo
    echo "1) 修复 Docker + UFW（自动确认 SSH 端口）"
    echo "2) 仅开放 Docker 容器端口"
    echo "3) 仅关闭 Docker 容器端口"
    echo "4) 同时开放 宿主机 + 容器端口"
    echo "5) 同时关闭 宿主机 + 容器端口"
    echo "6) 完全还原（卸载 ufw / 清空规则）"
    echo "0) 退出"
    echo
    read -rp "请选择 [0-6]: " choice

    case "$choice" in
        1) fix_ufw_docker ;;
        2) read -rp "端口（空格分隔）: " p; allow_docker $p ;;
        3) read -rp "端口（空格分隔）: " p; deny_docker $p ;;
        4) read -rp "端口（空格分隔）: " p; allow_all $p ;;
        5) read -rp "端口（空格分隔）: " p; deny_all $p ;;
        6) reset_all ;;
        0) exit 0 ;;
        *) echo "❌ 无效选择" ;;
    esac

    pause
    menu
}

require_root
menu
