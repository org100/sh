#!/usr/bin/env bash
set -e

clear

print_menu() {
cat <<'EOF'
========================================
      Docker + UFW 防火墙管理脚本
========================================
1) 修复 Docker + UFW 环境 (严格控制端口)
2) 只开放 Docker 容器端口 (ufw route)
3) 只关闭 Docker 容器端口 (ufw route)
4) 同时开放宿主机 + 容器端口 (ufw allow)
5) 同时关闭宿主机 + 容器端口 (ufw delete)
6) 完全还原 (卸载 UFW)
0) 退出
========================================
EOF
}

pause() {
  read -r -p "按回车继续..."
}

docker_list() {
  echo "--- 实时 Docker 容器列表 ---"
  printf "%-3s | %-20s | %-15s | %s\n" "ID" "NAMES" "IP" "STATUS"
  i=1
  docker ps --format '{{.Names}} {{.Status}}' | while read -r name status; do
    ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$name")
    printf "%-3s | %-20s | %-15s | %s\n" "$i" "$name" "$ip" "$status"
    i=$((i+1))
  done
  echo " 0   | any (全部容器)"
  echo "----------------------------"
}

get_target_ip() {
  docker_list
  read -r -p "请选择 ID 或输入容器名 [默认 0 = any]: " sel
  if [ -z "$sel" ] || [ "$sel" = "0" ]; then
    target_ip="any"
    return
  fi
  if [[ "$sel" =~ ^[0-9]+$ ]]; then
    name=$(docker ps --format '{{.Names}}' | sed -n "${sel}p")
  else
    name="$sel"
  fi
  target_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$name" 2>/dev/null || true)
  [ -z "$target_ip" ] && echo "容器不存在" && exit 1
}

process_ports_route_allow() {
  for p in $ports; do
    echo "开放 Docker 转发端口: $p -> $target_ip"
    if [ "$target_ip" = "any" ]; then
      ufw route allow proto tcp to any port "$p"
    else
      ufw route allow proto tcp to "$target_ip" port "$p"
    fi
  done
}

process_ports_route_delete() {
  for p in $ports; do
    echo "关闭 Docker 转发端口: $p -> $target_ip"
    while true; do
      if [ "$target_ip" = "any" ]; then
        rule=$(ufw status numbered | grep "ALLOW FWD" | grep "\b$p\b" | head -n1 | awk -F'[][]' '{print $2}')
      else
        rule=$(ufw status numbered | grep "ALLOW FWD" | grep "$target_ip" | grep "\b$p\b" | head -n1 | awk -F'[][]' '{print $2}')
      fi
      [ -z "$rule" ] && break
      ufw delete "$rule"
    done
  done
}

read_ports() {
  read -r -p "请输入端口 (空格分隔，如 80 443 81): " ports
}

while true; do
  print_menu
  read -r -p "请选择 [0-6]: " choice

  case "$choice" in
    0) exit 0 ;;
    1)
      ufw --force reset
      ufw default deny incoming
      ufw default allow outgoing
      ufw default allow routed
      ufw enable
      ;;
    2)
      get_target_ip
      read_ports
      process_ports_route_allow
      ;;
    3)
      get_target_ip
      read_ports
      process_ports_route_delete
      ;;
    4)
      read_ports
      for p in $ports; do ufw allow "$p"; done
      ;;
    5)
      read_ports
      for p in $ports; do
        while true; do
          r=$(ufw status numbered | grep "\b$p\b" | head -n1 | awk -F'[][]' '{print $2}')
          [ -z "$r" ] && break
          ufw delete "$r"
        done
      done
      ;;
    6)
      ufw disable
      apt purge -y ufw
      ;;
    *)
      echo "无效选择"
      ;;
  esac

  pause
  clear
done
