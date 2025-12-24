@echo off
REM GitHub Secrets 生成工具 - Windows 版本

echo === GitHub Secrets 生成工具 (Windows) ===
echo.

:menu
echo 请选择要生成的 Secret:
echo 1) .env 文件 (ENV_FILE)
echo 2) .p12 证书 (BUILD_CERTIFICATE_BASE64)
echo 3) .mobileprovision 配置文件 (BUILD_PROVISION_PROFILE_BASE64)
echo 4) 生成所有 Secrets
echo 5) 退出
echo.
set /p choice="请输入选项 (1-5): "

if "%choice%"=="1" goto generate_env
if "%choice%"=="2" goto generate_p12
if "%choice%"=="3" goto generate_profile
if "%choice%"=="4" goto generate_all
if "%choice%"=="5" goto end

echo ❌ 无效选项
echo.
pause
goto menu

:generate_env
echo.
echo --- 环境变量文件 (.env) ---
if not exist ".env" (
    echo ❌ 错误: .env 文件不存在
    echo 请创建 .env 文件，内容格式:
    echo QIANWEN_API_KEY=your_api_key
    echo GPT4O_API_KEY=your_api_key
    pause
    goto menu
)

echo 正在生成 ENV_FILE secret...
certutil -encode .env temp.b64 >nul
findstr /v /c:"-" temp.b64 > env-secret.txt
del temp.b64

echo.
echo ✅ 已生成 env-secret.txt
echo 请复制以下内容到 GitHub Secrets (ENV_FILE):
echo.
type env-secret.txt
echo.
del env-secret.txt
pause
goto menu

:generate_p12
echo.
echo --- iOS 分发证书 (.p12) ---
set /p p12_path="请输入 .p12 证书文件路径: "

if not exist "%p12_path%" (
    echo ❌ 错误: 文件不存在
    pause
    goto menu
)

echo 正在生成 BUILD_CERTIFICATE_BASE64 secret...
certutil -encode "%p12_path%" temp.b64 >nul
findstr /v /c:"-" temp.b64 > p12-secret.txt
del temp.b64

echo.
echo ✅ 已生成 p12-secret.txt
echo 请复制以下内容到 GitHub Secrets (BUILD_CERTIFICATE_BASE64):
echo.
type p12-secret.txt
echo.
del p12-secret.txt

echo.
echo ⚠️  还需要在 GitHub Secrets 中设置:
echo    - P12_PASSWORD: 证书密码
echo    - KEYCHAIN_PASSWORD: 任意密码（用于 CI）
pause
goto menu

:generate_profile
echo.
echo --- iOS 配置文件 (.mobileprovision) ---
set /p profile_path="请输入 .mobileprovision 文件路径: "

if not exist "%profile_path%" (
    echo ❌ 错误: 文件不存在
    pause
    goto menu
)

echo 正在生成 BUILD_PROVISION_PROFILE_BASE64 secret...
certutil -encode "%profile_path%" temp.b64 >nul
findstr /v /c:"-" temp.b64 > profile-secret.txt
del temp.b64

echo.
echo ✅ 已生成 profile-secret.txt
echo 请复制以下内容到 GitHub Secrets (BUILD_PROVISION_PROFILE_BASE64):
echo.
type profile-secret.txt
echo.
del profile-secret.txt
pause
goto menu

:generate_all
echo.
echo === 生成所有 Secrets ===

if not exist ".env" (
    echo ❌ 错误: .env 文件不存在
    pause
    goto menu
)

echo.
echo 1. 生成 ENV_FILE secret...
certutil -encode .env temp.b64 >nul
findstr /v /c:"-" temp.b64 > env-secret.txt
del temp.b64
echo 请复制 env-secret.txt 内容到 GitHub Secrets (ENV_FILE)
type env-secret.txt
del env-secret.txt

echo.
set /p p12_path="2. 请输入 .p12 证书文件路径: "
if exist "%p12_path%" (
    certutil -encode "%p12_path%" temp.b64 >nul
    findstr /v /c:"-" temp.b64 > p12-secret.txt
del temp.b64
    echo 请复制 p12-secret.txt 内容到 GitHub Secrets (BUILD_CERTIFICATE_BASE64)
    type p12-secret.txt
    del p12-secret.txt
) else (
    echo ❌ 证书文件不存在，跳过
)

echo.
set /p profile_path="3. 请输入 .mobileprovision 文件路径: "
if exist "%profile_path%" (
    certutil -encode "%profile_path%" temp.b64 >nul
    findstr /v /c:"-" temp.b64 > profile-secret.txt
del temp.b64
    echo 请复制 profile-secret.txt 内容到 GitHub Secrets (BUILD_PROVISION_PROFILE_BASE64)
    type profile-secret.txt
    del p12-secret.txt
) else (
    echo ❌ 配置文件不存在，跳过
)

echo.
echo === 需要手动配置的 Secrets ===
echo 请设置以下 Secrets:
if not exist "%p12_path%" (
    echo - BUILD_CERTIFICATE_BASE64: .p12 证书的 Base64
    echo - P12_PASSWORD: 证书密码
    echo - KEYCHAIN_PASSWORD: 任意密码（用于 CI）
)
if not exist "%profile_path%" (
    echo - BUILD_PROVISION_PROFILE_BASE64: .mobileprovision 的 Base64
)
)
pause
goto menu

:end
echo.
echo 退出脚本
exit /b 0
