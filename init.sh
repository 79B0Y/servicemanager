#!/data/data/com.termux/files/usr/bin/sh

# 日期： 20250529
# 更新内容：
#   1. 使用iSG Temux 新框架
#   2. 使用新版Python 和 HomeAssistant
#   3. 安装日志输出
# 运行方法
#  1. 直接运行： chmod +x ./init.sh && nohup ./init.sh > init.log 2>&1 &， 日志还可以看 /sdcard/Download/log/termux/termux_init.log
#  2. 下载运行： pkg install -y wget && wget https://eucfg.linklinkiot.com/isg/container_complete_init_v3.sh -O init.sh && chmod +x init.sh && nohup ./init.sh > init.log 2>&1 &


IMAGE_VER="20250619"
# 初始化日志文件
LOG_DIR="/sdcard/Download/log/termux"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/termux_init.log"

# 检查文件是否存在，并且包含 "INSTALL_COMPLETE"
FLAG_FILE="/data/data/com.termux/imgflag"
if [ -f "$FLAG_FILE" ] && grep -q "INSTALL_COMPLETE" "$FLAG_FILE"; then
    echo "already  INSTALL_COMPLETE，exit"
    exit 0
fi

# 如果不包含 INSTALL_COMPLETE，继续执行后续代码
echo "not INSTALL_COMPLETE，start install..."


VER_FILE="$LOG_DIR/detail_version"
PROOT_ERR_FILE="$LOG_DIR/termux_proot_err.log"
su 0 chmod 777 -R "$LOG_DIR"
: > "$LOG_FILE" # 清空原日志文件
log_step() {
    local step="$1"
    local msg="$2"
    local info="$3"
    local now
    now="$(date +"%Y-%m-%d %H:%M:%S")"
    printf "\n[%s] ==== STEP %s %s {%s}\n" "$now" "$step" "$msg" "$info" | tee -a "$LOG_FILE"
}

log_info() {
    local msg="$1"
    local now
    now="$(date +"%Y-%m-%d %H:%M:%S")"
    echo "[$now] $msg" | tee -a "$LOG_FILE"
}

run_or_fail() {
    local step="$1"
    local cmd="$2"
    local info="$3"


    # 执行命令，分别捕获 stdout 和 stderr
    eval "$cmd"
    local code=$?

    if [ $code -ne 0 ]; then
        # 将错误输出记录到 log_step
        log_step "${step}" "[ERROR] $cmd failed" "$info"
        exit $code
    fi

    # 清理临时文件
    rm -f "$stdout_file" "$stderr_file"
}

log_version() {
  local msg="$1"
  echo "$msg" | tee -a "$VER_FILE"
}

echo "$(date +"%Y-%m-%d %H:%M:%S") IMAGE_VER: $IMAGE_VER" > "$VER_FILE"
echo "[$(date +"%Y-%m-%d %H:%M:%S")] INSTALL_START" > "$FLAG_FILE"
# 1.基本设置
# 1.1.输出系统基本信息，安卓安卓版本，termux系统信息，白名单列表等
log_step "1"   "Some Android Setting And Info" "1/16,130,0"
log_version "============= SYSTEM INFO==========="
log_info "Android Version: $(getprop ro.build.version.release)"
log_info "System: $(uname -a)"
log_info "Termux Info: $(termux-info)"
log_info "Whitelist package:\n$(cmd deviceidle whitelist)"

PREFIX=/data/data/com.termux/files/usr
export PREFIX
export TZ=$(getprop persist.sys.timezone)
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
export TMPDIR=/data/data/com.termux/files/usr/tmp
export PATH=/data/data/com.termux/files/usr/bin:$PATH
# proot-distro 在编译期常见的 seccomp 问题
export PROOT_NO_SECCOMP=1
log_info "Time Zone:$TZ"

