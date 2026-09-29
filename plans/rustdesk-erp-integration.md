# RustDesk × jshERP 账号体系整合技术方案

> 需求：RustDesk 客户端接入 jshERP（/home/zz/develope/code/github/erp_boot）账号体系。
> 1. 登录用 ERP 登录体系，支持微信扫码登录
> 2. ID/中继服务器等配置在 ERP 后台按租户配置，登录后直接下发（一个租户共用一套）
> 3. 相同账号登录后，机器配置保留到该账号，可在 ERP 后台编辑/删除机器信息
> 4. 未登录 RustDesk 时，功能保持现状

---

## 0. 核心设计思路

**原则：ERP 实现协议，客户端复用现有机制，改动最小化。**

RustDesk 客户端本来就是"api-server 可配置"的架构（`Config2.options['api-server']` → 所有 `Bearer` 认证请求打向 `{api-server}/api/...`）。因此：

1. **ERP 后端新增一个 RustDesk 兼容 API 层**（`/hytx/api/**`），实现客户端已在使用的协议子集（登录、currentUser、心跳、地址簿）。客户端的登录态管理、地址簿同步、401 登出、配置合并**全部走现成代码路径，零协议改动**。
2. **微信扫码登录**：ERP 已有端到端链路（小程序码 + Redis 场景状态机 + 轮询确认）。客户端只需新增一个"扫码登录"UI 区块（取码 → 显示 → 轮询 → 持久化 token），复用 ERP 的 `WechatMiniProgramSceneService/AuthService`。
3. **租户级 ID/中继配置下发**：复用心跳通道的 `strategy.config_options` 机制（`src/hbbs_http/sync.rs:287-304` `handle_config_options` 会把返回的 map 合并进 `Config2.options`，即 RustDesk2.toml），ERP 按 token/设备识别租户后返回 `custom-rendezvous-server / relay-server / key`。
4. **机器信息按账号保存**：复用**个人地址簿（personal address book）**协议。客户端已有按 guid 的 REST 模式（`flutter/lib/models/ab_model.dart` 的 `Ab` 类）、登录后自动 pull、本地加密缓存、401 处理；再开启"最近会话自动同步进地址簿"（`sync-ab-with-recent-sessions`）即可满足"登录后机器配置自动保留到账号"。ERP 后台的"机器管理"页直接读写同一批表，天然双向一致。
5. **未登录 = 现状**：所有改动为增量；不登录则无 token → AB 不拉取（`ab_model.dart:122-124` 现有门槛）、心跳返回空配置、登录门槛的功能维持原状。

### 部署拓扑

```
RustDesk 客户端(定制构建)
   │  api-server = https://<erp域名>:6443/hytx   (登录/心跳/地址簿, Bearer token)
   ├──▶ jshERP-boot (Spring Boot, context=/hytx, 端口9999, nginx 6443)
   │        └── 新增 /api/** RustDesk 兼容层 + 后台管理页
   │
   └──▶ hbbs/hbbr (真正的 ID/中继服务器, 独立部署)
            地址+公钥由 ERP 按租户经心跳下发给客户端
```

ERP 本身不做信令/中继转发，只做"账号 + 配置下发 + 机器档案"。

---

## 1. 登录体系

### 1.1 账号密码登录（ERP 账号）

ERP 新增端点（注意 context path：客户端 api-server 配 `https://host:6443/hytx`，实际 URL 即 `/hytx/api/...`）：

| 端点 | 方法 | 认证 | 说明 |
|---|---|---|---|
| `/api/login` | POST | 无 | 账密登录，返回 AuthBody |
| `/api/login-options` | GET | 无 | 返回空 OIDC 列表（登录框只显示账密表单+微信入口）|
| `/api/currentUser` | POST | Bearer | 刷新登录态，返回 UserPayload |
| `/api/logout` | POST | Bearer | 删除 Redis token |

**请求/响应契约**（与客户端 `flutter/lib/common/hbbs/hbbs.dart` 的 `LoginRequest`/`LoginResponse`、Rust `src/hbbs_http/account.rs` 的 `AuthBody`/`UserPayload` 对齐）：

