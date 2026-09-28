# 探索发现

## RustDesk（/home/zz/develope/code/github/rustdesk）
（待填写——第一次探索代理失败，重试中）

## ERP jshERP（/home/zz/develope/code/github/erp_boot）

### 技术栈
- Spring Boot 2.0.0.RELEASE，Java 8，MyBatis-Plus 3.0.7.1 + PageHelper，MySQL 8，Redis，fastjson
- 无 Shiro/Spring Security/JWT —— 认证是 **Redis-hash-token**
- 端口 9999，context path `/hytx`

### 登录体系（可直接复用给 RustDesk）
- `POST /user/login`：`UserController.java:137`，body `{loginName, password, code, uuid}`（code/uuid 为验证码 `GET /user/randomImage`）
- 响应 `BaseResponseInfo{code, data}`，data = `{msgTip:"user can login", token, user, pwdSimple}`
- Token：`UserService.login`（`service/UserService.java:332-408`）= 32位UUID去横线 + `_<tenantId>`
- 存储：Redis hash `token -> {userId, clientIp}`（`RedisService.storageObjectBySession`），TTL 6h **滑动续期**，无 refresh-token；登出删 key
- 密码：MD5 hex（`Tools.md5Encryp`）
- 微信登录路径已有：`loginByBoundWechatOpenId`/`buildLoginResult`（UserService.java:410-446）——免密码发同款 token，可照抄
- 认证过滤器：`filter/LogCostFilter.java`（`@WebFilter("/*")`），读 header **`X-Access-Token`** → Redis 查 userId；未认证返回 HTTP 500 body `"loginOut"`；白名单在 59-67 行（**新端点必须加白或带 token**）

### 多租户（自动隔离）
- `jsh_tenant` 表（`Tenant.java`）：id/tenantId(=创始用户id)/userNumLimit/type(0免费/1付费)/enabled/expireTime
- `jsh_user.tenant_id` 关联
- `config/TenantConfig.java`：MyBatis-Plus `TenantSqlParser` 自动给**除白名单外所有表**追加 `WHERE tenant_id = ?`（白名单：jsh_sequence, jsh_function, jsh_platform_config, jsh_tenant, jsh_sys_dict_data, jsh_sys_dict_type）；tenantId 从 token 尾部解析（`Tools.getTenantIdByToken`，`_` 分隔）；tenantId==0 为平台管理员
- **新建带 tenant_id 列的表即自动获得租户隔离**

### 微信扫码登录（完整已有，端到端）
- 设计文档：`plans/wechat-integration/technical_design.md`
- 配置：`application.yml:63-74` `wechat.mini-program`（app-id wxcbee1ae28659008f，secret 环境变量）
- 客户端：`service/wechat/WechatMiniProgramClient.java`（getAccessToken Redis 缓存、code2Session、getUnlimitedQRCodeBase64(sceneId) 生成小程序码）
- 场景状态机：`service/wechat/WechatMiniProgramSceneService.java`（Redis TTL 300s，状态 WAITING/SCANNED/CONFIRMED/BOUND/UNBOUND/EXPIRED/ERROR）
- 认证：`service/wechat/WechatMiniProgramAuthService.java`（confirmLogin/confirmBind/buildLoginStatus → 发 ERP token）
- PC 端接口：`controller/UserWechatMiniProgramController.java`：
  - `GET /user/wechat/miniprogram/login/qrcode`（取小程序码 base64 + sceneId）
  - `GET /user/wechat/miniprogram/login/status`（轮询）
  - `/bind/info`、`/bind/qrcode`、`/bind/status`
- 小程序端：`controller/MiniProgramWechatController.java`：`GET /mini-program/wechat/scene/info`、`POST /mini-program/wechat/login/confirm`、`POST /mini-program/wechat/bind/confirm`（已白名单）
- 绑定存储：`jsh_user.weixin_open_id`（唯一索引）
- 前端：`jshERP-web/src/views/user/Login.vue`（微信图标+二维码弹窗+1.5s轮询）、`jshERP-web/src/api/login.js:32-66`

### 后端模块模式（以 Supplier 为模板）
- Controller：`@RestController @RequestMapping("/xxx") extends BaseController`，端点 `/info /list /add /update /delete /deleteBatch /batchSetStatus`
- 响应：CRUD 用 `ResponseJsonUtil.returnJson` → `{code, message, data}`；列表用 `BaseController.getDataTable` → `{code:200, data:{rows, total}}`；杂项用 `BaseResponseInfo{code,data}`
- Service：`PageUtils.startPage()` + `@Transactional(value="transactionManager")` + `logService.insertLogWithUserId` 审计
- Mapper：`datasource/mappers/XxxMapper.java` + `XxxMapperEx.java`，XML 在 `src/main/resources/mapper_xml/`
- 菜单/权限：DB 驱动 `jsh_function` 表（number/name/parent_number/url/component/state/sort/enabled/type/push_btn/icon），角色经 `jsh_user_business`（type=RoleFunctions）关联；前端组件路径如 `/system/TenantList` → `@/views/system/TenantList.vue`

### 配置存储
- `jsh_system_config`：按租户但固定列（~16 个 varchar(1) 开关）——不适合放 RustDesk 配置
- `jsh_platform_config`：真 KV 但是**全局**（被租户过滤排除）
- **推荐**：新建 `jsh_rustdesk_config` 表（带 tenant_id，自动隔离）存 ID/中继服务器配置；全局默认可放 jsh_platform_config

### 前端 jshERP-web
- Vue 2.7.16 + ant-design-vue 1.5.2 + vuex + axios；axios 拦截器带 `X-Access-Token`
- `src/utils/request.js`（token header、500+loginOut 处理）、`src/api/manage.js`（getAction/postAction...）、`src/api/api.js`（端点注册）
- 新页面模式：`src/views/<dir>/<Name>List.vue`（mixin `src/mixins/JeecgListMixin.js`）+ `modules/<Name>Modal.vue` + api.js 注册 + `jsh_function` 插行 + 角色授权
- 列表页参考：`src/views/system/TenantList.vue`

### 设备/机器管理
- **无现成设备模块**。模板：
  - `jsh_serial_number`（序列号，设备型记录）
  - **gift 模块（人情往来）是新建独立模块最佳模板**：`jshERP-boot/docs/gift_ddl.sql`（7 表全带 tenant_id + delete_flag）、`controller/Gift*Controller`、`src/views/gift/`
  - `jsh_user_business`：通用 type/keyId/value 绑定表
- `local-print-service/`（Go，Windows 安装版 agent）= 已有向租户机器铺软件的先例
- DDL 迁移脚本约定：`jshERP-boot/docs/migration/` 编号脚本（如 `09_account_head_expense_department.sql`）

### 关键文件索引
- 认证：`jshERP-boot/src/main/java/com/jsh/erp/filter/LogCostFilter.java`、`service/UserService.java`(login:332, wechat:410)、`service/RedisService.java`、`utils/Tools.java`(md5:582, token→tenantId:619)
- 租户：`config/TenantConfig.java`、`service/TenantService.java`
- 微信：`service/wechat/`（5 类）、`config/wechat/WechatMiniProgramProperties.java`、`controller/UserWechatMiniProgramController.java`、`controller/MiniProgramWechatController.java`
- 模板：`controller/SupplierController.java`、`service/SupplierService.java`、`docs/gift_ddl.sql`
- 前端：`src/utils/request.js`、`src/api/api.js`、`src/permission.js`、`src/mixins/JeecgListMixin.js`、`src/views/user/Login.vue`
