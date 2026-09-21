# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 产品与范围

TMSkip 是 macOS 13+ 原生菜单栏应用：按 Asimov 风格规则发现可再生目录（`node_modules`、`target` 等），写入 Time Machine「排除备份」标记，并提供可搜索/可撤销的忽略列表。

- Bundle ID: `app.tmskip.mac`
- 技术栈: SwiftUI + 必要 AppKit 桥接
- **不删除用户文件**，只改备份相关元数据（`isExcludedFromBackup`）；**也不写入其他应用包（`*.app`）内**
- 仓库主页: https://github.com/JosephusZhou/TMSkip（About 页内链，见 `Views/AboutView.swift`）
- 回复语言: 除非用户明确要求其他语言，否则使用 **简体中文**

## 常用命令

```bash
# 打开工程
open TMSkip.xcodeproj

# 命令行构建（Debug）
xcodebuild -project TMSkip.xcodeproj -scheme TMSkip \
  -configuration Debug -destination 'platform=macOS' build

# 构建 + 重启应用（开发循环首选；--no-build 跳过构建）
Scripts/dev-run.sh

# 运行构建产物（路径中 * 以本机 DerivedData 实际目录为准）
open ~/Library/Developer/Xcode/DerivedData/TMSkip-*/Build/Products/Debug/TMSkip.app
```

单元测试在 `TMSkipTests` target（scheme TestAction 已接入，共 7 个测试类 / 49 个用例）：

```bash
xcodebuild -project TMSkip.xcodeproj -scheme TMSkip \
  -destination 'platform=macOS' test
# 示例:
# xcodebuild ... -only-testing:TMSkipTests/ScanEngineTests/testSkipPathsAreNotScanned
```

无独立 lint/formatter 配置；以 Xcode 默认 Swift 检查为准。

## 签名与权限

- 签名由 `Config/Signing.xcconfig`（入库，默认 ad-hoc，保证任何人 clone 后可构建）+ `Config/Local.xcconfig`（gitignore，本机个人证书）管理。`#include?` 必须位于 Signing.xcconfig **末尾**（xcconfig 后定义覆盖先定义）。
- 个人证书身份（姓名/邮箱/Team ID）只允许写在 gitignore 的 `Local.xcconfig`（模板见 `Config/Local.xcconfig.example`），**任何入库文件与文档不得出现真实身份**，避免随仓库泄漏。配置后指定需求（DR）稳定：TCC 授权一次，重编译与 Debug/Release 通用；未配置则回退 ad-hoc，每次重编译都要求重新授权。
- TCC 授权（完全磁盘访问等）绑定 DR 而非 cdhash；换证书/换 Team → DR 变 → 需重新授权一次，属预期。
- 分发：`Scripts/make-release.sh` 自动检测 Developer ID 证书（付费计划）并签名+公证；无则按当前签名打包；`ANON=1` 强制 ad-hoc 匿名分发。详见 README「分发」。
- 对外分发的正式包应换 `Developer ID Application` 并公证；用户首次授权一次属预期。
- 系统「App 管理」权限：向其他应用包内写属性会被系统拦截，TMSkip 直接跳过这类路径（见「应用包保护与权限分类」）。

## 架构总览