```jsonc
// POST /api/login  请求
{
  "username": "jshLoginName",     // 映射 jsh_user.login_name
  "password": "明文",              // HTTPS 传输；服务端 Tools.md5Encryp 后比对
  "id": "<rustdesk设备id>",        // LoginRequest 自带 → 用于设备注册(见§4)
  "uuid": "<b64 uuid>",
  "type": "account",
  "autoLogin": true,
  "deviceInfo": { "os": "Windows", "type": "client", "name": "DESKTOP-XXX" }
}
// 响应（AuthBody）
{
  "access_token": "<32位uuid>_<tenantId>",   // 沿用 ERP token 格式
  "type": "access_token",
  "user": {
    "name": "jshLoginName",        // ← login_name
    "display_name": "张三",         // ← username
    "avatar": "",                  // 无头像，留空
    "status": 1,
    "is_admin": false,
    "info": { "settings": null, "other": {"erp_user_id": 123} }
  }
}
```

**Token 策略**：复用 `UserService.login` 的签发逻辑（`service/UserService.java:332-408`，UUID + `_<tenantId>`，Redis hash `{userId, clientIp}`），但 **TTL 单独用 30 天滑动**（新增常量，如 `RUSTDESK_SESSION_IN_SECONDS`）。原因：客户端心跳/AB 调用不带 Bearer（心跳）或频率不定（currentUser 仅启动时校验），ERP 默认 6h TTL 会导致频繁掉线。

**安全取舍**：客户端协议无验证码 UI，`/api/login` 不做图片验证码；用 IP 限流 + 连续失败锁定弥补（Nginx 或服务端计数）。

### 1.2 微信扫码登录

完全复用 ERP 已有链路：`WechatMiniProgramClient.getUnlimitedQRCodeBase64(sceneId)` + `WechatMiniProgramSceneService`（Redis 状态机 WAITING/SCANNED/CONFIRMED/EXPIRED，TTL 300s）+ `WechatMiniProgramAuthService` + 小程序确认页（`mini-program/src/pages/wechat-auth/index.vue` 不改或仅加 scene 来源标记）。

ERP 新增两个客户端端点（加入 `LogCostFilter` 白名单）：

```
GET /api/wechat/login/qrcode
  → { "qrcode_base64": "data:image/png;base64,...", "scene_id": "xxx", "expire_seconds": 300 }

GET /api/wechat/login/status?scene_id=xxx     （客户端 1.5s 轮询）
  → { "status": "WAITING" | "SCANNED" | "EXPIRED" }
  → { "status": "CONFIRMED", "access_token": "...", "user": {...} }   // 内部走 loginByBoundWechatOpenId 同款签发
```

绑定流程不进 RustDesk 客户端（v1 范围收缩）：用户在 ERP 网页端绑定微信（`/user/wechat/miniprogram/bind/qrcode` 已有），之后才能扫码登录 RustDesk。**前置校验**：扫码登录时若 `jsh_user.weixin_open_id` 为空，status 返回业务错误提示"请先在 ERP 后台绑定微信"。

### 1.3 客户端如何知道 ERP api-server（引导）

三个方案，推荐 A：

- **A（推荐）**：定制构建预设 —— Flutter 启动时若 `api-server` 选项为空则写入默认值（`--dart-define=ERP_API_SERVER=...` 或 const）。一行增量，不动 hbb_common 子模块。
- B：用现有"配置客户端"机制分发 base64 服务器配置串（`flutter/lib/common.dart:2960-2987` `ServerConfig` → `applyServerConfig:3645`）。
- C：hbb_common `OVERWRITE_SETTINGS` 硬预设（需要改子模块仓库）。

> 注意：`libs/hbb_common` 子模块当前未初始化（`git submodule status` 显示 `-b2b1ac4`），任何本地构建前需 `git submodule update --init libs/hbb_common`。

---

## 2. 租户级 ID/中继配置下发

### 2.1 数据模型