echo "Version: Android $(getprop ro.build.version.release)"
echo "Memory:\t$(($(cat /proc/meminfo | grep MemTotal | awk '{print $2}') / 1024))MB"
echo "CPU:\t$(cat /proc/cpuinfo | grep "processor" | wc -l) Cores"
echo "Architecture:\t$(getprop ro.product.cpu.abi)"
echo "Termux App Version:\t$(termux-info|grep TERMUX_VERSION | cut -d= -f2)"
echo "\n"
termux-setup-storage &

echo "======== ENV ========="
env
echo "whoami:$(whoami)"
echo "======== ENV END ========="
# 设置一些环境变量
export UBTDIR=/data/data/com.termux/files/usr/var/lib/proot-distro/installed-rootfs/ubuntu
export LSVDIR=/data/data/com.termux/files/usr/var/service
export LLOGDIR=/sdcard/Download/log
export LBKDIR=/sdcard/Download/backup
sleep 1

# 1.2. 设置termux唤醒锁，修改进程数限制
termux-wake-lock
su 0 device_config put activity_manager max_phantom_processes 65536
su 0 device_config put activity_manager max_cached_processes 65536


# 2. 更新termux系统，SSH密码设置
log_step "2"   "Package Update & Upgrade" "2/16,129,1"
run_or_fail "2" "yes N | pkg update -y" "2/16,129,1"
cat > /data/data/com.termux/files/usr/etc/profile.d/runit-env.sh << 'EOF_ENV'
# Termux/Runit base env
PREFIX=/data/data/com.termux/files/usr
export PREFIX
export PATH=$PREFIX/bin:$PATH
export LD_PRELOAD=$PREFIX/lib/libtermux-exec-ld-preload.so
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
export TZ=$(getprop persist.sys.timezone)
export TMPDIR=$PREFIX/tmp
# proot-distro 在编译期常见的 seccomp 问题
export PROOT_NO_SECCOMP=1
EOF_ENV


. /data/data/com.termux/files/usr/etc/profile.d/runit-env.sh

run_or_fail "2" "DEBIAN_FRONTEND=noninteractive pkg upgrade -y" "2/16,129,1"

export LD_PRELOAD=/data/data/com.termux/files/usr/lib/libtermux-exec-ld-preload.so
# 3. 安装配置一些基本的库，软件
log_step "3"   "Install And Config some basic software(ssh, runsv, mosquitto,mariadb,wget....)" "3/16,129,3"

pkg install -y mosquitto wget vim rsync git build-essential openssl openssl-tool termux-services
pkill -f "runsv"

rm -f "$PREFIX/var/service/mosquitto/down"
export SVDIR=$PREFIX/var/termuxservice
export LOGDIR=$PREFIX/var/log

# 3.1 更改termux-services配置并迁移 mysqld 与 sshd
log_step "3.1" "Change termux-services default Dir and move mysqld, sshd" "3/16,129,3"
mkdir -p $PREFIX/var/termuxservice
echo "export SVDIR=$PREFIX/var/termuxservice
export LOGDIR=$PREFIX/var/log
export UBTDIR=/data/data/com.termux/files/usr/var/lib/proot-distro/installed-rootfs/ubuntu
export LSVDIR=/data/data/com.termux/files/usr/var/service
export LLOGDIR=/sdcard/Download/log
export LBKDIR=/sdcard/Download/backup
" > /data/data/com.termux/files/usr/etc/profile.d/start-services.sh

pkg install -y openssh mariadb
mv "$PREFIX/var/service/mysqld" "$PREFIX/var/service/sshd" "$PREFIX/var/termuxservice/" 2>/dev/null
rm -f "$PREFIX/var/termuxservice/sshd/down"


pgrep -f "runsvdir /data/data/com.termux/files/usr/var/termuxservice" > /dev/null || runsvdir /data/data/com.termux/files/usr/var/termuxservice &

# 3.2 设置当前账号
log_step "3.2" "Set Password" "3/16,128,3"
printf "linknlink123\nlinknlink123" | passwd
sshd


