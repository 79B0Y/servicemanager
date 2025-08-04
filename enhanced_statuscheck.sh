#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# LinknLink Service Manager - Status Check Script (Enhanced)
# 版本: 1.2 (优先从MQTT获取安装状态，检查所有服务，包括 enabled=false)
# =============================================================================

BASE_DIR="/data/data/com.termux/files/home/servicemanager"
CONFIG_FILE="$BASE_DIR/configuration.yaml"
SERVICEUPDATE_FILE="$BASE_DIR/serviceupdate.json"
MQTT_CACHE_FILE="$BASE_DIR/mqtt_install_cache.json"

# MQTT 客户端缓存时间（秒）
MQTT_CACHE_TIMEOUT=300  # 5分钟

# 加载 MQTT 配置
load_mqtt_conf() {
    MQTT_HOST=$(grep -Po '^[[:space:]]*host:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1)
    MQTT_PORT=$(grep -Po '^[[:space:]]*port:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1)
    MQTT_USER=$(grep -Po '^[[:space:]]*username:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1)
    MQTT_PASS=$(grep -Po '^[[:space:]]*password:[[:space:]]*\K.*' "$CONFIG_FILE" | head -n1)
}

# 解析 serviceupdate.json 获取所有 service id (无视 enabled)
load_services() {
    SERVICES=$(jq -r '.services[].id' "$SERVICEUPDATE_FILE")
}

# MQTT 上报
mqtt_report() {
    local topic=$1
    local payload=$2
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$topic" -m "$payload"
}

# 获取MQTT安装状态缓存
get_mqtt_install_status() {
    local service_id="$1"
    local cache_file="$MQTT_CACHE_FILE"
    local current_time=$(date +%s)
    
    # 检查缓存文件是否存在且未过期
    if [[ -f "$cache_file" ]]; then
        local cache_time=$(jq -r '.timestamp // 0' "$cache_file" 2>/dev/null || echo 0)
        local time_diff=$((current_time - cache_time))
        
        if [[ $time_diff -lt $MQTT_CACHE_TIMEOUT ]]; then
            # 从缓存获取安装状态
            local cached_status=$(jq -r ".services.\"$service_id\".install_status // \"unknown\"" "$cache_file" 2>/dev/null || echo "unknown")
            if [[ "$cached_status" != "unknown" && "$cached_status" != "null" ]]; then
                if [[ "${DEBUG_INSTALL:-0}" == "1" ]]; then
                    echo "   - [DEBUG] 从缓存获取状态: $cached_status (缓存时间: ${time_diff}s前)" >&2
                fi
                echo "$cached_status"
                return 0
            fi
        else
            if [[ "${DEBUG_INSTALL:-0}" == "1" ]]; then
                echo "   - [DEBUG] 缓存已过期 (${time_diff}s > ${MQTT_CACHE_TIMEOUT}s)" >&2
            fi
        fi
    else
        if [[ "${DEBUG_INSTALL:-0}" == "1" ]]; then
            echo "   - [DEBUG] 缓存文件不存在: $cache_file" >&2
        fi
    fi
    
    echo "unknown"
    return 1
}

# 订阅MQTT获取实时安装状态
fetch_mqtt_install_status() {
    local service_id="$1"
    local mqtt_topic="isg/install/$service_id/status"
    local timeout_duration=1  # 进一步减少超时时间到1秒
    
    if [[ "${DEBUG_INSTALL:-0}" == "1" ]]; then
        echo "   - [DEBUG] 尝试从MQTT主题获取: $mqtt_topic (超时: ${timeout_duration}s)" >&2
    fi
    
    # 使用mosquitto_sub获取最新消息，增加调试信息
    local mqtt_message=$(timeout $timeout_duration mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$mqtt_topic" -C 1 2>/dev/null || echo "")
    
    if [[ "${DEBUG_INSTALL:-0}" == "1" ]]; then
        echo "   - [DEBUG] MQTT原始消息: ${mqtt_message:-"(empty)"}" >&2
    fi
    
    if [[ -n "$mqtt_message" && "$mqtt_message" != "null" ]]; then
        # 解析JSON消息获取状态，直接返回原始状态
        local install_status=$(echo "$mqtt_message" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")
        
        if [[ "${DEBUG_INSTALL:-0}" == "1" ]]; then
            echo "   - [DEBUG] 解析状态字段: $install_status" >&2
        fi
        
        # 验证是否为有效的安装状态
        case "$install_status" in
            "installed"|"success"|"installing"|"uninstalling"|"uninstalled"|"failed")
                echo "$install_status"
                return 0
                ;;
            *)
                if [[ "${DEBUG_INSTALL:-0}" == "1" ]]; then
                    echo "   - [DEBUG] 无效状态，返回unknown" >&2
                fi
                echo "unknown"
                return 1
                ;;
        esac
    else
        if [[ "${DEBUG_INSTALL:-0}" == "1" ]]; then
            echo "   - [DEBUG] MQTT无消息或消息为空" >&2
        fi
        echo "unknown"
        return 1
    fi
}

# 更新MQTT缓存
update_mqtt_cache() {
    local service_id="$1"
    local install_status="$2"
    local current_time=$(date +%s)
    
    # 创建或更新缓存文件
    if [[ ! -f "$MQTT_CACHE_FILE" ]]; then
        echo "{\"timestamp\": $current_time, \"services\": {}}" > "$MQTT_CACHE_FILE"
    fi
    
    # 更新特定服务的缓存
    local temp_file=$(mktemp)
    jq ".timestamp = $current_time | .services.\"$service_id\".install_status = \"$install_status\" | .services.\"$service_id\".last_updated = $current_time" "$MQTT_CACHE_FILE" > "$temp_file" && mv "$temp_file" "$MQTT_CACHE_FILE"
}

# 增强的安装状态检查函数
check_service_install_status() {
    local service_id="$1"
    local install_status="unknown"
    
    echo "🔍 检查 $service_id 安装状态..."
    
    # 方法1: 优先从MQTT缓存获取
    install_status=$(get_mqtt_install_status "$service_id")
    if [[ "$install_status" != "unknown" ]]; then
        echo "✅ 从MQTT缓存获取到 $service_id 状态: $install_status"
        return 0
    fi
    
    # 方法2: 实时从MQTT获取
    echo "📡 实时从MQTT获取 $service_id 安装状态..."
    install_status=$(fetch_mqtt_install_status "$service_id")
    if [[ "$install_status" != "unknown" ]]; then
        echo "✅ 从MQTT实时获取到 $service_id 状态: $install_status"
        # 更新缓存
        update_mqtt_cache "$service_id" "$install_status"
        echo "$install_status"
        return 0
    fi
    
    # 方法3: 回退到传统的status.sh检查
    echo "🔧 使用传统方法检查 $service_id 安装状态..."
    local service_dir="$BASE_DIR/$service_id"
    if [[ -f "$service_dir/status.sh" ]]; then
        local status_output=$(bash "$service_dir/status.sh" --json 2>/dev/null || echo '{}')
        local status_install=$(echo "$status_output" | jq -r '.install // "unknown"' 2>/dev/null || echo "unknown")
        
        # 将status.sh的true/false映射为标准状态
        case "$status_install" in
            "true")
                install_status="installed"
                echo "✅ 从status.sh获取到 $service_id 状态: true → installed"
                # 更新缓存
                update_mqtt_cache "$service_id" "$install_status"
                echo "$install_status"
                return 0
                ;;
            "false")
                install_status="uninstalled"
                echo "❌ 从status.sh获取到 $service_id 状态: false → uninstalled"
                # 更新缓存
                update_mqtt_cache "$service_id" "$install_status"
                echo "$install_status"
                return 0
                ;;
            *)
                echo "⚠️  从status.sh获取到未知状态: $status_install"
                ;;
        esac
    else
        echo "❌ status.sh 不存在: $service_dir/status.sh"
    fi
    
    # 方法4: 最后的检查方法 - 检查服务目录和关键文件
    echo "📁 使用文件系统检查 $service_id 安装状态..."
    if [[ -d "$service_dir" ]]; then
        # 检查关键脚本是否存在
        local key_scripts=("install.sh" "start.sh" "stop.sh" "status.sh")
        local script_count=0
        for script in "${key_scripts[@]}"; do
            [[ -f "$service_dir/$script" ]] && ((script_count++))
        done
        
        # 如果大部分关键脚本都存在，认为已安装
        if [[ $script_count -ge 3 ]]; then
            echo "✅ 从文件系统推断 $service_id 状态: installed (found $script_count/4 scripts)"
            install_status="installed"
            # 更新缓存
            update_mqtt_cache "$service_id" "$install_status"
        else
            echo "❌ 从文件系统推断 $service_id 状态: uninstalled (found $script_count/4 scripts)"
            install_status="uninstalled"
            # 更新缓存
            update_mqtt_cache "$service_id" "$install_status"
        fi
    else
        echo "❌ $service_id 服务目录不存在"
        install_status="uninstalled"
        # 更新缓存
        update_mqtt_cache "$service_id" "$install_status"
    fi
    
    echo "$install_status"
    
    echo "$install_status"
}

