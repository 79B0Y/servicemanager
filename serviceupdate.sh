#!/data/data/com.termux/files/usr/bin/sh

set -euo pipefail


pkg update -y

# 根据requirements.yaml安装依赖开始
echo "根据requirements.yaml安装依赖开始"
# 默认文件路径
YAML_FILE="${1:-/data/data/com.termux/files/home/servicemanager/requirements.yaml}"

# 检查文件是否存在
if [[ ! -f "$YAML_FILE" ]]; then
    echo "错误: 文件 $YAML_FILE 不存在"
    exit 1
fi

# 函数：清理命令字符串
clean_command() {
    local cmd="$1"
    cmd=$(echo "$cmd" | sed 's/^[[:space:]]*-[[:space:]]*//')
    cmd=$(echo "$cmd" | sed 's/[[:space:]]*#.*$//')
    cmd=$(echo "$cmd" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    echo "$cmd"
}

# 执行termux命令
execute_termux_commands() {
    local in_termux=0
    local commands=()
    
    while IFS= read -r line; do
        if [[ "$line" =~ ^termux:[[:space:]]*$ ]]; then
            in_termux=1
            continue
        fi
        
        if [[ "$line" =~ ^[a-zA-Z_][a-zA-Z0-9_]*:[[:space:]]*$ ]]; then
            in_termux=0
            continue
        fi
        
        if [[ $in_termux -eq 1 && "$line" =~ ^[[:space:]]*-[[:space:]]+ ]]; then
            cmd=$(clean_command "$line")
            if [[ -n "$cmd" ]]; then
                commands+=("$cmd")
            fi
        fi
    done < "$YAML_FILE"
    
    if [[ ${#commands[@]} -gt 0 ]]; then
        echo "开始安装"
        for cmd in "${commands[@]}"; do
            echo "执行: $cmd"
            if ! eval "$cmd"; then
                echo "错误: 命令执行失败 - $cmd"
                exit 1
            fi
        done
        echo "已经安装"
    fi
}

# 执行proot_ubuntu命令
execute_proot_ubuntu_commands() {
    local in_proot=0
    local commands=()
    
    while IFS= read -r line; do
        if [[ "$line" =~ ^proot_ubuntu:[[:space:]]*$ ]]; then
            in_proot=1
            continue
        fi
        
        if [[ "$line" =~ ^[a-zA-Z_][a-zA-Z0-9_]*:[[:space:]]*$ ]]; then
            in_proot=0
            continue
        fi
        
        if [[ $in_proot -eq 1 && "$line" =~ ^[[:space:]]*-[[:space:]]+ ]]; then
            cmd=$(clean_command "$line")
            if [[ -n "$cmd" ]]; then
                commands+=("$cmd")
            fi
        fi
    done < "$YAML_FILE"
    
    if [[ ${#commands[@]} -gt 0 ]]; then
        echo "进入proot安装"
        
        local temp_script=$(mktemp)
        cat > "$temp_script" << 'EOF'
#!/bin/bash
set -e
EOF
        
        for cmd in "${commands[@]}"; do
            echo "echo \"执行: $cmd\"" >> "$temp_script"
            echo "$cmd" >> "$temp_script"
        done
        
        if ! proot-distro login ubuntu -- bash -c "$(cat "$temp_script")"; then
            echo "错误: proot命令执行失败"
            rm -f "$temp_script"
            exit 1
        fi
        
        rm -f "$temp_script"
        echo "proot安装完成"
    fi
}

# 主执行
if grep -q "^termux:" "$YAML_FILE"; then
    execute_termux_commands
fi

if grep -q "^proot_ubuntu:" "$YAML_FILE"; then
    execute_proot_ubuntu_commands
fi
# 根据requirements.yaml安装依赖结束
echo "根据requirements.yaml安装依赖结束"

CONFIG_FILE="/data/data/com.termux/files/home/servicemanager/configuration.yaml"
JSON_FILE="/data/data/com.termux/files/home/servicemanager/serviceupdate.json"
BASE_DIR="/data/data/com.termux/files/home/servicemanager"

# 提取 MQTT 配置字段
get_config() {
  local key=$1
  grep -A 10 '^mqtt:' "$CONFIG_FILE" | grep -E "^\s*$key:" | sed -E "s/^\s*$key:\s*\"?([^\"#]+)\"?.*/\1/"
}

MQTT_HOST=$(get_config host)
MQTT_PORT=$(get_config port)
MQTT_USER=$(get_config username)
MQTT_PASS=$(get_config password)

MQTT_ARGS="-h $MQTT_HOST -p $MQTT_PORT -u $MQTT_USER -P $MQTT_PASS"

# 认证头（来自环境变量）
USERID="${USERID:-}"
LOGINSESSION="${LOGINSESSION:-}"

# 检查工具
command -v jq >/dev/null || { echo "缺少 jq"; exit 1; }
command -v mosquitto_pub >/dev/null || { echo "缺少 mosquitto_pub"; exit 1; }

# 遍历所有服务
jq -c '.services[]'  "$JSON_FILE" | while read -r service; do
  id=$(echo "$service" | jq -r '.id')
  if [ -z "$id" ]; then
    echo "[WARN] 跳过空服务 ID"
    continue
  fi
  latest_version=$(echo "$service" | jq -r '.latest_script_version')
  package_url=$(echo "$service" | jq -r '.latest_script_package_url')

  if [ "$id" = "commonservicepackage" ]; then
      current_version_file="$BASE_DIR/commonservicepackage_current_script_version"
  else
    current_version_file="$BASE_DIR/$id/current_script_version"
  fi
  # 如果 latest_version 为空，跳过处理只发 MQTT
  if [ -z "$latest_version" ]; then
    echo "[INFO] [$id] 最新版本为空，跳过处理"
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    mosquitto_pub $MQTT_ARGS -t "isg/scriptpackage/$id/status" -m \
      "{\"updated\":false,\"msg\":\"latest_version empty\",\"timestamp\":\"$timestamp\"}"
    continue
  fi

  current_version=""
  if [ -f "$current_version_file" ]; then
    current_version=$(cat "$current_version_file")
  fi

  if [ "$current_version" = "$latest_version" ]; then
    echo "[INFO] [$id] 当前脚本版本已是最新 ($latest_version)"
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    mosquitto_pub $MQTT_ARGS -t "isg/scriptpackage/$id/status" -m \
      "{\"updated\":false,\"version_after_update\":\"$latest_version\",\"version_before_update\":\"$current_version\",\"timestamp\":\"$timestamp\"}"
  else
    echo "[INFO] [$id] 发现新版本: $current_version → $latest_version"

    tar_file="./${id}-script.tar.gz"

    echo "[INFO] [$id] 下载脚本包到 $tar_file ..."
    if ! curl -fsSL -H "userid: $USERID" -H "loginsession: $LOGINSESSION" -o "$tar_file" "$package_url"; then
      echo "[ERROR] [$id] 下载失败，curl 无法写入 $tar_file"
      mosquitto_pub $MQTT_ARGS -t "isg/scriptpackage/$id/status" -m \
            "{\"updated\":false,\"msg\":\"download script package failed\",\"timestamp\":\"$timestamp\"}"
      continue
    fi

    echo "[INFO] [$id] 解压到 $BASE_DIR ..."
    if ! tar -xzvf "$tar_file" -C "$BASE_DIR" >/dev/null; then
      echo "[ERROR] [$id] 解压失败"
      mosquitto_pub $MQTT_ARGS -t "isg/scriptpackage/$id/status" -m \
                  "{\"updated\":false,\"msg\":\"tar script package failed\",\"timestamp\":\"$timestamp\"}"
      rm -f "$tar_file"
      continue
    fi

    # 处理文件格式和权限
    # 如果是 commonservicepackage，只处理 $BASE_DIR 根目录下的文件
    if [ "$id" = "commonservicepackage" ]; then
      echo "[INFO] [$id] 处理 "$BASE_DIR" 目录下文件的格式与权限..."
      find "$BASE_DIR" -maxdepth 1 -type f -exec dos2unix {} \; >/dev/null 2>&1
      find "$BASE_DIR" -maxdepth 1 -type f -exec chmod +x {} \;
    else
      echo "[INFO] [$id] 处理 $BASE_DIR/$id 目录下文件的格式和权限..."
      find "$BASE_DIR/$id" -type f -exec dos2unix {} \; >/dev/null 2>&1
      find "$BASE_DIR/$id" -type f -exec chmod +x {} \;
    fi

    rm -f "$tar_file"

    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    mosquitto_pub $MQTT_ARGS -t "isg/scriptpackage/$id/status" -m \
      "{\"updated\":true,\"version_after_update\":\"$latest_version\",\"version_before_update\":\"$current_version\",\"timestamp\":\"$timestamp\"}"
    echo "$latest_version" > "$current_version_file"
  fi
done