# 3.3 设置数据库密码
log_step "3.3" "Set MariaDB password Start" "3/16,128,3"
#$SHELL -l -c "sv-enable mysqld" > /dev/null 2>&1 || /data/data/com.termux/files/usr/var/termuxservice/mysqld/run > /dev/null 2>&1 &
rm -f /data/data/com.termux/files/usr/var/termuxservice/mysqld/down
sleep 1
echo u > /data/data/com.termux/files/usr/var/termuxservice/mysqld/supervise/control
# Wait MariaDB start up
while ! netstat -tunlp 2>/dev/null | grep -q ':3306'; do
    log_info "Waiting for MariaDB to start and listen on port 3306..."
    sleep 1
done
log_info "MariaDB is listening on port 3306."
mariadb -uroot -e "ALTER USER 'root'@'localhost' IDENTIFIED BY 'linknlink123'"
mariadb -uroot -plinknlink123 -e "FLUSH PRIVILEGES"
log_step "3.3" "Set MariaDB password Done" "3/16,128,3"

# 3.4 修改MQTT配置文件并重启MQTT
log_step "3.4" "Set MQTT Conf Start" "3/16,128,3"
cat $PREFIX/etc/mosquitto/mosquitto.conf | grep -q "listener 1883 0.0.0.0"|| (echo "listener 1883 0.0.0.0" >> $PREFIX/etc/mosquitto/mosquitto.conf)
cat $PREFIX/etc/mosquitto/mosquitto.conf | grep -v "#.*allow_anonymous" | grep -q "allow_anonymous" || echo "allow_anonymous true" >> $PREFIX/etc/mosquitto/mosquitto.conf
sleep 1
echo '#!/data/data/com.termux/files/usr/bin/sh
exec mosquitto -c /data/data/com.termux/files/usr/etc/mosquitto/mosquitto.conf 2>&1' > $PREFIX/var/service/mosquitto/run

#($SHELL -l -c "sv restart mosquitto")
#($SHELL -l -c "sv-enable mosquitto")
log_step "3.4" "Set MQTT Conf Done" "3/16,128,3"


# 3.5 安装我们自己的addon服务
log_step "3.5" "Install linknlink software" "3/16,128,3"
log_info "Install isgaddonmanager"
mariadb -uroot -plinknlink123 -e "CREATE DATABASE IF NOT EXISTS service_monitor DEFAULT CHARACTER SET UTF8;"
mariadb -uroot -plinknlink123 -e "GRANT ALL PRIVILEGES ON service_monitor.* TO 'isgaddonmanager'@'127.0.0.1' IDENTIFIED BY 'isgaddonmanager' WITH MAX_USER_CONNECTIONS 128;"
rm -f isgaddonmanager_latest_termux_arm.deb
wget --no-check-certificate https://eucfg.linklinkiot.com/isg/isgaddonmanager_latest_termux_arm.deb
dpkg -i isgaddonmanager_latest_termux_arm.deb
rm isgaddonmanager_latest_termux_arm.deb



log_info "Install isg-performance-monitor"
mkdir -p "$PREFIX/../usr/var/webui/" && \
wget --no-check-certificate -qO- https://eucfg.linklinkiot.com/isg/isg-performance-monitor-develop.tar.gz | tar -xzv -C "$PREFIX/../usr/var/webui/"

log_info "Install isgelecstat"
rm -f isgelecstat-latest-termux-arm.deb
wget --no-check-certificate https://eucfg.linklinkiot.com/isg/isgelecstat-latest-termux-arm.deb
dpkg -i isgelecstat-latest-termux-arm.deb
rm isgelecstat-latest-termux-arm.deb

log_info "Install isgdatamanager"
rm -f isgdatamanager-latest-termux-arm.deb
wget --no-check-certificate https://eucfg.linklinkiot.com/isg/isgdatamanager-latest-termux-arm.deb
dpkg -i isgdatamanager-latest-termux-arm.deb
rm isgdatamanager-latest-termux-arm.deb

