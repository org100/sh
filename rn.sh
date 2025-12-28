#!/bin/bash
# =====================================================
# RackNerd / UFW / Docker 正确兼容修复脚本（最终版）
# ✔ 不修改 Docker 配置
# ✔ 修复 UFW 与 Docker 网络冲突
# ✔ 正确区分：宿主端口 / Docker 外网端口
# =====================================================

UFW_AFTER="/etc/ufw/after.rules"

# -----------------------------------------------------
# 菜单
# -----------------------------------------------------
show_menu() {
    clear
    echo "================================================="
    echo "        UFW & Docker 正确兼容管理工具"
    echo "================================================="
    echo "1) 一键修复 UFW 与 Docker（推荐首次执行）"
    echo "2) 放行普通 UFW 入站端口（宿主机服务）"
    echo "3) 关闭普通 UFW 入站端口（宿主机服务）"
    echo "4) 查看 UFW 状态"
    echo "5) 允许 Docker 容器端口外网访问"
    echo "6) 关闭 Docker 容器端口外网访问"
    echo "0) 退出"
    echo "================================================="
    read -p "请选择操作 [0-6]: " choice
}

# -----------------------------------------------------
# 安装并启用 UFW
# -----------------------------------------------------
setup_ufw() {
    if ! command -v ufw >/dev/null 2>&1; then
        echo "[*] 安装 UFW"
        apt update && apt install -y ufw
    fi
    systemctl enable ufw >/dev/null 2>&1
    ufw --force enable
}

# -----------------------------------------------------
# 核心修复：UFW 与 Docker 正确协作
# -----------------------------------------------------
fix_ufw_docker() {
    setup_ufw

    echo "[*] 备份 $UFW_AFTER"
    cp "$UFW_AFTER" "${UFW_AFTER}.bak_$(date +%F_%H-%M-%S)"

    if grep -q "BEGIN UFW AND DOCKER" "$UFW_AFTER"; then
        echo "[*] Docker 兼容规则已存在，跳过写入"
    else
        echo "[*] 写入 Docker ↔ UFW 兼容规则"
        cat >> "$UFW_AFTER" <<'EOF'

# BEGIN UFW AND DOCKER
*filter
:ufw-user-forward - [0:0]
:ufw-docker-logging-deny - [0:0]
:DOCKER-USER - [0:0]

# Docker 流量交给 UFW forward 处理
-A DOCKER-USER -j ufw-user-forward

# 基础连接状态
-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
-A DOCKER-USER -m conntrack --ctstate INVALID -j DROP

# 容器之间通信
-A DOCKER-USER -i docker0 -o docker0 -j ACCEPT

# 允许内网 / Docker 网段访问宿主
-A DOCKER-USER -j RETURN -s 10.0.0.0/8
-A DOCKER-USER -j RETURN -s 172.16.0.0/12
-A DOCKER-USER -j RETURN -s 192.168.0.0/16

# 阻止 Docker 私网被外部直接访问（除非 ufw route allow）
-A DOCKER-USER -j ufw-docker-logging-deny -m conntrack --ctstate NEW -d 10.0.0.0/8
-A DOCKER-USER -j ufw-docker-logging-deny -m conntrack --ctstate NEW -d 172.16.0.0/12
-A DOCKER-USER -j ufw-docker-logging-deny -m conntrack --ctstate NEW -d 192.168.0.0/16

-A DOCKER-USER -j RETURN

# 日志
-A ufw-docker-logging-deny -m limit --limit 3/min --limit-burst 10 \
  -j LOG --log-prefix "[UFW DOCKER BLOCK] "
-A ufw-docker-logging-deny -j DROP

COMMIT
# END UFW AND DOCKER
EOF
    fi

    echo "[*] 重启 UFW"
    systemctl restart ufw

    echo
    echo "[✓] 修复完成"
    echo "-------------------------------------------------"
    echo "✔ 容器 → 宿主 / 内网：无需 ufw allow"
    echo "✔ Docker 端口默认不对外网开放"
    echo "✔ 外网访问容器需使用：ufw route allow"
    echo "-------------------------------------------------"
}

# -----------------------------------------------------
# 普通宿主机端口管理
# -----------------------------------------------------
ufw_allow_ports() {
    read -p "输入要放行的宿主端口（空格分隔）: " ports
    for p in $ports; do
        ufw allow "$p"/tcp
    done
    ufw reload
}

ufw_delete_ports() {
    read -p "输入要关闭的宿主端口（空格分隔）: " ports
    for p in $ports; do
        ufw delete allow "$p"/tcp
    done
    ufw reload
}

ufw_status() {
    ufw status verbose
}

# -----------------------------------------------------
# Docker 外网端口控制（真正的外部访问）
# -----------------------------------------------------
docker_allow_port() {
    read -p "容器端口（可空格分隔多个）: " ports
    read -p "协议 tcp/udp [tcp]: " proto
    proto=${proto:-tcp}

    for port in $ports; do
        echo "[*] 允许 Docker 容器端口 $port 外网访问"
        ufw route allow proto "$proto" from any to any port "$port"
    done
    ufw reload
}

docker_deny_port() {
    read -p "容器端口（可空格分隔多个）: " ports
    read -p "协议 tcp/udp [tcp]: " proto
    proto=${proto:-tcp}

    for port in $ports; do
        echo "[*] 关闭 Docker 容器端口 $port 外网访问"
        ufw route delete allow proto "$proto" from any to any port "$port"
    done
    ufw reload
}

# -----------------------------------------------------
# 主逻辑
# -----------------------------------------------------
show_menu
case "$choice" in
    1) fix_ufw_docker ;;
    2) ufw_allow_ports ;;
    3) ufw_delete_ports ;;
    4) ufw_status ;;
    5) docker_allow_port ;;
    6) docker_deny_port ;;
    0) exit 0 ;;
    *) echo "无效选项" ;;
esac
