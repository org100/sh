#!/bin/bash
# ===============================================
# RackNerd / UFW / Docker 正确兼容修复脚本
# 不修改 Docker 配置，仅修复 UFW 与 Docker 冲突
# ===============================================

UFW_AFTER="/etc/ufw/after.rules"

# ------------------------------
# 菜单
# ------------------------------
show_menu() {
    echo "=============================================="
    echo "UFW & Docker 正确兼容修复工具"
    echo "=============================================="
    echo "1) 一键修复 UFW 与 Docker（容器↔宿主↔外网）"
    echo "2) 放行普通 UFW 入站端口（宿主机用）"
    echo "3) 关闭普通 UFW 入站端口（宿主机用）"
    echo "4) 查看 UFW 状态"
    echo "5) 允许 Docker 容器端口外网访问（ufw route allow）"
    echo "6) 关闭 Docker 容器端口外网访问（ufw route deny）"
    echo "0) 退出"
    echo "=============================================="
    read -p "请选择操作 [0-6]: " choice
}

# ------------------------------
# 安装 & 启用 UFW
# ------------------------------
setup_ufw() {
    if ! command -v ufw >/dev/null 2>&1; then
        apt update && apt install -y ufw
    fi
    systemctl enable ufw
    ufw --force enable
}

# ------------------------------
# 核心修复：UFW + Docker
# ------------------------------
fix_ufw_docker() {
    setup_ufw

    echo "[*] 备份 after.rules"
    cp "$UFW_AFTER" "${UFW_AFTER}.bak_$(date +%F_%T)"

    if grep -q "BEGIN UFW AND DOCKER" "$UFW_AFTER"; then
        echo "[*] Docker 兼容规则已存在，跳过写入"
    else
        echo "[*] 写入 UFW & Docker 兼容规则"
        cat >> "$UFW_AFTER" <<'EOF'

# BEGIN UFW AND DOCKER
*filter
:ufw-user-forward - [0:0]
:ufw-docker-logging-deny - [0:0]
:DOCKER-USER - [0:0]

-A DOCKER-USER -j ufw-user-forward

-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
-A DOCKER-USER -m conntrack --ctstate INVALID -j DROP
-A DOCKER-USER -i docker0 -o docker0 -j ACCEPT

-A DOCKER-USER -j RETURN -s 10.0.0.0/8
-A DOCKER-USER -j RETURN -s 172.16.0.0/12
-A DOCKER-USER -j RETURN -s 192.168.0.0/16

-A DOCKER-USER -j ufw-docker-logging-deny -m conntrack --ctstate NEW -d 10.0.0.0/8
-A DOCKER-USER -j ufw-docker-logging-deny -m conntrack --ctstate NEW -d 172.16.0.0/12
-A DOCKER-USER -j ufw-docker-logging-deny -m conntrack --ctstate NEW -d 192.168.0.0/16

-A DOCKER-USER -j RETURN

-A ufw-docker-logging-deny -m limit --limit 3/min --limit-burst 10 -j LOG --log-prefix "[UFW DOCKER BLOCK] "
-A ufw-docker-logging-deny -j DROP

COMMIT
# END UFW AND DOCKER
EOF
    fi

    echo "[*] 重启 UFW"
    systemctl restart ufw

    echo
    echo "[✓] 修复完成"
    echo "👉 容器访问宿主机 / 内网端口：无需 ufw allow"
    echo "👉 Docker 默认端口不对外网开放"
}

# ------------------------------
# 普通 UFW 放行（宿主机）
# ------------------------------
ufw_allow_ports() {
    read -p "输入端口（空格分隔）: " ports
    for p in $ports; do
        ufw allow "$p"/tcp
    done
    ufw reload
}

ufw_deny_ports() {
    read -p "输入端口（空格分隔）: " ports
    for p in $ports; do
        ufw deny "$p"/tcp
    done
    ufw reload
}

ufw_status() {
    ufw status verbose
}

# ------------------------------
# Docker 外网端口控制
# ------------------------------
docker_allow_port() {
    read -p "容器端口: " port
    read -p "协议 tcp/udp [tcp]: " proto
    proto=${proto:-tcp}
    ufw route allow proto "$proto" from any to any port "$port"
    ufw reload
}

docker_deny_port() {
    read -p "容器端口: " port
    read -p "协议 tcp/udp [tcp]: " proto
    proto=${proto:-tcp}
    ufw route deny proto "$proto" from any to any port "$port"
    ufw reload
}

# ------------------------------
# 主逻辑
# ------------------------------
show_menu
case "$choice" in
1) fix_ufw_docker ;;
2) ufw_allow_ports ;;
3) ufw_deny_ports ;;
4) ufw_status ;;
5) docker_allow_port ;;
6) docker_deny_port ;;
0) exit 0 ;;
*) echo "无效选项" ;;
esac