log_info "Install isgspacemanager"
rm -f isgspacemanager-latest-termux-arm.deb
wget --no-check-certificate https://eucfg.linklinkiot.com/isg/isgspacemanager-latest-termux-arm.deb
dpkg -i isgspacemanager-latest-termux-arm.deb
rm isgspacemanager-latest-termux-arm.deb

log_info "Install isgdida"
rm -f isgdida-latest-termux-arm.deb
wget --no-check-certificate https://eucfg.linklinkiot.com/isg/isgdida-latest-termux-arm.deb
dpkg -i isgdida-latest-termux-arm.deb
rm isgdida-latest-termux-arm.deb

log_info "Install isgtrigger"
rm -f isgtrigger-latest-termux-arm.deb
wget --no-check-certificate https://eucfg.linklinkiot.com/isg/isgtrigger-latest-termux-arm.deb
dpkg -i isgtrigger-latest-termux-arm.deb
rm isgtrigger-latest-termux-arm.deb

log_version "============= PACKAGE INFO==========="
log_version "mosquitto:\t$(dpkg-query -W -f='${Version}' mosquitto | tr -d '\n')"
log_version "mariadb:\t$(dpkg-query -W -f='${Version}' mariadb | tr -d '\n')"
log_version "isgaddonmanager:$(dpkg-query -W -f='${Version}' isgaddonmanager)"
log_version "isgspacemanager:$(dpkg-query -W -f='${Version}' isgspacemanager)"
log_version "isgelecstat:\t$(dpkg-query -W -f='${Version}' isgelecstat)"
log_version "isgelecstat:\t$(dpkg-query -W -f='${Version}' isgelecstat)"
log_version "isgdida:\t$(dpkg-query -W -f='${Version}' isgdida)"
log_version "isgtrigger:\t$(dpkg-query -W -f='${Version}' isgtrigger)"


log_step "4"   "Install proot & ubuntu" "4/16,125,6"
pkg install -y proot proot-distro

if [ -d "$PREFIX/var/lib/proot-distro/installed-rootfs/ubuntu" ]; then
    log_step "4" "Ubuntu already installed, skip install." "4/16,125,6"
else
    run_or_fail "4" "proot-distro install ubuntu" "4/16,125,6"
fi

#pkg install sshpass -y

#. /data/data/com.termux/files/usr/etc/profile
#sshpass -p "linknlink123" ssh -P 8022 root@127.0.0.1
#. /data/data/com.termux/files/usr/etc/profile

proot-distro login ubuntu << 'EOF'
LOG_FILE="/sdcard/Download/log/termux/termux_init.log"
PROOT_ERR_FILE="/sdcard/Download/log/termux/termux_proot_err.log"
VER_FILE="/sdcard/Download/log/termux/detail_version"

export TZ=$(getprop persist.sys.timezone)
log_step() {
    local step="$1"
    local msg="$2"
    local info="$3"
    local now
    now="$(date +"%Y-%m-%d %H:%M:%S")"
    printf "\n[%s] [PROOT] ==== STEP %s %s {%s}\n" "$now" "$step" "$msg" "$info" | tee -a "$LOG_FILE"
}

log_info() {
    local msg="$1"
    local now
    now="$(date +"%Y-%m-%d %H:%M:%S")"
    echo "[$now][PROOT] $msg" | tee -a "$LOG_FILE"
}

run_or_fail() {
    local step="$1"
    local cmd="$2"
    local info="$3"


    eval "$cmd"
    local code=$?

    if [ $code -ne 0 ]; then
        # 将错误输出记录到 log_step
        log_step "${step}" "[ERROR] $cmd failed: $error_output" "$info"
        echo "$cmd failed: $error_output $info" > "$PROOT_ERR_FILE"
        exit $code
    fi

    # 清理临时文件
    rm -f "$stdout_file"
}

log_version() {
  local msg="$1"
  echo -e "[PROOT] $msg" | tee -a "$VER_FILE"
}
log_info "Time Zone:$TZ"
log_step "5"   "Login ubuntu, Update & Upgrade" "5/16,122,8"
apt update && apt upgrade -y

