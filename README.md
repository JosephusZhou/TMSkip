# TMSkip

把可再生目录（`node_modules`、`target`、`Pods` 等）移出 Time Machine 备份。

| 项 | 内容 |
|----|------|
| 产品名 | **TMSkip** |
| 平台 | macOS 13+ |
| 技术 | SwiftUI |
| Bundle ID | `app.tmskip.mac` |
| 仓库 | [github.com/JosephusZhou/TMSkip](https://github.com/JosephusZhou/TMSkip) |

## 界面预览

### 手动扫描

一键扫描用户主目录，按 Asimov 规则查找可再生目录，结果需确认后才写入排除。

![手动扫描](screenshots/TMSkip-001.png)

### 忽略列表

所有已排除路径统一管理，支持搜索、筛选、排序、撤销与手动添加。

![忽略列表](screenshots/TMSkip-002.png)

### 扫描配置

自动扫描策略、触发模式、结果处理方式、扫描范围与跳过目录均可自定义。

![扫描配置](screenshots/TMSkip-003.png)

### 菜单栏

驻留菜单栏，随时查看已忽略体积、触发扫描、切换自动扫描开关。

![菜单栏](screenshots/TMSkip-004.png)

## 运行

```bash
cd TMSkip                 # 仓库根目录
open TMSkip.xcodeproj
# 或命令行：
xcodebuild -project TMSkip.xcodeproj -scheme TMSkip -configuration Debug -destination 'platform=macOS' build
open ~/Library/Developer/Xcode/DerivedData/TMSkip-*/Build/Products/Debug/TMSkip.app
```

首次启动会引导 **完全磁盘访问**。授权后可：

1. **手动扫描** `~/`（Asimov 规则快照）
2. 查看结果体积、勾选、应用 Time Machine 排除（位于其他应用包内的路径自动跳过）
3. 在 **忽略列表** 中搜索、筛选、撤销，或手动添加要排除的目录
4. 在 **扫描配置** 中改策略、跳过目录、规则开关
5. 使用 **菜单栏** 快捷入口

安全边界：扫描只读；应用排除只写备份元数据（`isExcludedFromBackup`），**不删除任何文件**，也不会进入其他应用的 `.app` 包。写入被系统权限拦截时（如「App 管理」），完成页会给出授权引导。

## 分发

### 选项 A：付费开发者计划（$99/年，推荐，用户体验最好）

1. 创建 **Developer ID Application** 证书（Xcode 或 developer.apple.com）
2. 一次性配置公证凭据：
   ```bash
   xcrun notarytool store-credentials TMSkipNotary \
       --apple-id <AppleID> --team-id <TeamID> --password <App专用密码>
   ```
3. 打包（自动检测证书 → 重签 → 公证 → 装订）：
   ```bash
   ./Scripts/make-release.sh   # 产出 dist/TMSkip-<版本>.zip
   ```
用户下载解压即可打开；首次使用授权一次「完全磁盘访问」。

### 选项 B：零成本发未公证包

同样用 `./Scripts/make-release.sh` 打包（无 Developer ID 证书时自动跳过公证）。
接收方首次打开需绕过 Gatekeeper：**右键 → 打开**，或：

```bash
xattr -cr /Applications/TMSkip.app
```

两种子模式：

- 默认：保留工程签名（本机配置了 `Config/Local.xcconfig` 时，**包内会含你的证书身份：姓名/邮箱**，接收方用 `codesign -dvvv` 可见）。
- **匿名分发**（推荐给不想暴露身份的场景）：

  ```bash
  ANON=1 ./Scripts/make-release.sh
  ```

  强制 ad-hoc 重签，包内不含任何证书身份（已验证：`codesign -dvvv` 仅显示
  `Signature=adhoc`，全包搜索不到姓名/邮箱/Team ID）。接收方体验不变。
  注意：ad-hoc 包更新版本时，新包 cdhash 不同，接收方可能需重新授权一次
  完全磁盘访问（仅在系统弹出时）。

### 选项 C：只发源码，用户自行构建

```bash
git clone <repo> && cd TMSkip && open TMSkip.xcodeproj
# Xcode → Signing & Capabilities → 勾选自动签名，选择自己的 Personal Team
```

仓库默认 ad-hoc 签名，clone 后即可构建。提示：TCC 授权（完全磁盘访问等）绑定
签名身份，ad-hoc 每次重编译都要重新授权；想要「授权一次、重编译通用」，复制
`Config/Local.xcconfig.example` 为 `Config/Local.xcconfig` 并填入自己的开发者证书
（该文件不入库）。Debug 与 Release 使用同一张证书时，两边共享同一份授权。

### 本地发布 GitHub Release（自动打包 + 上传 DMG + 绑定 tag）

`./Scripts/release-github.sh` 在本机完成「编译 → 分包 → 发布」全流程，不依赖
GitHub Actions（运行器 macOS SDK 较老，打包出的 UI 与本机最新 SDK 有差异）：

1. 一次 universal 编译（x86_64 + arm64），再 lipo 拆分成两个单架构 DMG：
   `dist/TMSkip-<版本>-arm64.dmg` / `dist/TMSkip-<版本>-x86_64.dmg`
2. 生成 `dist/SHA256SUMS.txt` 校验和，随 Release 一并上传
3. 版本号默认读构建产物 Info.plist（也可作为参数传入，如
   `./Scripts/release-github.sh 0.4.0`，DMG 内版本与 tag 对齐），
   Release 自动绑定 `v<版本>` tag：
   - 本地/远端没有该 tag 时，自动在当前 HEAD 创建并 push 到 origin；
   - tag 已存在则直接绑定，绝不移动已有 tag（仅远端存在时会先 fetch 到本地）
4. 通过 GitHub API 创建或更新对应 Release，并上传 DMG 与校验和
   （同一版本重复执行 = 更新 Release + 同名资产先删后传）

前置：导出 `GITHUB_TOKEN`（需 `repo` 权限，GitHub → Settings → Developer
settings → Personal access tokens 生成）；或本机安装并登录 `gh` CLI。

```bash
export GITHUB_TOKEN=ghp_xxx
./Scripts/release-github.sh                 # 用工程当前版本（如 0.4.0）构建并发布
./Scripts/release-github.sh 0.4.0           # 指定版本（构建 + 发布，绑定 v0.4.0）
./Scripts/release-github.sh --skip-build    # 复用 dist 已有 DMG，只做发布
./Scripts/release-github.sh --dry-run       # 构建打包，但不 push tag / 不调 API
DRAFT=1 ./Scripts/release-github.sh         # 以草稿形式创建 Release，确认后再手动发布
```

签名沿用工程配置（本机配置 `Config/Local.xcconfig` 则用个人证书，否则 ad-hoc）；
lipo 分包改写了主二进制，脚本自动按同一身份重签。需要覆盖重签身份时（例如匿名分发）：

```bash
ANON=1 ./Scripts/release-github.sh                  # 强制 ad-hoc 重签（包内不含证书身份）
IDENTITY="Developer ID Application: xxx" \
  ./Scripts/release-github.sh                       # 指定身份重签（或 "-" 表示 ad-hoc）
```

注意：覆盖仅作用于 lipo 分包后的重签，最终 DMG 内 app 以该身份为准；Xcode
构建阶段仍用工程签名（不影响产物）。Developer ID 重签后若未公证，下载者首次
打开仍需右键 → 打开。

### `make-dmg.sh` 环境变量（`release-github.sh` 同样生效）

| 变量 | 作用 |
|------|------|
| `ANON=1` | 强制 ad-hoc 重签（优先级最高，包内不含证书身份） |
| `IDENTITY` | 指定重签身份（如 `Developer ID Application: xxx`，或 `-` 表示 ad-hoc） |

### `make-release.sh` 环境变量

| 变量 | 作用 |
|------|------|
| `ANON=1` | 匿名分发：强制 ad-hoc 重签并跳过公证（优先级最高，即使检测到 Developer ID） |
| `IDENTITY` | 指定签名身份（默认自动检测 `Developer ID Application` 证书） |
| `NOTARY_PROFILE` | 公证用的 keychain profile（默认 `TMSkipNotary`） |

## 工程结构

```text
TMSkip/
├── TMSkip.xcodeproj
├── TMSkip/
│   ├── TMSkipApp.swift          # @main：主窗口 + 菜单栏 + AppDelegate
│   ├── AppModel.swift           # 唯一业务编排中心
│   ├── Models/                  # 领域模型 + 内置规则包（RulePackage+Bundled.swift）
│   ├── Services/                # 扫描、自动扫描(FSEvents/定时)、排除、体积、FDA、设置、通知、登录项、忽略存储、窗口路由、扫描日志
│   ├── Views/                   # 手动扫描 / 忽略列表 / 配置 / 关于 / Onboarding / 菜单栏 / 共享组件
│   ├── Resources/               # 资产（AppIcon 等）
│   └── TMSkip.entitlements      # 沙箱关闭（需完全磁盘访问）
├── Config/
│   ├── Signing.xcconfig         # 入库默认签名（ad-hoc）+ 末尾 include Local
│   └── Local.xcconfig.example   # 本机个人签名模板（复制为 Local.xcconfig，已 gitignore）
├── Scripts/
│   ├── make-release.sh          # 打包发布（自动检测 Developer ID 并公证）
│   ├── make-dmg.sh              # universal 构建 + 按架构 lipo 分包 DMG（脚本复用）
│   ├── release-github.sh        # 本地构建 DMG + 绑定 tag + GitHub API 发布 Release
│   ├── dev-run.sh               # 开发循环：构建 + 重启
│   └── make_app_icon.swift      # 生成 AppIcon 图标的辅助脚本
└── TMSkipTests/                 # 单元测试（7 个测试类）
```

## 已拍板决策

1. 扫描根：MVP 默认 `~/`，模型预留多根（M3）
2. 待处理：系统通知 + 菜单栏点标 + App 内队列（通知可关、点标保留）
3. 体积估算：MVP 已接异步计算
4. 产品/工程名：TMSkip
5. 应用包保护：不写入其他应用（`.app`）包内

## 当前 MVP 范围

- [x] SwiftUI 左栏 + 右内容
- [x] FDA Onboarding
- [x] 手动扫描 + 结果确认 + 应用排除
- [x] 体积估算（异步，失败/超时降级）
- [x] 忽略列表：搜索 / 筛选 / 排序 / 状态识别（异常、缺失）+ 撤销 / 重新忽略 / 手动添加
- [x] 扫描配置持久化
- [x] 菜单栏 Extra
- [x] 自动扫描守护（定时 + FSEvents，30s 防抖 / 5min 合流节流，待处理队列）
- [x] 系统通知跳转（点击通知开窗并提升待处理结果）
- [x] Asimov 在线规则同步（手动检查更新 + 启动后/每 24h 静默同步）
- [x] 登录项 SMAppService 真正注册（随设置联动）
- [x] 应用包保护：扫描不进入、应用/撤销/手动添加跳过其他应用包
