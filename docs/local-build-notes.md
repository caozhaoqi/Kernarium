# 在 Apple Silicon Mac 上从源码构建 Andarium 并无线安装到 iPhone

> 本文档是**本地构建经验总结**（2026-11-23），记录把 Kernarium/Andarium 从零
> 编译出 ipa 并无线装到真机的完整路径。所有改动都是本地补丁，不影响上游。
>
> 环境：macOS 27.3 arm64，Xcode 27.2，iPhone 16 Pro Max（iOS 27），个人免费
> Apple Developer 账号。

## 总览

Andarium 是"iOS 上跑 Android"的 App（Linux 内核 UML + 线程化解释器/JIT）。
从源码到手机要五层东西：

```
Xcode + iOS SDK + Metal Toolchain
  └─ iOS 依赖前缀（network + GPU）
       └─ 运行时框架 KRuntime_Android_6_18_4K
            └─ Andarium.app（内嵌 rootfs 系统镜像）
                 └─ 无线安装（devicectl）
```

## 一、工具链（一次性）

| 组件 | 获取方式 | 坑 |
|---|---|---|
| Xcode 27.2 | App Store | 装完要打开一次接受许可 |
| Metal Toolchain | `xcodebuild -downloadComponent MetalToolchain` | **Xcode 27 拆出来的独立组件**，839MB。不装的话 Mesa 的 `libkk_metallib.c` 编译报 `cannot execute tool 'metal'` |
| cmake ≥3.27 | 本仓 `.toolchain/`（PyPI wheel 3.31.10）或 brew | brew 装 cmake 4.x 也可以，但仓库审计脚本只在 4.x 下默认 NEW policy |
| meson/ninja | brew | glib/Mesa 需要 meson |
| python venv | `.toolchain/pyenv`（mako + packaging + pyyaml） | KosmicKrisp/Mesa 的 python 脚本用 `UML_MESA_PYTHON` 指进去 |

## 二、iOS 依赖前缀

```sh
export UML_MESA_PYTHON="$PWD/.toolchain/pyenv/bin/python"
./dependencies/prepare.sh --product ios-network          # 拉源码
./dependencies/prepare.sh --product ios-storage
./dependencies/prepare.sh --product ios-compression
./dependencies/prepare.sh --product apple-gpu-vulkan-experiment
./dependencies/build-ios-network.sh --platform ios --jobs 8
./dependencies/build-apple-gpu.sh --platform ios --jobs 8
```

产出的前缀路径正是 `kernarium-ios-device` preset 写死的两个变量：

- `.build/dependencies/ios-device-arm64/network`
- `.build/dependencies/apple-gpu-vulkan-experiment/ios-device-arm64`

**坑 1：仓库不能放在 `/tmp` 下**。`/tmp` 是 `/private/tmp` 的符号链接，
而依赖构建镜像按字面路径摆放产物——CMake 系装到 `…/tmp/…`，autotools 系装
到 `…/private/tmp/…`，pkg-config 永远找不到对方的 `.pc`。仓库必须放在
**无符号链接的真实路径**（如 `~/PycharmProjects/Kernarium`）。

**坑 2：仓库搬过家，前缀里 17 个文本文件烤死了旧绝对路径**。搬完用
`grep -rl 旧路径 .build/dependencies/macos-arm64-27 | xargs sed -i '' 's|旧|新|g'`
改写即可，不用重编。

## 三、内核产物 + rootfs

Apple 产品**不读内核源码**，只吃已接受的预构建产物。上游 release 里正好有：

```sh
# 下载（GitHub 直连极慢 ~12KB/s；走镜像快 75 倍）
base="https://ghfast.top/https://github.com/imxieyi/Kernarium/releases/download/andarium-1.1"
curl -LO "$base/android-6.18-arm64-4k-20261119-6.18.60-ca1.tar.gz"    # 内核 10.8MB
curl -LO "$base/lineage24-mainline6.18-4k-20261121-los24-r29.tar.gz" # rootfs 1.0GB
# 校验（release API 给了每个 asset 的 sha256）
shasum -a 256 *.tar.gz

mkdir -p .build/kernel/artifacts .build/android/releases
tar -xzf android-6.18-*.tar.gz -C .build/kernel/artifacts
tar -xzf lineage24-*.tar.gz    -C .build/android/releases
```

staging（把 rootfs 打成 App 内嵌的系统镜像，含 Magisk root 文件）：

```sh
python3 Andarium/scripts/stage-system-image.py
# → .build/andarium-system
```

## 四、编译与打包（一键脚本）

```sh
tools/local-install.sh          # 全流程：构建 → ipa → 无线安装
tools/local-install.sh --no-build   # 只重装现有 ipa
tools/local-install.sh --deps       # 顺带重编 iOS 依赖前缀
tools/local-install.sh --device UDID
```

