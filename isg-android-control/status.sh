#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# isg-android-control 状态查询脚本 - 调试版本
# 用于诊断版本获取问题
# =============================================================================

set -euo pipefail

SERVICE_ID="isg-android-control"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"
PROOT_DISTRO="${PROOT_DISTRO:-ubuntu}"
ANDROID_CONTROL_INSTALL_DIR="/root/android-control"

echo "=== 调试 isg-android-control 版本获取 ==="

# 1. 检查VERSION文件
VERSION_FILE="$BASE_DIR/$SERVICE_ID/VERSION"
echo "1. 检查VERSION文件: $VERSION_FILE"
if [[ -f "$VERSION_FILE" ]]; then
    echo "   文件存在，内容："
    cat "$VERSION_FILE" | hexdump -C
    echo "   清理后的内容: '$(cat "$VERSION_FILE" | tr -d '\n\r\t ')'"
else
    echo "   文件不存在"
fi

# 2. 检查安装目录
echo ""
echo "2. 检查安装目录:"
proot-distro login "$PROOT_DISTRO" -- ls -la /root/android-control/ || echo "   目录不存在或无法访问"

# 3. 检查可执行文件
echo ""
echo "3. 检查可执行文件:"
proot-distro login "$PROOT_DISTRO" -- ls -la /root/android-control/isg-android-control || echo "   文件不存在"

# 4. 测试版本命令 - 方法1
echo ""
echo "4. 测试版本命令 - 直接执行:"
proot-distro login "$PROOT_DISTRO" -- /root/android-control/isg-android-control version || echo "   命令执行失败"

# 5. 测试版本命令 - 方法2  
echo ""
echo "5. 测试版本命令 - 切换目录执行:"
proot-distro login "$PROOT_DISTRO" -- bash -c "cd /root/android-control && ./isg-android-control version" || echo "   命令执行失败"

# 6. 测试版本命令 - 方法3
echo ""
echo "6. 测试版本命令 - 使用bash -lc:"
proot-distro login "$PROOT_DISTRO" -- bash -lc "cd /root/android-control && ./isg-android-control version" || echo "   命令执行失败"

# 7. 测试输出捕获
echo ""
echo "7. 测试输出捕获:"
TEMP_FILE="/tmp/debug_version_$$"
if proot-distro login "$PROOT_DISTRO" -- bash -c "cd /root/android-control && ./isg-android-control version" > "$TEMP_FILE" 2>&1; then
    echo "   捕获成功，文件大小: $(wc -c < "$TEMP_FILE")"
    echo "   文件内容（十六进制）:"
    cat "$TEMP_FILE" | hexdump -C
    echo "   文件内容（原始）:"
    cat "$TEMP_FILE"
    echo "   文件内容（清理后）: '$(cat "$TEMP_FILE" | head -n1 | tr -d '\n\r\t ')'"
else
    echo "   捕获失败，错误输出:"
    cat "$TEMP_FILE"
fi
rm -f "$TEMP_FILE"

# 8. 检查进程
echo ""
echo "8. 检查进程:"
PID=$(pgrep -f "python3 -m isg_android_control.run" 2>/dev/null || echo "")
if [[ -n "$PID" ]]; then
    echo "   找到进程 PID: $PID"
    echo "   进程命令行: $(cat /proc/$PID/cmdline 2>/dev/null | tr '\0' ' ')"
else
    echo "   未找到运行的进程"
fi

# 9. 检查工作目录
echo ""
echo "9. 检查当前工作目录:"
pwd
echo "   在proot中的工作目录:"
proot-distro login "$PROOT_DISTRO" -- pwd

echo ""
echo "=== 调试完成 ==="