新表 `jsh_rustdesk_config`（`tenant_id` 唯一，自动享受 MyBatis-Plus `TenantSqlParser` 租户隔离——`config/TenantConfig.java:27-97`）：

```sql
CREATE TABLE jsh_rustdesk_config (
  id            BIGINT AUTO_INCREMENT PRIMARY KEY,
  tenant_id     BIGINT NOT NULL,
  id_server     VARCHAR(200)  COMMENT 'ID服务器 host[:21116] → custom-rendezvous-server',
  relay_server  VARCHAR(200)  COMMENT '→ relay-server',
  server_key    VARCHAR(200)  COMMENT 'hbbs 公钥 → key',
  enabled       TINYINT DEFAULT 1,
  remark        VARCHAR(500),
  create_time   DATETIME, update_time DATETIME, delete_flag TINYINT DEFAULT 0,
  UNIQUE KEY uk_tenant (tenant_id)
);
```

### 2.2 下发通道：心跳

客户端配了自定义 api-server 后自动开启心跳循环（`sync.rs:86-284`，每 3s，`POST /api/heartbeat`，无 Bearer）。ERP 实现逻辑：

1. 请求体中识别设备（登录时已把 `id/uuid` 注册进 `jsh_rustdesk_device`，见 §4）→ 得到 tenant_id；
2. 未登录/未注册设备 → 返回空 `config_options`（行为等同现状）；
3. 已注册 → 查 `jsh_rustdesk_config` 返回：

```jsonc
// POST /api/heartbeat 响应
{
  "strategy": {
    "config_options": {
      "custom-rendezvous-server": "id.xxx.com:21116",
      "relay-server": "relay.xxx.com",
      "key": "<hbbs公钥>"
    }
  },
  "modified_at": 1735600000
}
```

客户端 `handle_config_options` 自动合并进 `Config2.options`，连接层（`rendezvous_mediator.rs:403-409`、`client.rs:283`）即可用。

**已知约束**：`rendezvous_mediator` 在启动时读取服务器地址，心跳下发的变更可能需**重启客户端**才对 ID 服务器生效（key/relay 按连接读取，即时生效）。实现阶段验证；必要时客户端加"服务器配置已更新，重启后生效"提示。

---

## 3. 机器信息按账号保存（个人地址簿）

### 3.1 数据模型

照 gift 模块规范（全表带 `tenant_id` + `delete_flag`）：

```sql
-- 个人地址簿（每用户一条）
CREATE TABLE jsh_rustdesk_ab (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  guid VARCHAR(64) NOT NULL,
  tenant_id BIGINT NOT NULL,
  user_id BIGINT NOT NULL,
  name VARCHAR(100) DEFAULT '我的机器',
  create_time DATETIME, update_time DATETIME, delete_flag TINYINT DEFAULT 0,
  UNIQUE KEY uk_user (tenant_id, user_id),
  UNIQUE KEY uk_guid (guid)
);

-- 机器记录
CREATE TABLE jsh_rustdesk_ab_peer (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  guid VARCHAR(64) NOT NULL,
  ab_guid VARCHAR(64) NOT NULL,
  tenant_id BIGINT NOT NULL,
  remote_id VARCHAR(100) NOT NULL,
  hash VARCHAR(128) COMMENT '登录凭证哈希(客户端上传)',
  username VARCHAR(100), hostname VARCHAR(200), platform VARCHAR(50),
  alias VARCHAR(100),
  tags VARCHAR(500) COMMENT 'JSON数组',
  note VARCHAR(500),
  create_time DATETIME, update_time DATETIME, delete_flag TINYINT DEFAULT 0,
  UNIQUE KEY uk_guid (guid),
  KEY idx_ab (ab_guid), KEY idx_tenant (tenant_id)
);

-- 标签
CREATE TABLE jsh_rustdesk_ab_tag (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  guid VARCHAR(64) NOT NULL,
  ab_guid VARCHAR(64) NOT NULL,
  tenant_id BIGINT NOT NULL,
  name VARCHAR(100), color VARCHAR(20),
  create_time DATETIME, delete_flag TINYINT DEFAULT 0,
  UNIQUE KEY uk_guid (guid), KEY idx_ab (ab_guid)
);
```