# 检查服务状态 - 分两阶段上报
check_services() {
    declare -A STATUS_MAP
    declare -A INSTALL_MAP
    STOPPED_SERVICES=()

    echo "🚀 开始检查所有服务状态..."
    
    # ==========================================
    # 第一阶段：快速检查运行状态并立即上报
    # ==========================================
    echo ""
    echo "📊 第一阶段：快速检查运行状态"
    echo "═══════════════════════════════════════"
    
    for SERVICE in $SERVICES; do
        echo "🔍 检查 $SERVICE 运行状态..."
        SERVICE_DIR="$BASE_DIR/$SERVICE"
        
        # 检查运行状态
        if [[ -f "$SERVICE_DIR/status.sh" ]]; then
            STATUS=$(bash "$SERVICE_DIR/status.sh" 2>/dev/null || echo "stopped")
            case "$STATUS" in
                "running")
                    STATUS_MAP["$SERVICE"]="running"
                    echo "✅ $SERVICE: running"
                    ;;
                "starting")
                    STATUS_MAP["$SERVICE"]="starting"
                    echo "🔄 $SERVICE: starting"
                    ;;
                *)
                    STATUS_MAP["$SERVICE"]="stopped"
                    STOPPED_SERVICES+=("$SERVICE")
                    echo "❌ $SERVICE: stopped"
                    ;;
            esac
        else
            STATUS_MAP["$SERVICE"]="stopped"
            STOPPED_SERVICES+=("$SERVICE")
            echo "❌ $SERVICE: stopped (no status.sh)"
        fi
    done

    # 第一次MQTT上报：运行状态
    echo ""
    echo "📡 第一次MQTT上报：运行状态"
    report_status=$(printf '{')
    for SERVICE in "${!STATUS_MAP[@]}"; do
        report_status+="\"$SERVICE\":\"${STATUS_MAP[$SERVICE]}\","
    done
    report_status=${report_status%,}
    report_status+='}'
    mqtt_report "isg/status/all/status" "$report_status"
    echo "✅ 已上报运行状态 (第1次): $report_status"
    
    # 显示第一阶段统计
    local total_services=${#STATUS_MAP[@]}
    local running_count=0
    for service in "${!STATUS_MAP[@]}"; do
        [[ "${STATUS_MAP[$service]}" == "running" ]] && ((running_count++))
    done
    echo "📈 第一阶段统计: 总数 $total_services, 运行中 $running_count, 停止 $((total_services - running_count))"

    # ==========================================
    # 第二阶段：详细检查安装状态
    # ==========================================
    echo ""
    echo "📦 第二阶段：详细检查安装状态"
    echo "═══════════════════════════════════════"
    
    for SERVICE in $SERVICES; do
        echo ""
        echo "🔍 检查 $SERVICE 安装状态..."
        
        # 检查安装状态（使用增强方法）
        INSTALL_STATUS=$(check_service_install_status "$SERVICE")
        
        case "$INSTALL_STATUS" in
            "installed"|"success")
                INSTALL_MAP["$SERVICE"]="$INSTALL_STATUS"
                echo "✅ $SERVICE 安装状态: $INSTALL_STATUS"
                ;;
            "installing")
                INSTALL_MAP["$SERVICE"]="$INSTALL_STATUS"
                echo "🔄 $SERVICE 安装状态: $INSTALL_STATUS"
                ;;
            "uninstalling")
                INSTALL_MAP["$SERVICE"]="$INSTALL_STATUS"
                echo "🗑️  $SERVICE 安装状态: $INSTALL_STATUS"
                ;;
            "uninstalled"|"failed")
                INSTALL_MAP["$SERVICE"]="$INSTALL_STATUS"
                echo "❌ $SERVICE 安装状态: $INSTALL_STATUS"
                ;;
            *)
                INSTALL_MAP["$SERVICE"]="unknown"
                echo "⚠️  $SERVICE 安装状态: unknown"
                ;;
        esac
    done

    # ==========================================
    # 第二次MQTT上报：完整状态（运行状态 + 安装状态）
    # ==========================================
    echo ""
    echo "📡 第二次MQTT上报：完整状态"
    echo "═══════════════════════════════════════"

    # 第二次上报运行状态（确保最新）
    report_status=$(printf '{')
    for SERVICE in "${!STATUS_MAP[@]}"; do
        report_status+="\"$SERVICE\":\"${STATUS_MAP[$SERVICE]}\","
    done
    report_status=${report_status%,}
    report_status+='}'
    mqtt_report "isg/status/all/status" "$report_status"
    echo "✅ 已上报运行状态 (第2次): $report_status"

    # 上报安装状态
    report_install=$(printf '{')
    for SERVICE in "${!INSTALL_MAP[@]}"; do
        install_value="${INSTALL_MAP[$SERVICE]}"
        report_install+="\"$SERVICE\":\"$install_value\","
    done
    report_install=${report_install%,}
    report_install+='}'
    mqtt_report "isg/status/all/install" "$report_install"
    echo "✅ 已上报安装状态: $report_install"
    
    # ==========================================
    # 最终统计和报告
    # ==========================================
    echo ""
    echo "📈 最终状态统计"
    echo "═══════════════════════════════════════"
    
    local installed_count=0
    local installing_count=0
    local uninstalling_count=0
    
    for service in "${!INSTALL_MAP[@]}"; do
        case "${INSTALL_MAP[$service]}" in
            "installed"|"success") ((installed_count++)) ;;
            "installing") ((installing_count++)) ;;
            "uninstalling") ((uninstalling_count++)) ;;
        esac
    done
    
    echo "📊 状态统计:"
    echo "   总服务数: $total_services"
    echo "   运行中: $running_count"
    echo "   停止的: $((total_services - running_count))"
    echo "   已安装: $installed_count"
    echo "   安装中: $installing_count"
    echo "   卸载中: $uninstalling_count"
    
    # 生成详细报告
    if [[ ${#STOPPED_SERVICES[@]} -gt 0 ]]; then
        echo ""
        echo "⚠️  停止的服务详情:"
        for service in "${STOPPED_SERVICES[@]}"; do
            local install_status="${INSTALL_MAP[$service]}"
            case "$install_status" in
                "installed"|"success")
                    echo "   - $service (已安装但未运行)"
                    ;;
                "installing")
                    echo "   - $service (安装中)"
                    ;;
                "uninstalling")
                    echo "   - $service (卸载中)"
                    ;;
                "uninstalled"|"failed")
                    echo "   - $service (未安装)"
                    ;;
                *)
                    echo "   - $service (状态未知)"
                    ;;
            esac
        done
    fi
    
    # 显示检查用时
    local end_time=$(date +%s)
    local duration=$((end_time - START_TIME))
    echo ""
    echo "⏱️  检查耗时: ${duration}s"
}

