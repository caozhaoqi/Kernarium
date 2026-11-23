#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# LOCAL TOOL (非上游代码)：一键把本机构建好的 Andarium 装到 iPhone（Wi-Fi 或数据线）。
#
# 用法：
#   tools/local-install.sh               # 构建 + 打包 + 安装（默认第一台已连接设备）
#   tools/local-install.sh --no-build    # 跳过重编，直接用现有 ipa 安装
#   tools/local-install.sh --device UDID # 指定设备
#
# 前置（一次性）：
#   1. Xcode + iOS SDK 已装，且 xcodebuild -checkFirstLaunchStatus 通过
#   2. GuestHost/Config/Signing.local.xcconfig 里写了你的 DEVELOPMENT_TEAM
#   3. iOS 依赖前缀已编好（tools/local-install.sh --deps 可触发）
#   4. 内核产物在 .build/kernel/artifacts/，rootfs 已 staged（.build/andarium-system）
#
# 本地差异（相对上游，见 docs/local-build-notes.md）：
#   - Andarium.entitlements 去掉了个人账号拿不到的两个 capability
#   - bundle id 改为 com.qzq.andarium.local（避免与上游已注册 id 冲突）
set -euo pipefail

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"

BUILD_DIR=".build/kernarium-runtime-ios-device-android-4k"
PROJECT="Andarium/Andarium.xcodeproj"
SCHEME="Andarium"
DERIVED_DIR="$ROOT_DIR/.build/xcode-derived"
IPA_PATH="$ROOT_DIR/Andarium-local.ipa"

# ---------- 参数 ----------
DEVICE=""
NO_BUILD=0
WANT_DEPS=0
while [ "$#" -gt 0 ]; do
	case "$1" in
	--device) DEVICE=$2; shift 2 ;;
	--no-build) NO_BUILD=1; shift ;;
	--deps) WANT_DEPS=1; shift ;;
	-h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) printf '%s\n' "未知参数: $1（--help 看用法）" >&2; exit 1 ;;
	esac
done

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m警告:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m错误:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- 前置检查 ----------
say "检查前置条件"
[ -d "/Applications/Xcode.app" ] || die "没有 Xcode（/Applications/Xcode.app）"
export PATH="$ROOT_DIR/.toolchain/bin:/Applications/Xcode.app/Contents/Developer/usr/bin:$PATH"
xcodebuild -checkFirstLaunchStatus || die "Xcode 未完成首次启动（打开一次 Xcode）"

[ -f GuestHost/Config/Signing.local.xcconfig ] || {
	printf 'DEVELOPMENT_TEAM = \n' >&2
	die "缺 GuestHost/Config/Signing.local.xcconfig（复制 Signing.local.xcconfig.example 后填你的 Team ID）"
}
grep -q "DEVELOPMENT_TEAM = [A-Z0-9]" GuestHost/Config/Signing.local.xcconfig || \
	die "Signing.local.xcconfig 里还没填 DEVELOPMENT_TEAM"

[ -d "$BUILD_DIR" ] || warn "构建目录不存在，脚本会先 configure"
[ -d .build/andarium-system ] || die "系统镜像没 staged：先跑 python3 Andarium/scripts/stage-system-image.py"

# ---------- 可选：编译 iOS 依赖 ----------
if [ "$WANT_DEPS" = 1 ]; then
	say "编译 iOS 网络依赖前缀"
	./dependencies/build-ios-network.sh --platform ios --jobs "$(sysctl -n hw.ncpu)"
	say "编译 iOS GPU 依赖前缀（需要 Metal Toolchain：xcodebuild -downloadComponent MetalToolchain）"
	UML_MESA_PYTHON="$ROOT_DIR/.toolchain/pyenv/bin/python" \
		./dependencies/build-apple-gpu.sh --platform ios --jobs "$(sysctl -n hw.ncpu)"
fi

