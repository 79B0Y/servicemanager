#!/data/data/com.termux/files/usr/bin/bash

set -e

echo "🔧 开始配置 pnpm 全局路径..."

# 定义目标路径
TARGET_DIR="$HOME/.pnpm-global/global/5"
TARGET_BIN="$TARGET_DIR/bin"

# Step 1: 修改 ~/.bashrc
echo "📄 修改 ~/.bashrc..."

# 删除旧的 PNPM_HOME 定义
sed -i '/^export PNPM_HOME=.*$/d' ~/.bashrc
sed -i '/^case ":.*\$PNPM_HOME.*":/,+2d' ~/.bashrc

# 追加新的配置
cat <<EOF >> ~/.bashrc

# >>> PNPM global path fix >>>
export PNPM_HOME="$HOME/.pnpm-global/global/5"
export PATH="\$PNPM_HOME/bin:\$PATH"
# <<< PNPM global path fix <<<
EOF

# Step 2: 设置 pnpm 配置
echo "⚙️ 设置 pnpm config..."
pnpm config set global-dir "$TARGET_DIR"
pnpm config set global-bin-dir "$TARGET_BIN"

# Step 3: 应用环境变量
echo "🔁 应用环境变量..."
source ~/.bashrc

# Step 4: 测试安装一个小模块
echo "🧪 安装测试模块 is-positive..."
pnpm add -g is-positive

# Step 5: 验证模块安装路径
echo "🔍 验证安装路径..."
MODULE_PATH="$TARGET_DIR/node_modules/is-positive"
if [ -d "$MODULE_PATH" ]; then
    echo "✅ 模块安装成功在: $MODULE_PATH"
else
    echo "❌ 模块未安装在预期路径: $MODULE_PATH"
    exit 1
fi

# Step 6: 打印最终配置
echo "📦 当前 pnpm 配置："
echo "Global Dir: $(pnpm config get global-dir)"
echo "Global Bin: $(pnpm config get global-bin-dir)"

# 完成
echo "🎉 pnpm 路径修复完成！"