# 清理过期的MQTT缓存
cleanup_mqtt_cache() {
    if [[ -f "$MQTT_CACHE_FILE" ]]; then
        local current_time=$(date +%s)
        local cache_time=$(jq -r '.timestamp // 0' "$MQTT_CACHE_FILE" 2>/dev/null || echo 0)
        local time_diff=$((current_time - cache_time))
        
        if [[ $time_diff -gt $((MQTT_CACHE_TIMEOUT * 2)) ]]; then
            echo "🧹 清理过期的MQTT缓存..."
            rm -f "$MQTT_CACHE_FILE"
        fi
    fi
}

# 测试单个服务状态检查（调试用）
test_single_service() {
    local service_id="$1"
    
    if [[ -z "$service_id" ]]; then
        echo "用法: test_single_service <service_id>"
        echo "示例: test_single_service hass"
        return 1
    fi
    
    echo "🧪 测试单个服务状态检查: $service_id"
    echo "════════════════════════════════════════════════"
    
    load_mqtt_conf
    echo "MQTT配置: $MQTT_HOST:$MQTT_PORT ($MQTT_USER)"
    echo ""
    
    # 按新的优先级顺序测试各个检查方法
    echo "1️⃣ 测试 status.sh --json 检查:"
    local service_dir="$BASE_DIR/$service_id"
    if [[ -f "$service_dir/status.sh" ]]; then
        echo "   执行: bash $service_dir/status.sh --json"
        local status_output=$(bash "$service_dir/status.sh" --json 2>&1)
        echo "   原始输出: $status_output"
        
        if command -v jq >/dev/null 2>&1; then
            local install_field=$(echo "$status_output" | jq -r '.install // "not_found"' 2>/dev/null || echo "parse_error")
            echo "   install字段: $install_field"
            
            case "$install_field" in
                "true") echo "   映射结果: installed" ;;
                "false") echo "   映射结果: uninstalled" ;;
                *) echo "   映射结果: unknown" ;;
            esac
        else
            echo "   警告: jq未安装，无法解析JSON"
        fi
    else
        echo "   status.sh不存在: $service_dir/status.sh"
    fi
    echo ""
    
    echo "2️⃣ 测试MQTT缓存检查:"
    local cached_result=$(get_mqtt_install_status "$service_id")
    echo "   缓存结果: $cached_result"
    echo ""
    
    echo "3️⃣ 测试MQTT实时检查:"
    local mqtt_result=$(fetch_mqtt_install_status "$service_id")
    echo "   实时结果: $mqtt_result"
    echo ""
    
    echo "4️⃣ 测试文件系统检查:"
    if [[ -d "$service_dir" ]]; then
        local key_scripts=("install.sh" "start.sh" "stop.sh" "status.sh")
        local found_scripts=()
        local script_count=0
        
        for script in "${key_scripts[@]}"; do
            if [[ -f "$service_dir/$script" ]]; then
                ((script_count++))
                found_scripts+=("$script")
            fi
        done
        
        echo "   服务目录: $service_dir (存在)"
        echo "   找到脚本 ($script_count/4): ${found_scripts[*]}"
        
        if [[ $script_count -ge 3 ]]; then
            echo "   文件系统判断: installed"
        else
            echo "   文件系统判断: uninstalled"
        fi
    else
        echo "   服务目录: $service_dir (不存在)"
        echo "   文件系统判断: uninstalled"
    fi
    echo ""
    
    echo "🎯 综合状态检查结果 (新逻辑):"
    local final_result=$(check_service_install_status "$service_id")
    echo "   最终状态: $final_result"
    echo ""
    echo "════════════════════════════════════════════════"
}