### 3.2 客户端协议端点（全部 Bearer，按 tenant+user 隔离）

实现 `ab_model.dart` 中 `Ab`（per-guid REST 模式）已调用的端点，客户端零改动：

```
POST   /api/ab/personal                          → {guid, name}（不存在则建）
POST   /api/ab/peers?current&pageSize&ab=<guid>  → {total, data:[Peer]}
POST   /api/ab/peer/add/<guid>                   （body: {peers:[...]})
PUT    /api/ab/peer/update/<guid>                （alias/tags/note/hash 局部更新）
DELETE /api/ab/peer/<guid>                       （guid=记录guid）
GET    /api/ab/tags/<guid>                       → {total, data:[{name,color}]}
POST   /api/ab/tag/add/<guid> · PUT tag/rename · PUT tag/update · DELETE tag/<guid>
```

Peer 字段对齐 `peer_model.dart:7-66`：`{id, hash, username, hostname, platform, alias, tags}`。

### 3.3 "登录后自动保留机器配置到账号"

开启 `sync-ab-with-recent-sessions`：客户端每 3s 把最近会话合并推入个人地址簿（`ab_model.dart` 构造器中已有定时器逻辑）。

**注意**：该选项存于 `LocalConfig`（RustDesk_local.toml），而心跳 `strategy.config_options` 只写 `Config2`（RustDesk2.toml）——**推不过去**，需客户端一行增量改动：ERP 登录成功后若该选项未设置过则置 `'Y'`（保留用户显式关闭的能力）。

### 3.4 ERP 后台"机器管理"

- 列出本租户（可按用户筛选）的全部机器记录：remote_id / alias / 归属用户 / platform / hostname / 标签 / 备注 / 最近更新时间
- 编辑：alias、tags、note（写 `jsh_rustdesk_ab_peer`）→ 客户端下次 pull 生效
- 删除：逻辑删除 → 客户端下次 pull 消失
- 权限：`jsh_function` 插菜单行 + 角色授权（`jsh_user_business`）

> 说明：PeerConfig 中的查看偏好（画质/视图样式等）是客户端本地文件，不随地址簿同步——这是 RustDesk 设计，保留到账号的是"机器清单 + 别名/标签/备注 + 登录凭证哈希"。

### 3.5 设备档案（本机注册，配置下发的依赖）

登录请求自带 `id/uuid/deviceInfo`，ERP 端 upsert：

```sql
CREATE TABLE jsh_rustdesk_device (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  tenant_id BIGINT NOT NULL, user_id BIGINT NOT NULL,
  client_id VARCHAR(100) NOT NULL COMMENT 'rustdesk设备id',
  uuid VARCHAR(100), hostname VARCHAR(200), os VARCHAR(50), version VARCHAR(50),
  alias VARCHAR(100) COMMENT '后台可编辑', note VARCHAR(500),
  last_login_time DATETIME, last_heartbeat_time DATETIME,
  create_time DATETIME, delete_flag TINYINT DEFAULT 0,
  KEY idx_tenant_client (tenant_id, client_id)
);
```

`/api/sysinfo` 顺带更新设备信息；后台"设备列表"页可查看/编辑别名/删除（删除后客户端下次登录重新注册）。心跳按此表解析租户——**这是配置下发的租户解析依据**。

---

## 4. 改造清单

### 4.1 ERP 后端（jshERP-boot，Java 8 / Spring Boot 2.0，遵守现有 Supplier/gift 模块模式）

