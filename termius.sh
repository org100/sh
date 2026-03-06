#!/bin/sh
set -eu

SRC="$HOME/Library/Application Support/Termius/IndexedDB/file__0.indexeddb.leveldb"
BASE_DIR="$HOME/Library/Application Support/Termius/IndexedDB"
BACKUP_DIR="$(pwd)"

# ---------- tty helpers ----------
tty_has() { [ -r /dev/tty ] && [ -w /dev/tty ]; }

tty_out() {
  if tty_has; then
    printf "%s\n" "$*" > /dev/tty
  else
    printf "%s\n" "$*" >&2
  fi
}

tty_printf() {
  if tty_has; then
    printf "%s" "$*" > /dev/tty
  else
    printf "%s" "$*" >&2
  fi
}

tty_read() {
  if [ -r /dev/tty ]; then
    IFS= read -r "$1" < /dev/tty
  else
    IFS= read -r "$1"
  fi
}

pause() {
  tty_printf "回车返回主菜单..."
  dummy=""
  tty_read dummy || true
}

# ---------- backup helpers ----------
list_backups() {
  find "$BACKUP_DIR" -maxdepth 1 -type f -name "termius_indexeddb_*.tar.gz" -print 2>/dev/null \
  | sort -r
}

# FIX 1: 用 awk 在同一进程内完成编号+basename，避免子 shell 导致计数器不递增
print_backups() {
  backups="$(list_backups)"
  if [ -z "$backups" ]; then
    echo "当前目录没有备份文件"
    return 0
  fi

  echo "----------------------------------------"
  echo "当前目录备份列表（新 -> 旧）："
  echo "----------------------------------------"
  echo "$backups" | awk -F'/' '{printf "%2d) %s\n", NR, $NF}'
  echo "----------------------------------------"
}

pick_backup() {
  backups="$(list_backups)"
  [ -n "$backups" ] || return 1

  tty_out "----------------------------------------"
  tty_out "当前目录备份列表（新 -> 旧）："
  tty_out "----------------------------------------"
  # FIX 1: 同上，用 awk 一步完成编号+basename，兜底走 stderr 避免 set -e 因 /dev/tty 不可写退出
  if tty_has; then
    echo "$backups" | awk -F'/' '{printf "%2d) %s\n", NR, $NF}' > /dev/tty
  else
    echo "$backups" | awk -F'/' '{printf "%2d) %s\n", NR, $NF}' >&2
  fi
  tty_out "----------------------------------------"

  while :; do
    tty_printf "请输入编号 (0 取消): "
    idx=""
    tty_read idx

    case "$idx" in
      0) return 1 ;;
      ''|*[!0-9]*) tty_out "[!] 请输入数字"; continue ;;
    esac

    sel="$(echo "$backups" | sed -n "${idx}p")"
    [ -n "$sel" ] || { tty_out "[!] 编号超出范围"; continue; }

    echo "$sel"
    return 0
  done
}

ensure_termius_closed() {
  osascript -e 'tell application "Termius" to quit' >/dev/null 2>&1 || true
  pkill -x "Termius" >/dev/null 2>&1 || true
}

# FIX 3: 去掉 grep 多余的 2>/dev/null
validate_backup() {
  tar -tzf "$1" 2>/dev/null | grep -q '^file__0\.indexeddb\.leveldb/'
}

atomic_restore() {
  tmp_root="${BASE_DIR}/.restore_tmp.$$"
  rm -rf "$tmp_root" >/dev/null 2>&1 || true
  mkdir -p "$tmp_root"

  tar -xzf "$1" -C "$tmp_root" || return 1
  [ -d "$tmp_root/file__0.indexeddb.leveldb" ] || return 1

  rm -rf "$SRC"
  mv "$tmp_root/file__0.indexeddb.leveldb" "$SRC"
  rm -rf "$tmp_root"
}

# ================= 主循环 =================
while :; do
  clear
  echo "========================================"
  echo "     Termius IndexedDB 数据库管理器"
  echo "========================================"
  echo "当前目录: $BACKUP_DIR"
  echo "数据库目录: $SRC"
  echo "----------------------------------------"
  echo "1) 备份数据库到当前目录"
  echo "2) 选择备份并恢复"
  echo "3) 仅列出当前目录备份"
  echo "4) 删除指定备份"
  echo "0) 退出"
  echo "----------------------------------------"
  # FIX 2: 统一走 tty_read，与脚本其他地方保持一致
  tty_printf "请选择操作: "
  choice=""
  tty_read choice

  case "$choice" in
    1)
      if [ ! -d "$SRC" ]; then
        echo "[!] 找不到数据库目录: $SRC"
        pause
        continue
      fi

      TS="$(date +%Y%m%d_%H%M%S)"
      OUT="$BACKUP_DIR/termius_indexeddb_${TS}.tar.gz"

      echo "[*] 正在备份..."
      tar -czf "$OUT" -C "$BASE_DIR" "file__0.indexeddb.leveldb"
      echo "[+] 备份完成：$OUT"
      pause
      ;;

    2)
      TARGET="$(pick_backup)" || {
        echo "[*] 已取消恢复"
        pause
        continue
      }

      echo "[*] 校验备份..."
      if ! validate_backup "$TARGET"; then
        echo "[!] 备份文件异常（不包含 file__0.indexeddb.leveldb/）"
        pause
        continue
      fi

      echo "[*] 关闭 Termius..."
      ensure_termius_closed

      if [ -d "$SRC" ]; then
        SAFE_TS="$(date +%Y%m%d_%H%M%S)"
        SAFE_OUT="$BACKUP_DIR/termius_indexeddb_PRE_RESTORE_${SAFE_TS}.tar.gz"
        echo "[*] 恢复前自动备份..."
        tar -czf "$SAFE_OUT" -C "$BASE_DIR" "file__0.indexeddb.leveldb" >/dev/null 2>&1 || true
        echo "[+] 已生成恢复前备份：$SAFE_OUT"
      fi

      echo "[*] 正在恢复..."
      if atomic_restore "$TARGET"; then
        echo "[+] 恢复完成，启动 Termius..."
        open -a "Termius" >/dev/null 2>&1 || true
      else
        echo "[!] 恢复失败（备份可能损坏）"
      fi

      pause
      ;;

    3)
      print_backups
      pause
      ;;

    4)
      DEL_TARGET="$(pick_backup)" || {
        echo "[*] 已取消删除"
        pause
        continue
      }

      echo "[*] 将删除：$(basename "$DEL_TARGET")"
      # FIX 2: 统一走 tty_read
      tty_printf "确认删除？(Y/n): "
      yn=""
      tty_read yn

      case "$yn" in
        n|N)
          echo "[*] 已取消删除"
          ;;
        *)
          rm -f "$DEL_TARGET"
          echo "[+] 已删除"
          ;;
      esac

      pause
      ;;

    0)
      echo "已退出"
      exit 0
      ;;

    *)
      echo "[!] 无效选择"
      pause
      ;;
  esac
done
