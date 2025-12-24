#!/bin/bash

# GitHub Secrets 生成脚本
# 用于将证书和配置文件转换为 Base64 格式

echo "=== GitHub Secrets 生成工具 ==="
echo ""

# 检查操作系统
if [[ "$OSTYPE" == "darwin"* ]]; then
    BASE64_CMD="base64 -i"
    COPY_CMD="pbcopy"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    BASE64_CMD="base64 -w 0"
    COPY_CMD="xclip -selection clipboard"
elif [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "win32" ]]; then
    echo "Windows 系统检测到"
    echo "请使用 Git Bash 或手动执行 certutil 命令"
    BASE64_CMD="base64"
    COPY_CMD="cat"
else
    BASE64_CMD="base64"
    COPY_CMD="cat"
fi

# 函数：生成 Base64 并复制到剪贴板
generate_secret() {
    local file_path=$1
    local description=$2
    
    if [ ! -f "$file_path" ]; then
        echo "❌ 错误: 文件 $file_path 不存在"
        return 1
    fi
    
    echo ""
    echo "--- $description ---"
    echo "文件: $file_path"
    
    if [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "win32" ]]; then
        # Windows 特殊处理
        certutil -encode "$file_path" temp.b64 > /dev/null 2>&1
        findstr /v /c:"-" temp.b64 > secret.b64
        del temp.b64
        echo "✅ 已生成 secret.b64"
        echo "请手动复制 secret.b64 的内容到 GitHub Secrets"
        cat secret.b64
        del secret.b64
    else
        # macOS/Linux
        local secret=$(cat "$file_path" | $BASE64_CMD)
        echo "$secret" | $COPY_CMD
        echo "✅ 已复制到剪贴板"
        echo ""
        echo "前 50 个字符: ${secret:0:50}..."
    fi
}

# 函数：生成 .env 文件的 Base64
generate_env_secret() {
    local env_file=$1
    
    if [ ! -f "$env_file" ]; then
        echo "❌ 错误: .env 文件不存在"
        echo "请创建 .env 文件，内容格式:"
        echo "QIANWEN_API_KEY=your_api_key"
        echo "GPT4O_API_KEY=your_api_key"
        return 1
    fi
    
    echo ""
    echo "--- 环境变量文件 (.env) ---"
    
    if [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "win32" ]]; then
        certutil -encode "$env_file" temp.b64 > /dev/null 2>&1
        findstr /v /c:"-" temp.b64 > env-secret.b64
        del temp.b64
        echo "✅ 已生成 env-secret.b64"
        echo "请手动复制 env-secret.b64 的内容到 GitHub Secrets (ENV_FILE)"
        cat env-secret.b64
        del env-secret.b64
    else
        local secret=$(cat "$env_file" | $BASE64_CMD)
        echo "$secret" | $COPY_CMD
        echo "✅ 已复制到剪贴板"
        echo "请粘贴到 GitHub Secrets: ENV_FILE"
        echo ""
        echo "文件内容预览:"
        head -n 2 "$env_file" | sed 's/=.*$/=***/'
    fi
}

# 主菜单
while true; do
    echo ""
    echo "请选择要生成的 Secret:"
    echo "1) .env 文件 (ENV_FILE)"
    echo "2) .p12 证书 (BUILD_CERTIFICATE_BASE64)"
    echo "3) .mobileprovision 配置文件 (BUILD_PROVISION_PROFILE_BASE64)"
    echo "4) 生成所有 Secrets"
    echo "5) 退出"
    echo ""
    read -p "请输入选项 (1-5): " choice
    
    case $choice in
        1)
            generate_env_secret ".env"
            ;;
        2)
            read -p "请输入 .p12 证书文件路径: " p12_path
            generate_secret "$p12_path" "iOS 分发证书"
            echo ""
            echo "⚠️  还需要在 GitHub Secrets 中设置:"
            echo "   - P12_PASSWORD: 证书密码"
            echo "   - KEYCHAIN_PASSWORD: 任意密码（用于 CI）"
            ;;
        3)
            read -p "请输入 .mobileprovision 文件路径: " profile_path
            generate_secret "$profile_path" "iOS 配置文件"
            ;;
        4)
            echo ""
            echo "=== 生成所有 Secrets ==="
            generate_env_secret ".env"
            
            read -p "请输入 .p12 证书文件路径: " p12_path
            generate_secret "$p12_path" "iOS 分发证书"
            
            read -p "请输入 .mobileprovision 文件路径: " profile_path
            generate_secret "$profile_path" "iOS 配置文件"
            
            echo ""
            echo "=== 需要手动配置的 Secrets ==="
            echo "请设置以下 Secrets:"
            echo "- P12_PASSWORD: 证书密码"
            echo "- KEYCHAIN_PASSWORD: 任意密码（用于 CI）"
            ;;
        5)
            echo "退出脚本"
            exit 0
            ;;
        *)
            echo "❌ 无效选项"
            ;;
    esac
    
    echo ""
    read -p "按回车继续..."
done