log_step "6"   "Download, Build, Install Python" "6/16,118,10"
log_step "6.1"   "Install Python build dependencies" "6/16,118,10"
apt install -y build-essential zlib1g-dev libncurses5-dev libgdbm-dev \
  libnss3-dev libssl-dev libreadline-dev libffi-dev curl libbz2-dev \
  libpcap-dev libsqlite3-dev wget


log_step "6.2"   "Download Python source code" "6/16,118,12"
apt install wget
wget https://www.python.org/ftp/python/3.13.3/Python-3.13.3.tar.xz
tar -xf Python-3.13.3.tar.xz


log_step "6.3"   "Prepare the build system. May takes more than 8 minutes." "6/16,118,13" # 配置编译参数
cd Python-3.13.3
run_or_fail "6.3" "./configure --enable-optimizations --enable-loadable-sqlite-extensions --disable-werror" "6/16,118,13"

log_step "6.4"   "Builds the Python source code. May takes more than 50 minutes." "6/16,110,16"
make -j$(nproc)

log_step "6.5"   "Install Python" "6/16,68,60"
make altinstall
check_output=$(python3.13 -c "import sys, os; print(os.path.exists('/usr/local/lib/python3.13/encodings/__init__.py'))")
if [ "$check_output" != "True" ]; then
    log_step "6.5" "First make altinstall not pass, retry..." "6/16,68,60"
    run_or_fail "6.5" "make altinstall" "6/16,68,60"
else
    log_step "6.5" "make altinstall success" "6/16,67,60"
fi

log_step "6.6"   "Registers the newly installed Python version" "6/16,67,60"
cmd="update-alternatives --install /usr/bin/python3 python3 /usr/local/bin/python3.13 1"
run_or_fail "6.6" "$cmd" "6/16,67,60"
cmd="update-alternatives --set python3 /usr/local/bin/python3.13"
run_or_fail "6.6" "$cmd" "6/16,67,60"

#update-alternatives --config python3

log_step "6.99"   "Download, Build, Install Python Done. Version: $(python3.13 --version)" "6/16,66,61"
log_version "$(python3.13 --version)"
run_or_fail "6.99" "python3.13 --version" "6/16,66,61"

log_step "7"   "Use new Python to upgrade pip" "7/16,60,62"
cmd="python3.13 -m pip install --upgrade pip"
run_or_fail "7" "$cmd" "7/16,60,62"

# 安装HA
log_step "8"   "Steup HomeAssistant Start" "8/16,59,63"

log_step "8.1"   "Install ffmpeg libturbojpeg. May takes more than 10 minutes." "8/16,58,64"
cmd="apt install -y ffmpeg libturbojpeg"
run_or_fail "8.1" "$cmd" "8/16,58,64"

log_step "8.2"   "Create and enter python source env" "8/16,57,65"
cd ~
cmd="python3 -m venv homeassistant"
run_or_fail "8.2" "$cmd" "8/16,57,65"
source homeassistant/bin/activate

log_step "8.3"   "install some libs" "8/16,57,66"
pip install --upgrade pip
pip install numpy mutagen pillow aiohttp_fast_zlib
pip install aiohttp==3.10.8 attrs==23.2.0
pip install PyTurboJPEG
turbolibversion=$(pip list | grep 'PyTurboJPEG' | awk '{printf "%s %s ", $1, $2}' | sed 's/ $//')
log_step "8.3" "PyTurboJPEG installed: $turbolibversion" "8/16,46,74"

log_step "8.4"   "pip install homeassistant" "8/16,56,67"
mkdir -p ~/homeassistant
cd ~/homeassistant
cmd="pip install homeassistant==2025.5.3"
run_or_fail "8.4" "$cmd" "8/16,56,67"
log_version "homeassistant:\t$(hass --version)"

log_step "8.5"   "Start Home Assistant and wait init complete" "8/16,45,73"
hass &
HASS_PID=$!

