#!/usr/bin/env bash
set -e

UFW_AFTER="/etc/ufw/after.rules"
BACKUP_DIR="/root/ufw-backup"

require_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "❌ 请使用 root 运行"
        exit 1
    fi
}

pause() {
    read -rp "按回车继续..."
}

get_ssh_port() {
    local port
    port=$(ss -tnlp | awk '/ssh/ && /LISTEN/ {print $4}' | awk -F: '{print $NF}' | head -n1)
    echo "${port:-22}"
}

install_ufw_and_fix() {
    echo "▶ 修复 docker + ufw"

    apt update -y
    apt install -y ufw

    mkdir -p "$BACKUP_DIR"
    cp -a /etc/ufw "$BACKUP_DIR/" 2>/dev/null || true

    SSH_PORT=$(get_ssh_port)
    echo "✔ SSH 端口: $SSH_PORT"

    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "$SSH_PORT"/tcp

    if ! grep -q "BEGIN UFW AND DOCKER" "$UFW_AFTER"; then
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

    echo "✔ 修复完成（如未生效请重启服务器）"
    pause
}

input_ports() {
    read -rp "请输入端口（多个用空格分隔）: " PORTS
    echo "$PORTS"
}

allow_docker_ports() {
    PORTS=$(input_ports)
    for p in $PORTS; do
        ufw route allow proto tcp to any port "$p"
        echo "✔ Docker 端口已开放: $p"
    done
    pause
}

deny_docker_ports() {
    PORTS=$(input_ports)
    for p in $PORTS; do
        ufw delete route allow proto tcp to any port "$p" 2>/dev/null || true
        echo "✔ Docker 端口已关闭: $p"
    done
    pause
}

allow_all_ports() {
    PORTS=$(input_ports)
    for p in $PORTS; do
        ufw allow "$p"
        ufw route allow proto tcp to any port "$p"
        echo "✔ 宿主机 + Docker 端口已开放: $p"
    done
    pause
}

deny_all_ports() {
    PORTS=$(input_ports)
    for p in $PORTS; do
        ufw delete allow "$p" 2>/dev/null || true
        ufw delete route allow proto tcp to any port "$p" 2>/dev/null || true
        echo "✔ 宿主机 + Docker 端口已关闭: $p"
    done
    pause
}

reset_all() {
    echo "⚠ 即将完全还原系统（不可逆）"
    read -rp "确认请输入 YES: " CONFIRM
    [ "$CONFIRM" = "YES" ] || return

    ufw --force reset || true
    systemctl stop ufw || true
    apt purge -y ufw
    rm -rf /etc/ufw

    iptables -F
    iptables -t nat -F
    iptables -t mangle -F
    iptables -X

    systemctl restart docker

    echo "✔ 系统已完全还原"
    pause
}

require_root

while true; do
    clear
    echo "=============================="
    echo " Docker + UFW 防火墙管理菜单 "
    echo "=============================="
    echo
    echo "1) 修复 docker + ufw（安装 ufw / 放行 SSH / 写入规则）"
    echo "2) 开放 Docker 容器 外网端口"
    echo "3) 关闭 Docker 容器 外网端口"
    echo "4) 开放 宿主机 + 容器 端口"
    echo "5) 关闭 宿主机 + 容器 端口"
    echo "6) 完全还原（卸载 ufw / 清空规则 / 重启 docker）"
    echo
    echo "0) 退出"
    echo
    read -rp "请选择 [0-6]: " CHOICE

    case "$CHOICE" in
        1) install_ufw_and_fix ;;
        2) allow_docker_ports ;;
        3) deny_docker_ports ;;
        4) allow_all_ports ;;
        5) deny_all_ports ;;
        6) reset_all ;;
        0) exit 0 ;;
        *) echo "无效选项"; pause ;;
    esac
done