| # | 内容 | 参照 |
|---|---|---|
| B1 | DDL 迁移脚本 `docs/migration/NN_rustdesk.sql`：4 张新表 + `jsh_function` 菜单行 | `docs/migration/09_*.sql`、`docs/gift_ddl.sql` |
| B2 | `controller/RustDeskApiController.java`（`/api/**`）：login、login-options、currentUser、logout、heartbeat、sysinfo、wechat login qrcode/status | `SupplierController` |
| B3 | `controller/RustDeskAbApiController.java`（`/api/ab/**`）：§3.2 端点 | `SupplierController` |
| B4 | `controller/RustDeskConfigController.java`（`/rustdesk/config/*`）+ `RustDeskDeviceController` + `RustDeskMachineController`（后台管理，走现有 X-Access-Token 过滤） | `SupplierController` |
| B5 | `service/rustdesk/`：`RustDeskAuthService`（照抄 login 签发逻辑+30d TTL+微信状态机对接）、`RustDeskAbService`、`RustDeskConfigService`、`RustDeskDeviceService` | `UserService.login:332`、`service/wechat/*` |
| B6 | 实体 + Mapper（含 MapperEx + XML） | `SupplierMapperEx.xml` |
| B7 | `LogCostFilter` 白名单追加：`/api/login`、`/api/login-options`、`/api/heartbeat`、`/api/sysinfo`、`/api/wechat/login/qrcode`、`/api/wechat/login/status`（其余 `/api/**` 需 token） | `LogCostFilter.java:59-67` |
| B8 | 登录限流（IP 计数，Redis） | — |

### 4.2 ERP 前端（jshERP-web，Vue 2.7 + ant-design-vue 1.5）

| # | 内容 | 参照 |
|---|---|---|
| F1 | `src/views/rustdesk/RustDeskConfig.vue`：租户 ID/中继/公钥配置表单 | `views/system/TenantList.vue` |
| F2 | `src/views/rustdesk/DeviceList.vue`：设备档案列表（编辑别名/备注、删除） | `mixins/JeecgListMixin.js` |
| F3 | `src/views/rustdesk/MachineList.vue` + `modules/MachineModal.vue`：机器记录管理（按用户筛选、编辑、删除） | 同上 |
| F4 | `src/api/api.js` 注册 + `jsh_function` 插行 + 角色授权 | `api.js` |

### 4.3 RustDesk 客户端（最小增量，全部可 `#[cfg]`/常量门控）

| # | 内容 | 位置 |
|---|---|---|
| C1 | 微信扫码登录区块：取码→展示→1.5s 轮询→CONFIRMED 后按 `handleLoginResponse` 同款路径持久化 `access_token`/`user_info` | `flutter/lib/common/widgets/login.dart`（新 widget，可拆 `wechat_qr_login.dart`；桌面/移动共用） |
| C2 | api-server 默认预设：启动时若为空写入 ERP 地址（`--dart-define`） | `flutter/lib/main.dart` 或 `common.dart` 启动钩子 |
| C3 | ERP 登录成功后默认开启 `sync-ab-with-recent-sessions`（未设置过才写） | `flutter/lib/models/user_model.dart` 登录成功路径 |
| C4 | 新 UI 文案：按本地化规则加 key（key 即英文文本，`template.rs` 追加 + 各语言文件翻译/留空，`cn.rs` 填中文） | `src/lang/*.rs` |
| C5 | （可选，视 R2 验证结果）服务器配置更新后的重启提示 | — |

**不改**：`hbbs_http/`、`ab_model.dart`、`hbb_common`——协议层零改动。

### 4.4 未登录 = 现状（保障机制）

- 无 token → AB pull 直接 return（`ab_model.dart:122-124` 现有门槛）、currentUser 早退（`user_model.dart:57-61`）、心跳无设备档案 → ERP 返回空 config_options、登录门槛 UI 维持现状
- 未配 api-server（用户清空预设）→ 心跳循环不启动，与原版行为一致
- 连接/最近会话/LAN/文件传输等功能不依赖登录（已确认现状）

---

## 5. 实施计划（5 期）