log_info "Home Assistant starting with pid:$HASS_PID"

MAX_TRIES=90
COUNT=0
while [ $COUNT -lt $MAX_TRIES ]; do
    log_info "Check Home Assistant status  $((COUNT + 1)) of $MAX_TRIES..."
    if curl -s --head --request GET "http://127.0.0.1:8123" | grep -q -E "200 OK|302 Found"; then
        log_info "Home Assistant is up Now"
        break
    fi
    COUNT=$((COUNT + 1))
    sleep 60
done

if [ $COUNT -ge $MAX_TRIES ]; then
    log_info "[ERROR] Home Assistant did not become available after $MAX_TRIES attempts. Exiting"
    exit 1
fi

log_step "8.6"   "Terminate Home Assistant and install zlib-ng and isal with no binary..." "8/16,40,77"
kill $HASS_PID
pip install zlib-ng isal --no-binary :all:
libversion=$(pip list | grep -E 'zlib-ng|isal' | awk '{printf "%s %s ", $1, $2}' | sed 's/ $//')
log_step "8.6" "zlib-ng  isal installed: $libversion" "8/16,40,77"
log_version "key library version:\t$libversion $turbolibversion"

# 更改日志级别
grep -q '^logger:' /root/.homeassistant/configuration.yaml || echo -e '\nlogger:\n  default: critical\n' >> /root/.homeassistant/configuration.yaml
# 增加 iframe 支持
grep -q 'use_x_frame_options:' /root/.homeassistant/configuration.yaml || echo -e '\nhttp:\n  use_x_frame_options: false' >> /root/.homeassistant/configuration.yaml

log_step "8.99"   "Steup HomeAssistant Done, Version:$(hass --version)" "8/16,40,77"

log_step "9"   "Install HACS" "9/16,35,79"
wget -O - https://get.hacs.xyz | bash -

log_step "10"   "Install Nodejs and pnpm" "10/16,25,81"
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs git make g++ gcc libsystemd-dev
npm install -g pnpm@10.11.0
log_step "10.99"   "Install Nodejs and pnpm end. Node version:$(node --version), pnpm version:$(pnpm --version)" "10/16,22,83"
log_version "Nodejs:\t$(node --version)"
log_version "pnpm:\t$(pnpm --version)"

log_step "11"   "Install zigbee2mqtt" "11/16,20,84"
log_step "11.1"   "Download zigbee2mqtt" "11/16,20,84"
mkdir -p /opt/zigbee2mqtt
chown -R ${USER}: /opt/zigbee2mqtt
git clone --depth 1 https://github.com/Koenkk/zigbee2mqtt.git /opt/zigbee2mqtt
cd /opt/zigbee2mqtt

log_step "11.2"   "Build zigbee2mqtt. May takes a long time." "11/16,19,85"
pnpm i --frozen-lockfile --ignore-scripts
pnpm run build
echo 'export PNPM_HOME=$HOME/.pnpm-global' >> ~/.bashrc
echo 'export PATH=$PNPM_HOME:$PATH' >> ~/.bashrc
source ~/.bashrc
Z2MVERSION=$(grep -m1 '"version"' /opt/zigbee2mqtt/package.json | sed -E 's/.*"version": *"([^"]+)".*/\1/')
if [ -z "$Z2MVERSION" ]; then
  log_info "[ERROR] zigbee2mqtt install failed. Exiting"
  exit 1
else
  log_step "11"   "Install zigbee2mqtt success. Version: $Z2MVERSION" "11/16,16,86"
fi
log_version "Z2M:\t$Z2MVERSION"

log_step "11"   "Install zigbee2mqtt end" "11/16,16,86"

log_step "12"   "Install zwave-js-ui" "12/16,16,86"

SHELL=/data/data/com.termux/files/usr/bin/bash
source ~/.bashrc
SHELL=/data/data/com.termux/files/usr/bin/bash pnpm setup
SHELL=/data/data/com.termux/files/usr/bin/bash pnpm add -g zwave-js-ui