# 主执行流程
main() {
    # 如果提供了参数，则进行单服务测试
    if [[ $# -gt 0 ]]; then
        if [[ "$1" == "test" && -n "$2" ]]; then
            test_single_service "$2"
            return
        fi
    fi
    
    echo "🚀 启动 Status Check 增强版全量状态检测"
    echo "版本: 1.2 (优先MQTT安装状态检测)"
    echo ""
    echo "💡 调试提示: 使用 'bash statuscheck.sh test <service_id>' 来测试单个服务"
    echo ""
    
    # 清理过期缓存
    cleanup_mqtt_cache
    
    # 记录开始时间
    START_TIME=$(date +%s)
    
    # 加载配置
    load_mqtt_conf
    echo "✅ 已加载 MQTT 配置: $MQTT_HOST:$MQTT_PORT"
    
    # 加载服务列表
    load_services
    local service_count=$(echo "$SERVICES" | wc -w)
    echo "✅ 发现服务 ($service_count 个): $SERVICES"
    echo ""
    
    # 检查服务状态（分两阶段）
    check_services
    
    echo ""
    echo "🎉 状态检查完成"
    
    # 显示MQTT缓存信息
    if [[ -f "$MQTT_CACHE_FILE" ]]; then
        local cache_services=$(jq -r '.services | keys | length' "$MQTT_CACHE_FILE" 2>/dev/null || echo 0)
        echo "📋 MQTT缓存状态: $cache_services 个服务已缓存"
    fi
}

# 执行主流程
main "$@"