```text
TMSkipApp (@main) + AppDelegate（无可见主窗口时切 .accessory / 系统重开事件）
  ├── WindowGroup → RootView (NavigationSplitView)
  │     ├── SidebarView → selectedSidebar（待处理点标 + FDA 状态脚注）
  │     └── detail: ManualScan | IgnoreList | ScanSettings | About
  │     └── Onboarding overlay（FDA 未授权时）+ 顶部状态 flash
  └── MenuBarExtra (.window) → MenuBarPopoverView / MenuBarLabelView

AppModel (@MainActor, ObservableObject)  ← 唯一业务编排中心
  ├── SettingsStore          UserDefaults `tmskip.settings.v1`（容错解码 + migrate 修复）
  ├── IgnoreStore            ~/Library/Application Support/TMSkip/ignore-records.json
  ├── ScanLogService         ~/Library/Application Support/TMSkip/scan-log.jsonl
  ├── FullDiskAccessService  探测 + 打开系统设置
  ├── ScanEngine             规则遍历（可 Sendable，后台 Task.detached）
  ├── DirectorySizeService   actor，异步体积（限并发 3、20s 超时）
  ├── TimeMachineExclusionService  读/写 isExcludedFromBackup
  ├── RulePackageService     actor，从 Asimov 拉取并解析规则（data/sentinels.tsv）
  ├── NotificationService    UN 通知（delegate 在 AppModel.init 安装）
  ├── LoginItemService       SMAppService.mainApp 登录项
  ├── WindowRouter           主窗口重建/置前（未绑定场景时 pending 重放）
  └── AutoScanCoordinator    定时 + FSEvents 自动扫描（含 AutoScanLogic 纯决策）
```

### 数据流（手动扫描闭环）

1. `AppModel.startManualScan()` 校验 FDA → `Task.detached` 调 `ScanEngine.scan`
2. 命中路径映射为 `ScanCandidate`；已排除项写入 `IgnoreStore`（source 可为 `.unknown`）
3. `enqueueSizeComputation` 按候选 ID 异步填 `byteSize` / `sizeState`
4. 用户勾选后 `applySelected()` → `applyExclusions()` 逐项 `TimeMachineExclusionService.setExcluded(true)`；**位于其他应用包（`*.app`）内的路径整体跳过**并计入 `appBundleBlockedPaths`；失败路径区分权限拦截（`isPermissionDeniedError`，EROFS 不算）与一般 I/O 错误；成功项 upsert 到忽略列表；`scanPhase` 经历 `.applying` → `.done`
5. 忽略列表撤销走 `unignoreSelected()`（`setExcluded(false)` + `IgnoreStore.remove`；路径已不存在的陈旧记录直接清理）；状态异常项可 `reignoreSelected()` 重新排除

视图 **不直接** 调系统 API；读写状态与副作用经 `AppModel`。子 store 的 `objectWillChange` 已转发到 `AppModel`，多数 View 只观察 `@EnvironmentObject app`。

### 领域与配置要点

- `DomainModels.swift`: 导航、`ScanPhase`（idle/running/result/applying/done）、策略枚举、`IgnoreStatus`/`IgnoreSource`、`RulePackage`/`RuleDefinition`、`AppSettings`、忽略记录
- 扫描根 MVP: 仅 `~/`（UI 只读展示）；`AppSettings.roots: [ScanRoot]` 已预留多根（M3）
- 规则优先级: 当前 `settings.rulePackage` → 失败不阻断扫描；空规则强制 `RulePackage.bundledSnapshot`（L0 内置）
- Asimov 无规则 API: `RulePackageService` 拉取 `data/sentinels.tsv`（`dir<TAB>sentinel<TAB>ecosystem`，v0.12.0 起取代旧 bash 数组 `ASIMOV_VENDOR_DIR_SENTINELS`）并解析；分支候选 `main` → `master`（v0.12.0 起不再有 develop）；版本戳 = `bin/asimov` 的 `ASIMOV_VERSION='X'`（或旧版头 `@version X`；拉不到回退 `asimov-remote`）+ 规则数 + 内容 SHA256 前缀，规则未变则版本不 bump
- 哨兵支持 glob（`*.csproj` / `*.xcodeproj` 等，`ScanEngine.globMatch`）；换包时按规则 id 合并用户启用状态（`RulePackage.mergingEnabledStates`）
- 手动扫描 **始终** 需应用内确认；`ApplyPolicy` 同时作用于自动扫描（`notifyConfirm` 入待处理队列 / `autoApply` 立即写入，后者在设置页有二次确认）
- 扫描引擎: 不进入 `*.app` 包；目录探测用 `attributesOfItem`（不跟随符号链接，PRD 6.5 防环且防绕过 skipPaths）；跳过 `.git` / `.Trash`
- 扫描进度: 预计数校准分母（与 walk 同规则、剪枝规则命中树；上限 10 万目录 / 8 秒超时）；计数未在预算内完成时改用增长估算
- 跳过路径经 `AppSettings.normalizeSkipPath` 归一化（全角 `～`→`~`、去尾部 `/`、去首尾空白），家目录下路径缩写为 `~` 形式；拒绝跳过 `~` 或 `/` 整棵树
- `SettingsStore.migrate` 启动时修复：空 roots 补 `~`、空规则回退内置、skipPaths 归一化；`AppSettings` 全字段容错解码（`decodeIfPresent ?? 默认`），新增字段永不清配置
- Sandbox **关闭**（`TMSkip.entitlements`），因需遍历用户目录并改备份属性；依赖用户授予 **完全磁盘访问**

