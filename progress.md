# 会话进度日志

## 会话 2026-08-30
- 创建规划文件
- 两个探索代理完成，报告归档 findings.md
- 技术方案 plans/rustdesk-erp-integration.md

## 会话 2026-08-31（实施）
- 期0：rustdesk 分支 feat/erp-account；erp_boot 分支 feat/rustdesk-integration（基于 hytx）；hbb_common 子模块已初始化
- 工具链装至 /home/zz/develope/program：Maven 3.9.16（阿里云镜像 settings）、Flutter 3.24.5（flutter-io.cn）、Rust stable（rsproxy）
- 期1+2 后端：10_rustdesk_integration.sql（5 表+菜单 0111 段）、5 实体（Lombok）、5 Mapper+XML、4 服务（auth/device/config/ab）、RustDeskApiController(/api/**)、RustDeskAbApiController(/api/ab/**)、RustDeskAdminController(/rustdesk/**)
- 共享文件最小改动：LogCostFilter 白名单 +6 项、BusinessConstants +RUSTDESK_SESSION_IN_SECONDS(30d)、TenantConfig ISqlParserFilter 排除 RustDesk* 语句
- 期3 前端：RustDeskConfigList/DeviceList/MachineList + 2 Modal + api.js 8 个函数
- 期4 客户端：wechat_qr_login.dart 新组件 + login.dart 挂载；main.dart _presetErpApiServer（--dart-define=ERP_API_SERVER 可覆盖，默认 https://admin.hongyuntongxun.cn:6443/hytx）；user_model 登录成功默认开 sync-ab；ab_model Ab.syncFromRecent 个人簿自动补齐缺失机器；51 个 lang 文件加 4 个文案 key
- 编译验证：
  - ERP 后端 mvn compile **BUILD SUCCESS**（修复 3 处：dealNullStr 在 Tools、login-options 须返回 JSON 数组、旧版 Redis increment 需步长、微信响应补 type 字段）
  - dart analyze 改动文件 **0 错误**（仅 main.dart 原有 6 个废弃 info）
- 未提交，等用户 review；pubspec.lock 已还原
- 待办：真机联调（期5 清单见 plans/rustdesk-erp-integration.md §6）

## 会话 2026-08-31（追加：心跳即时生效）
- 需求：ID 服务器下发即时生效；心跳 10s 一次
- sync.rs：TIME_HEARTBEAT 15s→10s、TIME_CONN 3s→10s；handle_config_options 检测 custom-rendezvous-server 生效值变更 → 调用现成的 RendezvousMediator::restart()（外层循环重读配置立即重连）
- 边界修复（防重启死循环）：客户端按"生效值"比较（absent 视为 ""），absent→"" 不触发重启
- ERP heartbeat 改为条件返回：无配置→空 map（不碰客户端本地设置）；启用→仅返回非空 key；停用→三 key 空串（主动清除+回退）
- 验证：**cargo check --lib --features linux-pkg-config → Finished，0 错误**（2026-08-31，用户装齐系统依赖后）
  - 依赖排障过程：缺 pkg-config→用户装 CI 同款清单；缺 openssl/dbus→补 libssl-dev libdbus-1-dev；magnum-opus/scrap 默认走 vcpkg→改用仓库自带 linux-pkg-config 特性（需 libopus/libvpx/libaom/libyuv-dev）
  - Ubuntu 的 libyuv-dev 不带 .pc → 自建 shim：/home/zz/develope/program/pkgconfig/libyuv.pc，**以后构建需 export PKG_CONFIG_PATH=/home/zz/develope/program/pkgconfig**
  - 7 个 warning 全部为未触碰文件的原有未使用导入（common.rs/keyboard.rs/connection.rs 等）
  - lang 51 文件改动随 lib.rs:45 mod lang 一并通过编译检查
  ## 会话 2026-09-29（Docker 打包完成）
- 环境：本机 Docker（68.10 已弃用）；瘦镜像 ubuntu:24.04（tuna rootfs 导入避开 Docker Hub 限流）只装 apt 依赖；宿主工具链挂载复用（rustup/cargo/flutter/pub-cache，原路径挂载解决 package_config 绝对路径）；vcpkg 每平台独立根 + 二进制缓存持久化
- 产物（/home/zz/data/rustdesk/output/）：
  - hongyundesk-android-arm64.apk 28.6MB（debug 签名；libapp.so 12.2M + librustdesk.so 31.5M + libc++_shared 9.2M，573 文件校验通过）
  - hongyundesk-1.4.9.deb 25.4MB（Package: hongyundesk；/usr/share/hongyundesk/ 全部改名；hongyundesk.service；usr/share/rustdesk 残留=0）
- 排障记录（关键坑与解法）：
  1. 巨型单镜像 export 卡死 → 瘦镜像+挂载方案
  2. 容器内 cargo metadata 死锁（外层 futex+持有 .package-cache）→ 缺 windows 目标 crate 经代理断流挂死；宿主无代理先补齐 cargo metadata 缓存解决
  3. FRB 桥接生成必须在宿主跑（容器 bind-mount 下 cargo metadata 不稳）；--llvm-path /usr/lib/llvm-18 修 ffigen（noble llvm-18 不在 FRB 默认列表）；rustfmt 组件缺失需补装
  4. gradle：阿里云 init 脚本（beforeSettings+clear()）；gradle-wrapper 发行包用腾讯镜像手放 dists；FLUTTER_STORAGE_BASE_URL 必须用 storage.flutter-io.cn（tuna 不镜像 download.flutter.io，404）；sdkmanager 下载易截断→清理重试+校验（android.jar/aapt2）；SDK 组件全量预装 31/32/33/34+30.0.3/33.0.1/34.0.0
  5. pkill -f 自匹配教训：模式加 [] 或改用 docker kill
- Windows：仍需 Windows 机器（build.py --flutter 出便携包 + res/HongYunDesk-installer.iss 出安装器，独立 AppId）

## 会话 2026-08-31（追加：品牌改名 宏运桌面）
- 机制：APP_NAME 是 RwLock（hbb_common config.rs:72），get_app_name() 全 UI 走它；lang.rs 对非 RustDesk 名自动把翻译串里的 "RustDesk" 替换为应用名
- 改动 9 处：core_main.rs 启动最前写 APP_NAME="宏运桌面"（须在 global_init 前，配置/日志目录名由它派生）、Runner.rc FileDescription/ProductName、res/*.desktop Name、iOS Info.plist DisplayName+BundleName、macOS Info.plist 新增 CFBundleDisplayName、AndroidManifest 两个 label、tabbar_widget 首页 tab 标题改 bind.mainGetAppNameSync()
- 自动跟随（未改）：所有窗口标题(getWindowName)、移动端标题、About、托盘、含 RustDesk 的翻译串、is_custom_client 行为
- 有意不改（技术标识）：rustdesk.exe/crate 名/flutter_hbb 包名/Android applicationId/macOS PRODUCT_NAME/服务名/StartupWMClass
- 配置文件名随之变为 宏运桌面*.toml（全新 profile，ERP 预设等照常生效）；URI scheme 变为 宏运桌面://（如需 rustdesk:// 深链兼容另议）
- 验证：cargo check --lib Finished 0 错误；dart analyze tabbar 仅 1 个原有 info

## 会话 2026-08-31（追加：共存改造）
- 目标：宏运桌面与官方 RustDesk 各平台安装共存
- 运行时已天然隔离（APP_NAME 派生：配置/日志/IPC 管道/Windows 服务名），本轮解决"安装层"：
- Android：applicationId → com.hongyun.hongyundesk（manifest package 属性不动，Kotlin namespace 不变）
- iOS/macOS：bundle id ×3 → com.hongyun.hongyundesk；macOS 产物 RustDesk.app → 宏运桌面.app（build.py mv + workflow 三处）
- Linux（build.py + res/）：deb 包名 hongyundesk、安装目录 /usr/share/hongyundesk、/usr/bin/hongyundesk 符链、包内二进制 mv 为 hongyundesk（关键：官方 service 的 pkill -f "rustdesk --" 不会误杀我们进程，反之亦然）、systemd 单元 hongyundesk.service、图标 hongyundesk.png/svg、control Package/Description、DEBIAN 四脚本全部改路径；不再安装 rustdesk-link.desktop（不与官方争抢 rustdesk:// scheme）；postrm 清理宏运桌面配置目录；DRM 变体（assert/glob/retarget Conflicts 链）同步跟改；legacy sciter 路径同步+control 包名 sed
- 有意保留：/usr/lib/rustdesk/libdrmtap dlopen 编译期路径（fork 私有文件，与官方无文件冲突）；PKGBUILD/rpm spec 未跟改（arch/rpm 打包非当前交付物）
- Windows：安装器脚本不在本仓库——打包时需用独立 AppId/安装目录/快捷方式名（文档已注明）
- 验证：py_compile build.py OK；bash -n 四脚本 OK；residual 扫描 0 残留