ZUIVERSION=$(grep '"version"' "/root/.pnpm-global/global/5/node_modules/zwave-js-ui/package.json" | head -n 1 | sed -E 's/.*"version": *"([^"]+)".*/\1/')
if [ -z "$ZUIVERSION" ]; then
  log_info "[ERROR] zwave-js-ui install failed. Exiting"
  exit 1
else
  log_step "12"   "Install zwave-js-ui success. Version: $ZUIVERSION" "12/16,13,88"
fi
log_version "ZWave-js-ui:\t$ZUIVERSION"
EOF

if [ -s "$PROOT_ERR_FILE" ]; then
  log_step "13" "[ERROR] installation in proot failed. $(<"$PROOT_ERR_FILE")" "13/16,13,89"
  rm -f "$PROOT_ERR_FILE"
  exit 1
fi

log_step "13"   "Construct hass service" "13/16,13,89"
mkdir -p $PREFIX/var/service/hass/log
echo '#!/data/data/com.termux/files/usr/bin/sh
exec  proot-distro login ubuntu << EOF
source /root/homeassistant/bin/activate
hass
EOF
2>&1' > $PREFIX/var/service/hass/run
ln -sf $PREFIX/share/termux-services/svlogger $PREFIX/var/service/hass/log/run
chmod 755 -R $PREFIX/var/service/hass/log
chmod +x $PREFIX/var/service/hass/run
sleep 5
netstat -tunlp 2>/dev/null | grep -q ':8123' || echo r > "$PREFIX/var/service/hass/supervise/control"

log_step "14"   "Install isgservicemonitor" "14/16,12,90"
rm -f isgservicemonitor_latest_termux_arm.deb
wget --no-check-certificate https://eucfg.linklinkiot.com/isg/isgservicemonitor_latest_termux_arm.deb
dpkg -i isgservicemonitor_latest_termux_arm.deb
rm isgservicemonitor_latest_termux_arm.deb
log_version "isgservicemonitor:\t$(dpkg-query -W -f='${Version}' isgservicemonitor)"

log_step "15"   "Write linklink script & set MQTT default user&password" "15/16,10,93"
cat > "$PREFIX/bin/linklink" << 'EOF'
#!/data/data/com.termux/files/usr/bin/sh

. /data/data/com.termux/files/usr/etc/profile.d/start-services.sh
LOG_FILE="/data/data/com.termux/files/home/linklink.log"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

MONITOR_PATH="/data/data/com.termux/files/usr/var/termuxservice/isgservicemonitor/isgservicemonitor"
TOML_PATH="/data/data/com.termux/files/usr/var/termuxservice/isgservicemonitor/output/isgservicemonitor.toml"

is_isg_running=$(pgrep -f "^${MONITOR_PATH}$")
is_runsvdir_running=$(pgrep -x /data/data/com.termux/files/usr/bin/runsvdir)

if [ -z "$is_isg_running" ] && [ -z "$is_runsvdir_running" ]; then
  log "isgservicemonitor 和 runsvdir 都未运行，启动 isgservicemonitor..."
  export SVDIR=$PREFIX/var/termuxservice
  export LOGDIR=$PREFIX/var/log
  export TZ=$(getprop persist.sys.timezone)
  "$MONITOR_PATH" -p revocer -f "$TOML_PATH" >> "$LOG_FILE" 2>&1
else
  [ -n "$is_isg_running" ] && log "isgservicemonitor 运行中，PID: $is_isg_running"
  [ -n "$is_runsvdir_running" ] && log "runsvdir 运行中，PID: $is_runsvdir_running"
fi
EOF
chmod +x "$PREFIX/bin/linklink"

sleep 300

URL="http://127.0.0.1:54328/isgaddonmanager/cmd"
DATA='{"addonid":"201","configlist":{"password":"admin","username":"admin"},"name":"MQTT Broker","operation":"config"}'