### 关键 UI 约定

- Detail 区需 `.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)`，避免 `NavigationSplitView` 默认垂直居中
- 关闭主窗口 ≠ 退出；AppDelegate 在无可见主窗口时切 `.accessory`（Dock 图标消失），菜单栏「打开主窗口」/Dock 点击经 `WindowRouter` 切回 `.regular` 并重建窗口（PRD 运行形态）
- 按钮样式：`.prominent` / `.secondary` / `.destructive` 为自定义 ButtonStyle（`RootView.swift`），解决窗口失焦时系统按钮被淡化不可见的问题；并排按钮高度一致
- 忽略列表表头全选勾选框用 AppKit 桥接（`TableHeaderCheckboxInstaller`）嵌入 NSTableHeaderView

## 已拍板决策（勿擅自改产品语义）

| 项 | 结论 |
|----|------|
| 扫描根 | MVP 默认仅 `~/`，模型预留多根，M3 再开放 |
| 待处理触达 | 系统通知 + 菜单栏点标 + App 内队列（通知可关、点标保留） |
| 体积估算 | MVP P0，异步、可取消、失败/超时有降级态 |
| 产品/工程名 | TMSkip |
| 应用包保护 | 不写入其他应用包（`*.app`）内；扫描不进入、应用/撤销/手动添加均跳过 |

## 自动扫描守护（已落地）

- 编排：`Services/AutoScanCoordinator.swift` = `AutoScanLogic`（纯决策、时钟可注入、单测覆盖）+ `FSEventsWatcher`（CoreServices 薄壳，latency 30s 防抖）+ `AutoScanCoordinator`（@MainActor）
- 触发：定时（启动超间隔补跑，启动宽限 8s）+ FSEvents，受 `ScanTriggerMode` 控制；任意两次自动扫描硬间隔为 `max(5min, 用户配置间隔)`——配置的「每天」等长间隔同样约束 FSEvents 触发，不会被其绕过；与手动扫描互斥，手动忙时标记、忙完补一轮
- 结果分流：已排除→静默 upsert `IgnoreStore(source:.autoScan)`；新增→按 `ApplyPolicy`（入待处理队列 `autoPendingCandidates` 或立即 `applyExclusions`）；队列按 path 去重，经通知点击/菜单栏/手动扫描页出现时 `promoteAutoPending()`
- 只写 `setExcluded(true)`：自动路径永不 re-include；手动/自动共用 `AppModel.applyExclusions`
- 通知：`Services/NotificationService.swift`（UN delegate 在 `AppModel.init` 安装；固定 identifier 覆盖不堆叠；拒绝授权只提醒一次并回退菜单栏点标）
- 登录项：`Services/LoginItemService.swift`（`SMAppService.mainApp`，随 `launchAtLogin` diff 联动，失败 flash）
- 规则：启动后 5s、之后每 24h 静默同步（`autoRuleSync` 可关），失败完全静默回退
- 窗口：`Services/WindowRouter.swift` 解决主窗口关闭后重建（`WindowBinder` 显式注入 app，勿改回 @EnvironmentObject）；场景未绑定时的打开请求会 pending，`bind` 时重放（登录项/通知冷启动场景）
- 设置：字段级 diff 只重启受影响服务（`AppModel.handleSettingsChange`），`applyPolicy`/`notificationsEnabled` 在路由/通知时读取、无需重启服务