首次跑之前要写一次签名配置（gitignored，不会推上去）：

```sh
cp GuestHost/Config/Signing.local.xcconfig.example GuestHost/Config/Signing.local.xcconfig
# 编辑里面的 DEVELOPMENT_TEAM = 你的10位TeamID
```

## 五、个人免费账号的三道墙（都绕过去了）

| 墙 | 报错 | 绕法 | 代价 |
|---|---|---|---|
| Extended Virtual Addressing | `Personal development teams ... do not support the Extended Virtual Addressing capability` | 本地去掉 `Andarium.entitlements` 里那两个 key | Android 可用内存变小，重 App 可能被杀 |
| Bundle ID 已被注册 | `The app identifier "com.imxieyi.andarium" cannot be registered to your development team` | 改成 `com.qzq.andarium.local` | App 名字/图标不变，仅 id 变 |
| Profile 不含设备 UDID | `0xe8008012 This provisioning profile cannot be installed on this device` | 用 `-destination 'platform=iOS,id=UDID'` 或 `-allowProvisioningDeviceRegistration` 重新构建 | 无 |

免费账号的长期限制（README 也写了）：**证书 7 天过期**，过期重跑
`tools/local-install.sh` 即可（几分钟）；扩展虚拟地址空间则需要付费账号
（$99/年），那时把 entitlements 还原就行。

## 六、无线安装

数据线和 Wi-Fi 都走同一条命令（前提：设备与 Xcode 配对过一次）：

```sh
xcrun devicectl device install app --device <UDID> Andarium-local.ipa
xcrun devicectl list devices    # 看设备状态
```

**坑 3：ipa 的顶层结构必须是 `Payload/Andarium.app`**——zip 时要从
`Payload` 的父目录打包，否则装不上，报 `The provided IPA did not contain
an application bundle`。

**坑 4：`devicectl list devices` 的表格列宽可变、设备名可含空格/中文**，
awk 按列切不可靠，脚本里用 python 按两个以上空格切分，并以
`(UDID)` 后缀识别 identifier 列。

**坑 5：macOS 自带 bash 3.2 里，双引号字符串中 `$VAR` 紧贴多字节 UTF-8
字符（如全角逗号）会把 UTF-8 首字节并进变量名**，报 `TEAM<0xE5>: unbound
variable`。写脚本要么 `${VAR}` 加花括号，要么变量后接 ASCII 标点。

## 七、本地改动清单（相对上游 main）

| 文件 | 改动 | 原因 |
|---|---|---|
| `darwin/cpu/arm64/gadgets/executor.cpp` | `SlabDelete` 从嵌套类型搬到文件作用域模板 `HeapRelease<T>` | AppleClang 17 前端 bug：嵌套删除器的 `unique_ptr` 数组被判不可默认构造 |
| `Andarium/Config/Andarium.entitlements` | 去掉两个个人账号拿不到的 capability | 见"三道墙" |
| `Andarium/Andarium.xcodeproj/project.xcproj` | bundle id → `com.qzq.andarium.local` | 见"三道墙" |
| `tools/local-install.sh` | 新增 | 一键构建+安装 |
| `docs/local-build-notes.md` | 新增 | 本文档 |
| `GuestHost/Config/Signing.local.xcconfig` | 新增（gitignored） | 本机 Team ID |

## 八、清理（需要时）

```sh
rm -rf .build/downloads          # 下载的 rootfs/kernel 压缩包（~1.1G，已解包）
rm -rf .build/xcode-derived      # xcodebuild 中间产物（~1.1G，重编可再生）
rm -rf .build/dependency-build   # 依赖编译临时目录
rm -f Andarium-local-*.ipa       # 旧 ipa
```

## 九、常见问题

**Q: configure 报 `Missing ios Apple GPU dependency: libepoxy.a`**
→ GPU 前缀没编：`./dependencies/build-apple-gpu.sh --platform ios`

**Q: 编译报 `cannot execute tool 'metal'`**
→ `xcodebuild -downloadComponent MetalToolchain`

**Q: configure 报 `kernel artifact verifier: artifact root must be a regular local directory`**
→ 内核产物没解到 `.build/kernel/artifacts/`（见第三节）

**Q: `-- The accepted AOT artifact is not installed ... building without the AOT component`**
→ 可选警告。想要 AOT（系统库预翻译，跑得更快）：下载 release 里的
`lineage24-...-r29-aot.tar.gz`（126MB）解到
`.build/android/aot/lineage24-mainline6.18-4k-20261121-los24-r29`，重配重编。

**Q: 安装报 `0xe8008015`**
→ 证书 7 天过期了，重跑 `tools/local-install.sh --no-build`（会重新签名）。
