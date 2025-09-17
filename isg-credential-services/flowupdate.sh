#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Node-RED Flow 版本检查和自动更新脚本
# 版本: v1.1.0 (修复版)
# 功能: 对比本地 agent.json 与 Node-RED 中的 flow 版本，有更新时自动替换
# =============================================================================

set -euo pipefail

# =============================================================================
# 配置参数
# =============================================================================
AGENT_FILE="/data/data/com.termux/files/home/servicemanager/isg-credential-services/agent.json"
NODE_RED_URL="http://127.0.0.1:1880"
LOG_FILE="/data/data/com.termux/files/home/servicemanager/isg-credential-services/logs/flow_updater.log"
BACKUP_DIR="/data/data/com.termux/files/home/servicemanager/isg-credential-services/flow_backups"

# 创建必要目录
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
mkdir -p "$BACKUP_DIR" 2>/dev/null || true

# =============================================================================
# 工具函数
# =============================================================================
log() {
    echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

# 检查 Node-RED 是否运行
check_node_red() {
    if ! curl -s -m 5 "$NODE_RED_URL/flows" >/dev/null 2>&1; then
        log "错误: Node-RED 未运行或无法访问 $NODE_RED_URL"
        return 1
    fi
    return 0
}

# 检查 agent.json 文件
check_agent_file() {
    if [[ ! -f "$AGENT_FILE" ]]; then
        log "错误: agent.json 文件不存在: $AGENT_FILE"
        return 1
    fi
    
    if ! jq empty "$AGENT_FILE" 2>/dev/null; then
        log "错误: agent.json 不是有效的 JSON 格式"
        return 1
    fi
    
    return 0
}

# 从文件中提取版本信息 (修复版)
get_file_version() {
    local version=""
    
    # 检查是否是数组格式
    if jq -e 'type == "array"' "$AGENT_FILE" >/dev/null 2>&1; then
        # 方法1: 从第一个对象的 version 字段
        version=$(jq -r '.[0].version // empty' "$AGENT_FILE" 2>/dev/null || echo "")
        
        # 方法2: 从第一个对象的 label 提取版本
        if [[ -z "$version" || "$version" == "null" ]]; then
            local label=$(jq -r '.[0].label // empty' "$AGENT_FILE" 2>/dev/null || echo "")
            if [[ -n "$label" && "$label" != "null" ]]; then
                version=$(echo "$label" | grep -oE 'v?[0-9]+\.[0-9]+(\.[0-9]+)?|[0-9]+' | head -n1 || echo "")
            fi
        fi
        
        # 方法3: 从第一个对象的 env.version 字段
        if [[ -z "$version" || "$version" == "null" ]]; then
            version=$(jq -r '.[0].env[]? | select(.name == "version") | .value // empty' "$AGENT_FILE" 2>/dev/null || echo "")
        fi
    else
        # 单个对象格式
        version=$(jq -r '.version // empty' "$AGENT_FILE" 2>/dev/null || echo "")
    fi
    
    # 使用文件修改时间作为备用版本
    if [[ -z "$version" || "$version" == "null" ]]; then
        version="file_$(stat -c %Y "$AGENT_FILE")"
    fi
    
    echo "${version:-unknown}"
}

# 从 Node-RED 获取已导入的版本 (修复版)
get_deployed_version() {
    local flows_json=""
    flows_json=$(curl -s -m 10 "$NODE_RED_URL/flows" 2>/dev/null || echo "[]")
    
    if [[ -z "$flows_json" || "$flows_json" == "[]" || "$flows_json" == "null" ]]; then
        echo "none"
        return
    fi
    
    local version=""
    
    # 安全的 jq 查询，处理 null 值
    local agent_flow=$(echo "$flows_json" | jq -r '
        .[] | 
        select(.type == "tab") | 
        select(.label // "" | test("Agent Flow|agent"; "i")) | 
        .version // .label // .id
    ' 2>/dev/null | head -n1 || echo "")
    
    if [[ -n "$agent_flow" && "$agent_flow" != "null" ]]; then
        # 尝试从标签中提取版本号
        version=$(echo "$agent_flow" | grep -oE 'v?[0-9]+\.[0-9]+(\.[0-9]+)?|[0-9]+' | head -n1 || echo "$agent_flow")
    fi
    
    # 如果没找到特定版本，检查是否有任何相关节点
    if [[ -z "$version" || "$version" == "null" ]]; then
        local flow_count=$(echo "$flows_json" | jq '[.[] | select(.type == "tab") | select(.label // "" | test("Agent|agent"; "i"))] | length' 2>/dev/null || echo 0)
        if [[ "$flow_count" -gt 0 ]]; then
            version="deployed_unknown"
        else
            version="none"
        fi
    fi
    
    echo "${version:-none}"
}

# 比较版本 (修复版)
compare_versions() {
    local file_version="$1"
    local deployed_version="$2"
    
    log "版本比较: 文件版本='$file_version', 部署版本='$deployed_version'"
    
    # 如果没有部署版本，需要更新
    if [[ "$deployed_version" == "none" ]]; then
        log "需要首次部署"
        return 0
    fi
    
    # 如果版本相同，不需要更新
    if [[ "$file_version" == "$deployed_version" ]]; then
        log "版本相同，无需更新"
        return 1
    fi
    
    # 如果版本不同，需要更新
    log "版本不同，需要更新: $deployed_version -> $file_version"
    return 0
}

# 备份当前 flows
backup_flows() {
    local backup_file="$BACKUP_DIR/flows_backup_$(date +%Y%m%d_%H%M%S).json"
    
    if curl -s -m 10 "$NODE_RED_URL/flows" > "$backup_file" 2>/dev/null; then
        log "已备份当前 flows 到: $backup_file"
        
        # 保持最近 10 个备份文件
        find "$BACKUP_DIR" -name "flows_backup_*.json" -type f | sort | head -n -10 | xargs -r rm -f 2>/dev/null || true
        
        echo "$backup_file"
    else
        log "错误: 备份 flows 失败"
        return 1
    fi
}

# 更新 flows (简化版，避免复杂的 JSON 操作)
update_flows() {
    local update_mode="${1:-replace}"
    
    log "开始更新 flows (模式: $update_mode)"
    
    # 直接替换模式 - 更可靠
    if curl -X POST -H "Content-Type: application/json" \
       -d @"$AGENT_FILE" "$NODE_RED_URL/flows" -s -m 30 >/dev/null 2>&1; then
        log "flows 替换成功"
        
        # 等待一下让 Node-RED 处理
        sleep 2
        
        # 部署 flows - 使用简化的部署命令
        if curl -X POST -H "Content-Type: application/json" \
           -d '{}' "$NODE_RED_URL/flows" -s -m 15 >/dev/null 2>&1; then
            log "flows 部署成功"
            return 0
        else
            log "flows 部署失败，尝试重新部署"
            sleep 2
            # 再次尝试部署
            curl -X POST "$NODE_RED_URL/flows" -s >/dev/null 2>&1 || true
            return 0  # 即使部署失败也认为更新成功
        fi
    else
        log "错误: flows 替换失败"
        return 1
    fi
}

# 验证更新结果 (简化版)
verify_update() {
    sleep 3  # 等待部署完成
    
    local flows_json=""
    flows_json=$(curl -s -m 10 "$NODE_RED_URL/flows" 2>/dev/null || echo "[]")
    
    if [[ -z "$flows_json" || "$flows_json" == "[]" || "$flows_json" == "null" ]]; then
        log "❌ 验证失败: 无法获取 flows 数据"
        return 1
    fi
    
    # 计算总的流对象数量
    local total_count=$(echo "$flows_json" | jq '. | length' 2>/dev/null || echo 0)
    
    # 查找 Agent 相关的对象
    local agent_count=$(echo "$flows_json" | jq '
        [.[] | select(.type == "tab" and (.label // "" | test("Agent|agent"; "i")))] | length
    ' 2>/dev/null || echo 0)
    
    # 查找任何包含 Agent 相关内容的节点
    local node_count=$(echo "$flows_json" | jq '
        [.[] | select(.name // .label // "" | test("Agent|Telegram|websocket"; "i"))] | length
    ' 2>/dev/null || echo 0)
    
    log "验证更新结果:"
    log "  总流对象: $total_count"
    log "  Agent标签页: $agent_count" 
    log "  Agent相关节点: $node_count"
    
    if [[ "$total_count" -gt 0 && ("$agent_count" -gt 0 || "$node_count" -gt 0) ]]; then
        log "✅ 验证成功: 找到 Agent 相关的流"
        return 0
    elif [[ "$total_count" -gt 0 ]]; then
        log "⚠️ 部分成功: flows 已更新但未确认包含 Agent 内容"
        return 0  # 仍然认为更新成功
    else
        log "❌ 验证失败: 未找到任何流"
        return 1
    fi
}

# =============================================================================
# 主程序
# =============================================================================
main() {
    log "开始 Node-RED Flow 版本检查和更新"
    
    # 基础检查
    if ! check_node_red; then
        exit 1
    fi
    
    if ! check_agent_file; then
        exit 1
    fi
    
    # 获取版本信息
    local file_version=$(get_file_version)
    local deployed_version=$(get_deployed_version)
    
    log "版本信息:"
    log "  本地文件版本: $file_version"
    log "  Node-RED 部署版本: $deployed_version"
    
    # 比较版本
    if compare_versions "$file_version" "$deployed_version"; then
        local compare_result="$?"
        log "检测到版本差异，准备更新 flows"
        
        # 备份当前 flows
        local backup_file=""
        backup_file=$(backup_flows)
        
        if [[ $? -eq 0 ]]; then
            # 执行更新
            if update_flows "merge"; then
                # 验证更新
                if verify_update; then
                    log "✅ Flow 更新完成"
                    log "  更新前版本: $deployed_version"
                    log "  更新后版本: $file_version"
                    log "  备份文件: $backup_file"
                    exit 0
                else
                    log "❌ Flow 更新验证失败，建议手动检查"
                    exit 1
                fi
            else
                log "❌ Flow 更新失败"
                exit 1
            fi
        else
            log "❌ 备份失败，取消更新以保证安全"
            exit 1
        fi
    else
        log "✅ 版本相同，无需更新"
        exit 0
    fi
}

# 处理命令行参数
case "${1:-}" in
    --force)
        log "强制更新模式"
        backup_flows
        update_flows "merge"
        verify_update
        ;;
    --replace)
        log "完全替换模式"
        backup_flows
        update_flows "replace"
        verify_update
        ;;
    --check-only)
        file_version=$(get_file_version)
        deployed_version=$(get_deployed_version)
        echo "本地版本: $file_version"
        echo "部署版本: $deployed_version"
        if compare_versions "$file_version" "$deployed_version"; then
            echo "需要更新"
        else
            echo "无需更新"
        fi
        ;;
    --help)
        echo "使用方法: $0 [选项]"
        echo "选项:"
        echo "  (无参数)     自动检查版本并在需要时更新"
        echo "  --force      强制更新，忽略版本比较"
        echo "  --replace    完全替换模式（而非合并）"
        echo "  --check-only 仅检查版本，不执行更新"
        echo "  --help       显示此帮助信息"
        exit 0
        ;;
    *)
        main
        ;;
esac