## 扫描日志（scan-log.jsonl）

- 位置：`~/Library/Application Support/TMSkip/scan-log.jsonl`（与 ignore-records.json 同目录；不用 Caches——系统可清会丢历史，不用 ~/Library/Logs——应用数据应内聚）
- 格式：JSON Lines，每行一个 JSON 对象、追加写，单行原子；可 grep / jq 解析。时间戳 ISO8601，含 `appVersion`
- 事件（同一扫描会话用 `scanId` 关联；`AppModel.currentScanId` 手动/自动互斥共用）：
  - `scan.started`：kind=manual|auto，trigger=userInitiated|interval|fsEvents|startup
  - `scan.finished`：durationMs/foundCount/alreadyExcludedCount/pendingCount
  - `scan.cancelled`：reason（用户取消）
  - `apply.finished`：source=manualScan|autoScan，applied/failed/permissionBlocked/**appBundleBlockedCount**
- 崩溃审计：崩溃时只有 started 无 finished，恰好暴露中断扫描
- 埋点：`AppModel`（手动 start/finish/cancel、`applySelected`、`routeAutoScanResults`、`autoApply`）+ `AutoScanCoordinator.performScan` 开 `beginAutoScanLog`；写入失败 `try?` 静默降级，绝不影响扫描
- 轮转：单文件超 5MB 轮转为 `scan-log.1.jsonl`，保留最近 5 份；轮转逻辑见 `ScanLogService.rotateIfNeeded`

## 应用包保护与权限分类

- 扫描：`ScanEngine.isAppBundleName` 对任意 `.app` 目录剪枝，不进入其他应用的包
- 写入：应用/撤销/手动添加统一经 `AppModel.pathTouchesAppBundle` 判断，命中即跳过并计入结果（`appBundleBlockedPaths` / `bundleBlockedIDs`），**绝不写失败后弹系统授权**；完成页提示「按产品规则不修改其他应用的包内容」
- 权限分类：`isPermissionDeniedError` 把 EPERM/EACCES 与 Cocoa 无权限错误判为权限拦截（`permissionBlocked`），完成页提供「打开隐私与安全性设置」深链（`openAppManagementSettings` → App Management）；EROFS（只读卷）明确**不算**权限拦截，走一般失败提示
- 手动添加路径（`addManualIgnorePath`）同样拒绝 `.app` 内路径与 `~` / `/` 整树

## 忽略列表状态管理

- `IgnoreRecord.status`：`.excluded`（磁盘上仍被排除）/ `.anomaly`（路径存在但排除标记丢失）/ `.missing`（路径不存在）
- `IgnoreStore.refreshStatuses()` 重读系统排除标记刷新状态；列表支持搜索、筛选（全部/本 App 标记/状态异常/路径不存在）、排序（时间/体积/路径）
- 撤销（`unignoreSelected`）：清除排除标记 + 删记录；路径已不存在 → 直接清理陈旧记录；位于 `.app` 内 → 跳过并保留记录
- 重新忽略（`reignoreSelected`）：仅当选中项全为 `.anomaly` 时可用，重写 `setExcluded(true)` 并刷新状态
- 手动添加（忽略列表「添加忽略」sheet + 目录选择器）：`addManualIgnorePath`，source `.manualAdd`，异步回填体积
- 决策核心 `planUnignore` / `planReignore` 为静态纯函数，文件系统 I/O 注入，供单测覆盖

## 尚未实现

- 多扫描根（M3，模型已预留 `roots`）
- 自动扫描的真实定时/FSEvents 真机长稳验证（逻辑已单测，需在签名稳定的 Release 包观察登录项常驻）

## 安全约束

- 禁止访问 `~/.ssh` 及密钥、密码、cookie 等敏感材料
- 默认跳过目录（含 `~/Library` 等）是 **扫描跳过**，不是 TM 排除；文案与实现勿混淆
- 应用包内路径不写、手动添加拒绝 `~` / `/` 整树；`noReinclude` 保证规则失效时不自动取消排除
