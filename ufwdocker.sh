#!/usr/bin/env bash
set -e

UFW_AFTER="/etc/ufw/after.rules"
BACKUP_DIR="/root/ufw-backup-$(date +%s)"

require_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "❌ 请使用 root 运行"
        exit 1
    fi
}

get_ssh_port() {
    local port
    port=$(ss -tnlp | awk '/ssh/ && /LISTEN/ {print $4}' | awk -F: '{print $NF}' | head -n1)
    echo "${port:-22}"
}

install_ufw_and_fix() {
    echo "▶ 修复 docker + ufw 环境"

    apt update -y
    apt install -y ufw

    mkdir -p "$BACKUP_DIR"
    cp -a /etc/ufw "$BACKUP_DIR/" 2>/dev/null || true

    SSH_PORT=$(get_ssh_port)
    echo "✔ 检测到 SSH 端口: $SSH_PORT"

    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "$SSH_PORT"/tcp

    if ! grep -q "BEGIN UFW AND DOCKER" "$UFW_AFTER"; then
        echo "▶ 写入 Docker + UFW after.rules"
        cat >> "$UFW_AFTER" <<'EOF'

# BEGIN UFW AND DOCKER
*filter
:ufw-user-forward - [0:0]
:ufw-docker-logging-deny - [0:0]
:DOCKER-USER - [0:0]
-A DOCKER-USER -j ufw-user-forward

-A DOCKER-USER -j RETURN -s 10.0.0.0/8
-A DOCKER-USER -j RETURN -s 172.16.0.0/12
-A DOCKER-USER -j RETURN -s 192.168.0.0/16

-A DOCKER-USER -p udp -m udp --sport 53 --dport 1024:65535 -j RETURN

-A DOCKER-USER -j ufw-docker-logging-deny -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -d 192.168.0.0/16
-A DOCKER-USER -j ufw-docker-logging-deny -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -d 10.0.0.0/8
-A DOCKER-USER -j ufw-docker-logging-deny -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -d 172.16.0.0/12
-A DOCKER-USER -j ufw-docker-logging-deny -p udp -m udp --dport 0:32767 -d 192.168.0.0/16
-A DOCKER-USER -j ufw-docker-logging-deny -p udp -m udp --dport 0:32767 -d 10.0.0.0/8
-A DOCKER-USER -j ufw-docker-logging-deny -p udp -m udp --dport 0:32767 -d 172.16.0.0/12

-A DOCKER-USER -j RETURN

-A ufw-docker-logging-deny -m limit --limit 3/min --limit-burst 10 -j LOG --log-prefix "[UFW DOCKER BLOCK] "
-A ufw-docker-logging-deny -j DROP

COMMIT
# END UFW AND DOCKER
EOF
    fi

    ufw --force enable
    systemctl restart ufw

    echo "✔ 修复完成，如规则未生效请重启服务器"
}

allow_docker_ports() {
    for p in "$@"; do
        ufw route allow proto tcp to any port "$p"
        echo "✔ 已开放 Docker 外网端口: $p"
    done
}

deny_docker_ports() {
    for p in "$@"; do
        ufw delete route allow proto tcp to any port "$p" 2>/dev/null || true
        echo "✔ 已关闭 Docker 外网端口: $p"
    done
}

allow_all_ports() {
    for p in "$@"; do
        ufw allow "$p"
        ufw route allow proto tcp to any port "$p"
        echo "✔ 已开放 宿主机 + Docker 端口: $p"
    done
}

deny_all_ports() {
    for p in "$@"; do
        ufw delete allow "$p" 2>/dev/null || true
        ufw delete route allow proto tcp to any port "$p" 2>/dev/null || true
        echo "✔ 已关闭 宿主机 + Docker 端口: $p"
    done
}

reset_all() {
    echo "⚠ 正在完全还原系统（不可逆）"

    ufw --force reset 2>/dev/null || true
    systemctl stop ufw 2>/dev/null || true
    apt purge -y ufw
    rm -rf /etc/ufw

    iptables -F
    iptables -t nat -F
    iptables -t mangle -F
    iptables -X

    systemctl restart docker

    echo "✔ 已彻底还原系统防火墙"
}

require_root

case "$1" in
    fix)
        install_ufw_and_fix
        ;;
    allow-docker)
        shift
        allow_docker_ports "$@"
        ;;
    deny-docker)
        shift
        deny_docker_ports "$@"
        ;;
    allow-all)
        shift
        allow_all_ports "$@"
        ;;
    deny-all)
        shift
        deny_all_ports "$@"
        ;;
    reset)
        reset_all
        ;;
    *)
        echo
        echo "Docker + UFW 防火墙管理脚本"
        echo
        echo "用法:"
        echo "  $0 <命令> [端口...]"
        echo
        echo "命令说明:"
        echo "  fix           修复 docker + ufw 问题（安装 ufw、放行 SSH、写入 after.rules）"
        echo "  allow-docker  仅开放 Docker 容器 外网端口"
        echo "  deny-docker   仅关闭 Docker 容器 外网端口"
        echo "  allow-all     同时开放 宿主机 + 容器 端口"
        echo "  deny-all      同时关闭 宿主机 + 容器 端口"
        echo "  reset         完全还原：卸载 ufw、清空规则、重启 docker"
        echo
        echo "示例:"
        echo "  $0 fix"
        echo "  $0 allow-docker 80 443"
        echo "  $0 deny-docker 80"
        echo "  $0 allow-all 8080"
        echo "  $0 reset"
        echo
        exit 1
        ;;
esac
