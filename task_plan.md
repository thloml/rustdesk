# 任务计划：RustDesk 账号体系对接 ERP（jshERP）

## 目标
修改 RustDesk 客户端账号体系，与现有 ERP 项目（/home/zz/develope/code/github/erp_boot，jshERP-boot）搭配：
1. 登录使用 ERP 登录体系，支持微信扫码登录
2. ID/中继服务器等配置在 ERP 后台按租户配置，登录后直接下发（一个租户共用一套）
3. 相同账号登录后，机器配置保存到该账号，可在 ERP 后台编辑/删除机器信息
4. 未登录 RustDesk 时，功能保持现状（现有功能不变）

**详细技术方案：[plans/rustdesk-erp-integration.md](plans/rustdesk-erp-integration.md)**
**探索发现：[findings.md](findings.md)**

## 阶段

### 阶段1：探索 RustDesk 代码库
- 状态：complete

### 阶段2：探索 ERP 代码库
- 状态：complete

### 阶段3：设计整体方案
- 状态：complete
- 产出：plans/rustdesk-erp-integration.md

### 阶段4：输出实施计划
- 状态：complete

### 阶段5：实施（2026-08-31）
- 状态：complete（代码全部写完并编译/静态分析通过，未提交）
- ERP 后端：BUILD SUCCESS（mvn 3.9.16，Java 8）
- RustDesk：dart analyze 改动文件 0 错误；lang 51 文件已加 key
- 明细见 progress.md

### 阶段6：联调与回归（待用户环境）
- 状态：pending
- 前置：ERP 库执行 docs/migration/10_rustdesk_integration.sql；菜单授权；微信 secret 环境变量
- 清单：plans/rustdesk-erp-integration.md §6

## 关键决策
| 决策 | 结论 | 原因 |
|------|------|------|
| 集成方式 | ERP 实现 RustDesk 现有 `/api/*` 协议子集，客户端复用登录/AB/心跳机制 | 客户端协议层零改动，最小侵入（AGENTS.md 原则） |
| 微信扫码 | 客户端新增扫码 UI 区块，复用 ERP 场景状态机；绑定在 ERP 网页做 | ERP 已有完整端到端链路 |
| 配置下发 | 心跳 strategy.config_options（现有合并逻辑），租户解析靠登录时注册的设备表 | 零客户端改动 |
| 机器保留 | 复用个人地址簿 + sync-ab-with-recent-sessions；后台管理页读写同批表 | 该机制即"机器档案按账号存服务端"的现成实现 |
| RustDesk token TTL | 独立 30 天滑动（不复用 ERP 6h） | 客户端心跳不带 Bearer、currentUser 频率低，6h 会频繁掉线 |
| api-server 预设 | 客户端启动时为空则写入（--dart-define），不动 hbb_common | hbb_common 是子模块且未初始化，避免跨仓改动 |
| sync-ab 默认开 | 登录成功路径一行增量（选项未设置过才写），不能靠心跳推（LocalConfig≠Config2） | 心跳只写 Config2，该选项在 LocalConfig |

## 遇到的错误
| 错误 | 尝试次数 | 解决方案 |
|------|---------|---------|
| RustDesk 探索代理首次失败（captcha verify failed） | 1 | 原样重试成功 |