| 期 | 内容 | 交付/验收 | 预估 |
|---|---|---|---|
| **0 准备** | rustdesk 拉分支 `feat/erp-account`；erp_boot 拉分支 `feat/rustdesk-integration`；`git submodule update --init libs/hbb_common` | 分支就绪，rustdesk 可本地编译 | 0.5d |
| **1 ERP 兼容层核心** | B1(4表)、B2(除微信)、B5(AuthService/DeviceService/ConfigService)、B7、B8 | curl 模拟客户端：登录→currentUser→heartbeat 收到租户 config_options | 3d |
| **2 ERP 地址簿+微信** | B3、B2(微信两接口)、B5(AbService+微信对接) | curl 全 AB 协议走通；微信场景 WAITING→SCANNED→CONFIRMED 签发 token | 3d |
| **3 ERP 后台前端** | B4、F1-F4、菜单/角色 SQL | ERP 网页可配服务器、管理设备与机器 | 2d |
| **4 客户端改造** | C1-C4 | 桌面端真机：账密登录、微信扫码登录、登录后 AB 自动出现最近会话、后台改配置客户端生效 | 3d |
| **5 联调回归** | 见 §6 清单；定制构建脚本（`--dart-define=ERP_API_SERVER=...`） | 全场景通过 | 2d |

---

## 6. 验收/回归清单

**登录**
- [ ] 账密登录成功，设置页显示 ERP 用户名
- [ ] 微信扫码：扫码→小程序确认→客户端自动进入登录态；未绑定用户提示去 ERP 绑定；二维码 300s 过期自动刷新
- [ ] token 过期（Redis 删除）→ 下次 API 调用 401 → 客户端自动登出（现有 reset 逻辑）
- [ ] 登出后回到未登录形态，功能=原版

**配置下发**
- [ ] 租户 A 配置 ID/中继/公钥 → 登录的租户 A 客户端心跳收到并入库 RustDesk2.toml
- [ ] 未登录客户端心跳返回空配置
- [ ] 租户 B 客户端收到 B 的配置（互不串扰）
- [ ] 修改配置后 ID 服务器切换生效（验证 R2 是否需重启）

**机器保留**
- [ ] A 机登录账号 X，连接若干机器 → 地址簿自动出现（sync-ab）
- [ ] B 机登录同账号 X → pull 后机器清单一致、密码哈希可用
- [ ] ERP 后台改 alias/标签 → 客户端 pull 生效；后台删除 → 客户端消失
- [ ] 多租户隔离：租户 A 管理员看不到租户 B 的机器/设备/配置

**未登录回归**
- [ ] 最近会话、LAN 发现、直连、文件传输、主界面无地址簿面板（与原版一致）

---

## 7. 风险与待验证点

| # | 风险 | 应对 |
|---|---|---|
| R1 | `libs/hbb_common` 子模块未初始化，config.rs 行号以 GitHub b2b1ac4 为准 | 期0 初始化；实现时以本地代码为准 |
| R2 | 心跳下发 `custom-rendezvous-server` 后，`rendezvous_mediator` 启动时才读 → 可能需重启生效 | 期4 实测；必要时加提示或触发重连 |
| R3 | `/api/login` 无验证码，可被爆破 | IP 限流 + 失败锁定；仅走 HTTPS |
| R4 | ERP 改密码/禁用用户后旧 token 仍有效至 TTL | 接受（30d 内）；或 currentUser 时校验 `delete_flag/status`（推荐，成本低） |
| R5 | api-server 带 context path（`/hytx`）时客户端 URL 拼接是否正确 | 期1 用真实客户端联调首验 |
| R6 | `login-options` 响应格式必须匹配客户端解析（`user_model.dart:240-264`） | 期1 实现时按解析代码核对，返回空 provider 列表 |
| R7 | Spring Boot 2.0/Java 8 老栈，新代码不能用新 API | 遵守现有模块写法 |
| R8 | 同一台机器先后被两个租户账号登录，设备档案租户归属冲突 | 设备行按最近登录 upsert 归属（文档化；不做多归属） |
| R9 | 微信码 5 分钟过期与轮询 UI 状态同步 | EXPIRED → 客户端自动重新取码 |

---

## 8. 明确不做（v1 范围外）

- RustDesk 客户端内绑定/解绑微信（去 ERP 网页操作）
- 共享地址簿、团队地址簿（仅个人地址簿）
- 客户端设置漫游（画质/视图偏好等 PeerConfig 本地项）
- ERP 后台远程下发策略（ Strategy 的非配置类字段）、审计日志对接
- 网页版客户端
