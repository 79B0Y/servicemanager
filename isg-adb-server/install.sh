#!/data/data/com.termux/files/usr/bin/bash
# shellcheck source=/dev/null
set -euo pipefail

source "$(dirname "$0")/common_paths.sh"

ensure_directories

START_TIME=$(date +%s)
log "starting isg-adb-server installation"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"starting installation process\",\"timestamp\":$(date +%s)}"

# 安装 android-tools
log "installing android-tools"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"installing android-tools\",\"timestamp\":$(date +%s)}"

# Try to install normally first. If it fails and appears to be a 'valid-until' repository time error,
# temporarily disable the apt "Check-Valid-Until" and retry once.
backup_apt_sources() {
    local bdir
    bdir="$TEMP_DIR/apt_sources_backup_$(date +%s)"
    mkdir -p "$bdir"
    cp -a "$PREFIX/etc/apt/sources.list" "$bdir/" 2>/dev/null || true
    cp -a "$PREFIX/etc/apt/sources.list.d" "$bdir/" 2>/dev/null || true
    echo "$bdir"
}

restore_apt_sources() {
    local bdir="$1"
    if [ -z "$bdir" ] || [ ! -d "$bdir" ]; then
        return 0
    fi
    cp -a "$bdir/sources.list" "$PREFIX/etc/apt/" 2>/dev/null || true
    if [ -d "$bdir/sources.list.d" ]; then
        mkdir -p "$PREFIX/etc/apt/sources.list.d"
        cp -a "$bdir/sources.list.d/"* "$PREFIX/etc/apt/sources.list.d/" 2>/dev/null || true
    fi
}

set_mirror() {
    local name="$1"
    local base
    case "$name" in
        official)
            base="https://packages.termux.org/apt"
            ;;
        ustc)
            base="https://mirrors.ustc.edu.cn/termux/apt"
            ;;
        *)
            return 1
            ;;
    esac
    mkdir -p "$PREFIX/etc/apt"
    echo "deb ${base}/termux-main stable main" > "$PREFIX/etc/apt/sources.list"
    mkdir -p "$PREFIX/etc/apt/sources.list.d"
    echo "deb ${base}/termux-root root main" > "$PREFIX/etc/apt/sources.list.d/root.list"
    echo "deb ${base}/termux-science science main" > "$PREFIX/etc/apt/sources.list.d/science.list"
    log "switched apt mirror to $name ($base)"
    return 0
}

install_with_retry() {
    if bash -c "pkg update -y && pkg install -y android-tools"; then
        return 0
    fi
    # initial install failed; try switching mirrors (official then ustc)
    log "initial install failed; attempting to switch mirrors to a foreign source"
    local backupdir
    backupdir=$(backup_apt_sources) || backupdir=""

    for m in official ustc; do
        if set_mirror "$m"; then
            log "retrying install after switching to mirror: $m"
            if bash -c "pkg update -y && pkg install -y android-tools"; then
                log "install succeeded after switching mirror to $m"
                return 0
            fi
            log "install still failed with mirror $m; will try next fallback"
        fi
        # restore original before trying next
        restore_apt_sources "$backupdir"
    done

    # as a last resort, try disabling apt Check-Valid-Until temporarily
    local tmpconf="$PREFIX/etc/apt/apt.conf.d/99disable-check-valid-until"
    log "attempting apt valid-until fallback (temporary)"
    echo 'Acquire::Check-Valid-Until "false";' > "$tmpconf" || {
        log "failed to write temporary apt conf $tmpconf"
        restore_apt_sources "$backupdir"
        return 1
    }

    # Retry update/install with the temp conf in place
    if bash -c "pkg update -y && pkg install -y android-tools"; then
        log "install succeeded after disabling Check-Valid-Until"
        rm -f "$tmpconf" || true
        return 0
    fi

    # final cleanup and fail
    log "install still failed after retry with Check-Valid-Until disabled"
    rm -f "$tmpconf" || true
    restore_apt_sources "$backupdir"
    return 1
}

if ! install_with_retry; then
    log "failed to install android-tools"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"android-tools installation failed\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# 设置 adb tcp 端口并重启 adbd
log "configuring adb to listen on tcp:$SERVICE_PORT and restarting adbd"
if ! su_exec "setprop service.adb.tcp.port $SERVICE_PORT" || ! su_exec "stop adbd" || ! su_exec "start adbd"; then
    log "failed to configure/start adbd"
    mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"failed\",\"message\":\"failed to configure/start adbd\",\"timestamp\":$(date +%s)}"
    record_install_history "FAILED" "unknown"
    exit 1
fi

# 尝试连接本地 adb
log "attempt adb connect to 127.0.0.1:$SERVICE_PORT"
adb connect "127.0.0.1:${SERVICE_PORT}" >/dev/null 2>&1 || true

# 注册 servicemonitor
log "registering servicemonitor service"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"status\":\"installing\",\"message\":\"registering servicemonitor service\",\"timestamp\":$(date +%s)}"

mkdir -p "$SERVICE_CONTROL_DIR"
cat << 'EOF' > "$RUN_FILE"
#!/data/data/com.termux/files/usr/bin/sh
# 启动 isg-adb-server（设置端口并重启 adbd）
su -c 'setprop service.adb.tcp.port 5555'
su -c 'stop adbd'
su -c 'start adbd'
adb connect 127.0.0.1:5555
EOF

chmod +x "$RUN_FILE" || true
touch "$DOWN_FILE" || true

# 记录安装历史
record_install_history "SUCCESS" "installed"

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
log "isg-adb-server installation completed in ${DURATION}s"
mqtt_report "isg/install/$SERVICE_ID/status" "{\"service\":\"$SERVICE_ID\",\"status\":\"installed\",\"duration\":$DURATION,\"timestamp\":$END_TIME}"

exit 0