# ---------- 构建 ----------
if [ "$NO_BUILD" = 0 ]; then
	say "配置运行时构建树"
	[ -f "$BUILD_DIR/CMakeCache.txt" ] || \
		cmake --preset kernarium-ios-device-android \
			-DUML_ANDROID17_KERNEL_ARTIFACT_DIR="$ROOT_DIR/.build/kernel/artifacts/android-6.18-arm64-4k-20261119-6.18.60-ca1"

	say "编译运行时框架"
	cmake --build "$BUILD_DIR" --parallel "$(sysctl -n hw.ncpu)"

	say "打包 XCFrameworks"
	./Kernarium/scripts/package-ios-frameworks.sh --runtimes android

	say "xcodebuild 构建 App（含自动签名）"
	xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
		-destination 'generic/platform=iOS' -configuration Release \
		-derivedDataPath "$DERIVED_DIR" \
		-allowProvisioningUpdates -allowProvisioningDeviceRegistration build
else
	say "跳过构建（--no-build）"
	[ -d "$DERIVED_DIR" ] || die "--no-build 但找不到 $DERIVED_DIR"
fi

APP=$(find "$DERIVED_DIR/Build/Products/Release-iphoneos" -maxdepth 1 -name "Andarium.app" | head -1)
[ -n "$APP" ] || die "没找到 Andarium.app 构建产物"

# 校验签名身份
TEAM=$(grep -m1 "DEVELOPMENT_TEAM = " GuestHost/Config/Signing.local.xcconfig | awk '{print $3}')
ACTUAL_TEAM=$(codesign -dv "$APP" 2>&1 | grep "TeamIdentifier=" | head -1 | cut -d= -f2)
[ "$ACTUAL_TEAM" = "$TEAM" ] || \
	die "签名身份不匹配: 期望 Team ${TEAM}, 实际 TeamIdentifier=${ACTUAL_TEAM}"

# ---------- 打 ipa ----------
say "打包 ipa"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
# ipa 必须是 Payload/Andarium.app 顶层结构，zip 从 $STAGE 打保证路径正确
( cd "$STAGE" && zip -qr "$IPA_PATH" Payload )
say "ipa: ${IPA_PATH} ($(du -h "$IPA_PATH" | cut -f1))"

# ---------- 选设备 ----------
if [ -z "$DEVICE" ]; then
	say "选择设备"
	# 设备名可能含空格/中文，用 python 按两个以上空格切分最稳
	DEVICES=$(xcrun devicectl list devices 2>/dev/null | python3 -c '
import sys, re
rows = []
for line in sys.stdin:
    cols = re.split(r"  +", line.strip())
    if len(cols) >= 4 and "(UDID)" in cols[1] and "----" not in cols[0]:
        rows.append((cols[1].replace(" (UDID)", ""), cols[0], cols[2]))
# connected 优先
rows.sort(key=lambda r: 0 if r[2] == "connected" else 1)
for r in rows: print("|".join(r))
')
	[ -n "$DEVICES" ] || die "没有已配对的设备（先用 Xcode 或数据线连接一次）"
	DEVICE=$(printf '%s\n' "$DEVICES" | head -1 | cut -d'|' -f1)
	NAME=$(printf '%s\n' "$DEVICES" | head -1 | cut -d'|' -f2)
	STATE=$(printf '%s\n' "$DEVICES" | head -1 | cut -d'|' -f3)
	[ "$STATE" = "connected" ] || die "设备 ${NAME} 不在线 (状态: ${STATE})。连接 Wi-Fi 或插数据线后重试"
	say "目标设备: ${NAME} (${DEVICE})"
else
	say "目标设备: ${DEVICE} (手动指定)"
fi

# ---------- 安装 ----------
say "安装到设备"
if xcrun devicectl device install app --device "$DEVICE" "$IPA_PATH"; then
	say "安装成功。首次启动前：设置 → 通用 → VPN与设备管理 → 信任你的开发者证书"
else
	warn "安装失败，常见原因："
	warn "  0xe8008012: profile 不含此设备 → 加 -allowProvisioningDeviceRegistration 重新构建（本脚本已带）"
	warn "             或用数据线插一次让 Xcode 注册设备"
	warn "  0xe8008015: 证书过期 → 免费账号 7 天有效，重跑本脚本即可"
	exit 1
fi
