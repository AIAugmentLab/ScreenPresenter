#!/bin/bash

# ============================================================================
# ScreenPresenter DMG 打包脚本
# ============================================================================
# 用法: ./build_dmg.sh [选项]
#
# 选项:
#   --skip-build    跳过构建步骤，直接使用已有的 .app 文件
#   --clean         清理所有构建产物
#   --help          显示帮助信息
#
# 示例:
#   ./build_dmg.sh              # 完整构建并生成 DMG
#   ./build_dmg.sh --skip-build # 使用已有的 .app 生成 DMG
#   ./build_dmg.sh --clean      # 清理构建产物
# ============================================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 项目配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
PROJECT_NAME="ScreenPresenter"
SCHEME_NAME="ScreenPresenter"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/$PROJECT_NAME.xcarchive"
EXPORT_PATH="$BUILD_DIR/Export"
APP_NAME="$PROJECT_NAME.app"
DMG_DIR="$BUILD_DIR/DMG"
DMG_NAME="$PROJECT_NAME"

# 从 Info.plist 获取版本号
# 优先从构建产物中读取，确保版本号与 Xcode 项目设置一致
get_version() {
    # 优先从构建产物获取版本号
    local built_plist="$EXPORT_PATH/$APP_NAME/Contents/Info.plist"
    if [ -f "$built_plist" ]; then
        /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$built_plist" 2>/dev/null && return
    fi
    
    # 备选：从源代码 Info.plist 获取
    local plist="$PROJECT_DIR/$PROJECT_NAME/Info.plist"
    if [ -f "$plist" ]; then
        /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist" 2>/dev/null || echo "1.0.0"
    else
        echo "1.0.0"
    fi
}

# 辅助函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 显示帮助信息
show_help() {
    echo "============================================================================"
    echo "ScreenPresenter DMG 打包脚本"
    echo "============================================================================"
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  --skip-build    跳过构建步骤，直接使用已有的 .app 文件"
    echo "  --clean         清理所有构建产物"
    echo "  --help          显示帮助信息"
    echo ""
    echo "示例:"
    echo "  $0              # 完整构建并生成 DMG"
    echo "  $0 --skip-build # 使用已有的 .app 生成 DMG"
    echo "  $0 --clean      # 清理构建产物"
    echo ""
}

# 清理构建产物
clean_build() {
    log_info "清理构建产物..."
    rm -rf "$BUILD_DIR"
    rm -rf "$PROJECT_DIR/DerivedData"
    log_success "清理完成"
}

# 构建应用
build_app() {
    log_info "开始构建 $PROJECT_NAME (Release)..."
    
    # 创建构建目录
    mkdir -p "$BUILD_DIR"
    
    # 构建命令
    BUILD_CMD="xcodebuild clean build \
        -project \"$PROJECT_DIR/$PROJECT_NAME.xcodeproj\" \
        -scheme \"$SCHEME_NAME\" \
        -configuration Release \
        -derivedDataPath \"$BUILD_DIR/DerivedData\" \
        CODE_SIGN_IDENTITY=\"-\" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO \
        ONLY_ACTIVE_ARCH=NO"
    
    # 检查 xcpretty 是否可用，如果可用则使用它美化输出
    if command -v xcpretty &> /dev/null; then
        eval "$BUILD_CMD" | xcpretty --color
    else
        log_info "提示: 安装 xcpretty (gem install xcpretty) 可获得更简洁的构建输出"
        eval "$BUILD_CMD"
    fi
    
    # 查找构建产物
    APP_PATH=$(find "$BUILD_DIR/DerivedData" -name "$APP_NAME" -type d | head -1)
    
    if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
        log_error "构建失败：找不到 $APP_NAME"
        exit 1
    fi
    
    # 复制到导出目录
    mkdir -p "$EXPORT_PATH"
    rm -rf "$EXPORT_PATH/$APP_NAME"
    cp -R "$APP_PATH" "$EXPORT_PATH/"
    
    log_success "构建完成: $EXPORT_PATH/$APP_NAME"
}