MAX_TRIES=10
success=false
for i in $(seq 1 $MAX_TRIES); do
    echo "Attempt $i..."

    response=$(curl -s -X POST "$URL" -d "$DATA")
    status=$(echo "$response" | grep -o '"status":[0-9]*' | cut -d':' -f2)

    echo "Response: $response"

    if [ "$status" = "0" ]; then
        echo "Success: status == 0"
        success=true
        break
    fi

    echo "isgaddonmanager not ready (status=$status), retrying in 1 second..."
    sleep 1
done
if [ "$success" = true ]; then
    echo "Set MQTT Broker User&Password succeeded, continuing..."
else
    echo "Max retries reached, exiting..."
    exit 1
fi

log_step "15,1"   "Construct zigbee2mqtt  and zwave-js-ui service" "15/16,10,93"
#构建zigbee2mqtt service
mkdir -p $PREFIX/var/service/zigbee2mqtt/supervise
touch $PREFIX/var/service/zigbee2mqtt/down
echo  '#!/data/data/com.termux/files/usr/bin/sh
exec proot-distro login ubuntu << EOF
  npm --prefix /opt/zigbee2mqtt/ start
EOF
2>&1
fi

' >  "$PREFIX/var/service/zigbee2mqtt/run"
chmod +x $PREFIX/var/service/zigbee2mqtt/run



## 构建zwave-js-ui
mkdir -p "$PREFIX/var/service/zwave-js-ui/supervise"
touch $PREFIX/var/service/zwave-js-ui/down
echo '#!/data/data/com.termux/files/usr/bin/sh
if command -v zwave-js-ui > /dev/null 2>&1; then
  exec zwave-js-ui 2>&1
else
  exec proot-distro login ubuntu << EOF
  /root/.pnpm-global/zwave-js-ui
EOF
  2>&1
fi

'> "$PREFIX/var/service/zwave-js-ui/run"
chmod +x $PREFIX/var/service/zwave-js-ui/run


log_step "16"   "Install isg Web" "16/16,5,96"
mariadb -uroot -plinknlink123 -e "CREATE DATABASE IF NOT EXISTS isgdevicemanager DEFAULT CHARACTER SET UTF8;"
mariadb -uroot -plinknlink123 -e "GRANT ALL PRIVILEGES ON isgdevicemanager.* TO 'isgdevicemanager'@'127.0.0.1' IDENTIFIED BY '7x2Lp9@qZ#2D' WITH MAX_USER_CONNECTIONS 128;"

log_info "install isgweb backend service"
rm -f isgdevicemanager_latest_termux_arm.deb
wget --no-check-certificate https://eucfg.linklinkiot.com/isg/isgdevicemanager_latest_termux_arm.deb
dpkg -i isgdevicemanager_latest_termux_arm.deb
rm -f isgdevicemanager_latest_termux_arm.deb
sleep 1
echo t > /data/data/com.termux/files/usr/var/service/isgdevicemanager/supervise/control
sleep 1
ps -ef | grep "/data/data/com.termux/files/usr/var/service/isgdevicemanager/isgdevicemanager"

log_info "install isgwebui"
rm -f isg-web_latest_termux_arm.deb
wget --no-check-certificate https://eucfg.linklinkiot.com/isg/isg-web_latest_termux_arm.deb
dpkg -i isg-web_latest_termux_arm.deb
rm isg-web_latest_termux_arm.deb

log_step "99"   "Init End" "15/16,0,100"

#设置版本信息
mkdir -p /data/data/com.termux/files/usr/var/webui/isg-performance-monitor-develop/release
echo  "$IMAGE_VER" > "/data/data/com.termux/files/usr/var/webui/isg-performance-monitor-develop/release/image_version"
cp $VER_FILE "/data/data/com.termux/files/usr/var/webui/isg-performance-monitor-develop/release/"

echo "[$(date +"%Y-%m-%d %H:%M:%S")] INSTALL_COMPLETE" >> "$FLAG_FILE"