# 创建 DMG
create_dmg() {
    log_info "创建 DMG 安装包..."
    
    APP_PATH="$EXPORT_PATH/$APP_NAME"
    
    if [ ! -d "$APP_PATH" ]; then
        log_error "找不到应用: $APP_PATH"
        log_info "请先运行不带 --skip-build 参数的脚本进行构建"
        exit 1
    fi
    
    # 从构建产物获取版本号
    VERSION=$(get_version)
    DMG_FINAL_NAME="${PROJECT_NAME}_${VERSION}.dmg"
    log_info "检测到版本号: $VERSION"
    
    # 清理旧的 DMG 目录
    rm -rf "$DMG_DIR"
    mkdir -p "$DMG_DIR"
    
    # 复制应用到 DMG 目录
    cp -R "$APP_PATH" "$DMG_DIR/"
    
    # 创建 Applications 文件夹的符号链接
    ln -s /Applications "$DMG_DIR/Applications"
    
    # 创建 DMG 背景图目录 (可选)
    # mkdir -p "$DMG_DIR/.background"
    
    # 计算 DMG 大小 (应用大小 + 额外空间)
    APP_SIZE=$(du -sm "$DMG_DIR" | cut -f1)
    DMG_SIZE=$((APP_SIZE + 20))  # 额外 20MB 空间
    
    # 临时 DMG 路径
    TEMP_DMG="$BUILD_DIR/temp_$DMG_NAME.dmg"
    FINAL_DMG="$BUILD_DIR/$DMG_FINAL_NAME"
    
    # 删除旧的 DMG 文件
    rm -f "$TEMP_DMG"
    rm -f "$FINAL_DMG"
    
    log_info "创建临时 DMG (大小: ${DMG_SIZE}MB)..."
    
    # 创建临时 DMG
    hdiutil create \
        -srcfolder "$DMG_DIR" \
        -volname "$DMG_NAME" \
        -fs HFS+ \
        -fsargs "-c c=64,a=16,e=16" \
        -format UDRW \
        -size ${DMG_SIZE}m \
        "$TEMP_DMG"
    
    # 挂载临时 DMG
    log_info "挂载并配置 DMG..."
    MOUNT_DIR=$(hdiutil attach -readwrite -noverify -noautoopen "$TEMP_DMG" | grep "/Volumes/" | sed 's/.*\/Volumes/\/Volumes/')
    
    if [ -z "$MOUNT_DIR" ]; then
        log_error "挂载 DMG 失败"
        exit 1
    fi
    
    log_info "DMG 挂载于: $MOUNT_DIR"
    
    # 设置 DMG 窗口属性 (使用 AppleScript)
    log_info "配置 DMG 窗口样式..."
    
    # 等待 Finder 识别卷
    sleep 2
    
    # 使用 AppleScript 设置 DMG 窗口属性
    osascript <<EOF
    tell application "Finder"
        tell disk "$DMG_NAME"
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set the bounds of container window to {400, 100, 900, 450}
            set viewOptions to the icon view options of container window
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to 80
            
            -- 设置图标位置
            set position of item "$APP_NAME" of container window to {130, 180}
            set position of item "Applications" of container window to {370, 180}
            
            close
            open
            update without registering applications
            delay 2
        end tell
    end tell
EOF
    
    # 同步并等待
    sync
    sleep 3
    
    # 卸载 DMG
    log_info "卸载临时 DMG..."
    hdiutil detach "$MOUNT_DIR" -force || {
        sleep 5
        hdiutil detach "$MOUNT_DIR" -force
    }
    
    # 压缩 DMG
    log_info "压缩最终 DMG..."
    hdiutil convert "$TEMP_DMG" \
        -format UDZO \
        -imagekey zlib-level=9 \
        -o "$FINAL_DMG"
    
    # 清理临时文件
    rm -f "$TEMP_DMG"
    rm -rf "$DMG_DIR"
    
    # 显示结果
    DMG_SIZE_FINAL=$(du -h "$FINAL_DMG" | cut -f1)
    
    log_success "============================================"
    log_success "DMG 创建成功!"
    log_success "============================================"
    log_success "文件: $FINAL_DMG"
    log_success "大小: $DMG_SIZE_FINAL"
    log_success "============================================"
    
    # 打开 Finder 显示 DMG 文件
    open -R "$FINAL_DMG"
}

# 主函数
main() {
    echo ""
    echo "============================================"
    echo "  $PROJECT_NAME DMG 打包工具"
    echo "============================================"
    echo ""
    
    SKIP_BUILD=false
    
    # 解析参数
    for arg in "$@"; do
        case $arg in
            --skip-build)
                SKIP_BUILD=true
                ;;
            --clean)
                clean_build
                exit 0
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                log_warning "未知参数: $arg"
                show_help
                exit 1
                ;;
        esac
    done
    
    # 检查 Xcode 命令行工具
    if ! command -v xcodebuild &> /dev/null; then
        log_error "xcodebuild 未找到，请安装 Xcode 命令行工具"
        exit 1
    fi
    
    # 执行构建流程
    if [ "$SKIP_BUILD" = false ]; then
        build_app
    else
        log_info "跳过构建步骤..."
    fi
    
    create_dmg
}

# 运行主函数
main "$@"

