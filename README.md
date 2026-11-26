# dsh-release — 把 DeepSeek Harness 打成 Debian 包

从**锁定 tag / commit 的源码**构建 DeepSeek Harness，产出可直接 `apt install` 的
`.deb`。核心约束：

- **源码可追溯**：只接受 tag 或完整 40 位 commit；构建前校验、构建后把 ref/commit
  写进包元数据和 `/usr/share/doc`。
- **服务是用户服务**：安装的是 `systemd --user` 单元 `dsh-web.service`，以安装用户
  身份运行、数据落在该用户的 `~/.dsh`。包里**没有** root 系统服务，验证脚本会显式
  检查这一点。
- **不打包开发树**：用上游自己的 release 路径（pack workspace 闭包 + 重新安装外部
  依赖）生成一个与源码无关的生产安装，体积远小于整个 `node_modules`。

## 快速开始

构建机要求（Ubuntu 24.04 amd64）：

```bash
sudo apt-get install -y git curl ca-certificates build-essential
# Node.js >= 24.9（包不内置 Node，运行时也依赖系统的 nodejs）
curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
sudo apt-get install -y nodejs
node --version                 # >= 24.9.0
corepack enable && pnpm --version   # 需要 pnpm 11.28.5
```

构建（不需要 root，也不需要 fakeroot）：

```bash
make                 # fetch -> build -> stage -> package -> verify
ls -lh dist/
```

产物：

```
dist/deepseek-harness_0.2.2~rc.5-1_amd64.deb
dist/deepseek-harness_0.2.2~rc.5-1_amd64.deb.sha256
```

安装（用 `sudo` 时，维护脚本会自动为这个 sudo 用户 enable + start 用户服务）：

```bash
sudo apt install ./dist/deepseek-harness_0.2.2~rc.5-1_amd64.deb
systemctl --user status dsh-web
dsh-web-url          # 输出带一次性 launch token 的 URL，用浏览器打开
```

如果安装环境里没有可达的 systemd 用户会话（容器、镜像构建等），unit 仍会为安装
用户启用，但服务会在该用户下次登录时启动；脚本会打印提示。

## 版本锁定

`release.conf` 是唯一决定源码版本的地方：

```conf
DSH_REF="dsh-v0.2.2-rc.5"
```

`scripts/fetch-source.sh` 会：

1. 拒绝分支、短 hash、`refs/...` 等可变或歧义 ref；
2. 浅取该 tag/commit，校验 tag 解析出的 commit 与 checkout 一致；
3. 要求工作树干净；
4. 从 `package.json` 读版本，映射为 Debian 版本（`0.2.2-rc.5` → `0.2.2~rc.5`），
   并把 commit 时间作为 `SOURCE_DATE_EPOCH`；
5. 把 ref/commit 写入 `build/source.env`，后续阶段只读这份记录。

包内可交叉核对：

```bash
dpkg-deb -f dist/*.deb X-DSH-Source-Ref X-DSH-Source-Commit
cat /usr/share/doc/deepseek-harness/BUILD-INFO.json
```

一次改 pin（会丢弃 `.work/src` 并重新安装/编译）：

```bash
make DSH_REF=dsh-v0.2.3-alpha.2 DEB_REVISION=1
```

构建使用 `pnpm run build:artifacts --profile official`：发布用品牌配置、无本地 dirty
标记；只产出运行时产物，不跑仓库的测试 typecheck 门禁。

## 为什么服务一定是用户服务

| 项目 | 本包的做法 |
| --- | --- |
| unit 位置 | `/usr/lib/systemd/user/dsh-web.service`（用户单元目录） |
| 启用方式 | `systemctl --user enable`，或为安装用户写 `~/.config/systemd/user/default.target.wants/` 链接 |
| 运行身份 | 用户管理器直接以该用户身份启动；unit 里没有 `User=`/`Group=` |
| 数据 | 该用户的 `~/.dsh`、`~/.config/dsh/web.env` |
| 端口 | 默认只绑 `127.0.0.1:3080`，不暴露到公网 |
| 首次访问 | URL 带一次性 launch token；`dsh-web-url` 从用户 journal 取最近一条，访问成功后浏览器持有 cookie，之后 `http://127.0.0.1:3080` 可直接用 |
| root 系统单元 | 不安装、不启用；`make verify` 会断言包内不存在 `/lib/systemd/system/dsh-web.service` |

默认**不开启 linger**：服务随登录启动、随用户管理器停止（通常注销时停止）。需要
“不登录也常驻”时由用户自己显式开启：

```bash
sudo loginctl enable-linger "$USER"
systemctl --user enable --now dsh-web
```

维护脚本如何找到安装用户：`DSH_DEB_USER` > `SUDO_USER` > `PKEXEC_UID`。用 root
直接 `dpkg -i` 且没有这些变量时不会猜测用户，只安装 unit 并打印手动启用命令。

## 运行配置

```bash
# 环境变量（API key、DSH_HOME 等）
install -d ~/.config/dsh
cat > ~/.config/dsh/web.env <<'EOF'
DEEPSEEK_API_KEY=sk-...
EOF
systemctl --user restart dsh-web

# 改端口/监听地址（不要直接改包内 unit）
systemctl --user edit dsh-web
# [Service]
# ExecStart=
# ExecStart=/usr/bin/dsh web --no-open --host 0.0.0.0 --port 3080

# 日志 / 当前访问地址
journalctl --user -u dsh-web -f
dsh-web-url
```

## 包内布局

```
/usr/bin/dsh                                      启动器（查找 Node >= 24.9）
/usr/bin/dsh-web-url                              打印当前带 token 的 Web UI 地址
/usr/lib/dsh/app/                                 生产安装（packed workspace 闭包）
/usr/lib/systemd/user/dsh-web.service             用户服务
/usr/share/man/man1/dsh.1.gz
/usr/share/doc/deepseek-harness/
    README.Debian.gz  copyright  THIRD_PARTY_NOTICES.md
    BUILD-INFO.json   changelog.Debian.gz  source-commit
```

`/usr/bin/dsh` 支持 `DSH_NODE` 与 `DSH_APP_ROOT` 覆盖，便于在未安装状态下做冒烟
测试；正常运行时使用 `/usr/lib/dsh/app`。

## 命令

```bash
make              # 默认目标：完整构建 + 验证
make fetch        # 取锁定源码，生成 build/source.env
make build        # pnpm install + build:artifacts --profile official
make stage        # 打包 workspace 闭包并组装 rootfs
make package      # dpkg-deb 生成 dist/*.deb
make verify       # 控制字段、布局、unit、脚本语法、真实启动冒烟测试
make clean        # 删 build/ dist/，保留源码和依赖缓存
make distclean    # 再删 .work/（源码、node_modules、pnpm store）
make print-config # 当前 pin 和包名
```

单项脚本可直接运行，环境变量与 Makefile 一致（见 `scripts/common.sh`）。

## 验证做了什么

`make verify` 不安装包，而是解包后检查：

- control 的版本、架构、`nodejs (>= 24.9.0)`、`libc6`、`Conflicts: dsh`、
  `X-DSH-Source-Commit`；
- `/usr/bin/dsh`、Web dist、文档、man page 是否齐全；
- **只存在用户 unit**，没有 root 系统 unit；unit 中没有 `User=`，带 `--no-open`；
- postinst/prerm/postrm 的 `sh -n`；
- 在 `systemd-analyze` 可用时对 unit 做离线校验（部分 rootfs 下只告警）；
- 用解包出的 launcher 运行 `dsh --version`；
- 真实启动 `dsh web --port 0`，验证未带 token 时 401、带 launch token 后拿到
  cookie 并返回 200，再用 cookie 访问干净地址仍为 200；
- 用解包出的 launcher 在受限 PATH（模拟 systemd 用户服务的环境）下启动；
- 同一 rootfs 重复打包得到相同 sha256（本机验证过；文件 mtime 固定为源码 commit 时间）。

构建机没有 systemd 用户会话，因此**没有执行真实的 `dpkg -i` + 用户服务启动**；包的
布局、unit、HTTP 行为、maintainer 脚本流程（用 stub 模拟 `systemctl --user`）都已
验证。正式发布前建议在一台一次性 Ubuntu 24.04 虚拟机上完整走一遍：

```bash
sudo apt install ./deepseek-harness_*.deb
dsh-web-url
systemctl --user status dsh-web
```

已经额外在 `node:24-bookworm-slim` 容器里用真实 `dpkg` 验证过（用等价的 nodejs 包
满足依赖）：安装、以非 root 用户启动 Web、401 → token 303 → cookie 200 的认证流、
postinst 为用户写 enable 链接、`dpkg -r` 停止/禁用并保留 `~/.dsh`，以及与本仓库
冲突的 Ubuntu `dsh` 包被 `Conflicts/Replaces` 正确移除。

## 设计取舍与已知限制

- **不内置 Node**：按需求依赖系统 `nodejs (>= 24.9.0)`。Ubuntu 24.04 官方源只有
  Node 18，所以 README 和 `README.Debian` 都要求先用 NodeSource 装 Node 24。
  好处是 deb 小；代价是安装前必须先处理 Node。
- **包名不是 `dsh`**：Debian/Ubuntu 已有同名的 `dsh`（distributed shell）并占用
  `/usr/bin/dsh`。本包名 `deepseek-harness`，声明 `Conflicts`/`Replaces: dsh`，
  命令仍是 `dsh`。
- **插件管理需要 pnpm**：`dsh plugin` 会把参数转发给 pnpm；pnpm 不随包安装，只列
  为 `Suggests`。基础 Web 使用不需要 pnpm。
- **构建需要网络**：GitHub 取源码，npm registry 安装依赖。生产安装的外部依赖版本
  被钉在 `make build` 时实际安装的版本（overrides），避免二次解析漂移。
- **原生工具链**：完整 native 集需要 `musl-gcc`（静态 Landlock launcher 和 musl
  addon）。`scripts/prepare-musl.sh` 会下载并校验两个固定版本的 Ubuntu 包，解压到
  `.work/musl`，不需要 root；可用 `MUSL_BASE_URL` 指定镜像。
- **仅支持本机架构**：默认 amd64；`aarch64` 需要相应构建机，暂不做交叉编译。
- **用户数据不会被 purge**：`~/.dsh` 与 `~/.config/dsh` 属于用户，卸载/升级都不动。
- **测试门禁**：本流水线只跑 `build:artifacts`，不跑上游完整 `pnpm run build` 的
  test/script typecheck。需要最严格验证时，可在 CI 里另跑上游 `build`。
- **Node 版本**：依赖声明为 `nodejs (>= 24.9.0)`；推荐 Node 24.x（NodeSource
  `setup_24.x`）。原生 addon 是 Node-API，但仍建议与构建机同一大版本，避免其他
  原生依赖的 ABI 差异。

## 目录结构

```
release.conf                 版本/包名/架构唯一配置
Makefile                     make 入口
packaging/                   control 模板、maintainer 脚本、user unit、启动器、man、文档
scripts/fetch-source.sh      锁定源码
scripts/build-source.sh      pnpm install + build:artifacts --profile official
scripts/stage-runtime.mjs    packed workspace 闭包 -> 生产安装
scripts/stage-rootfs.sh      组装 rootfs + control + 文档
scripts/package.sh           dpkg-deb
scripts/verify-deb.sh        解包检查 + Web 冒烟测试
scripts/ci-install-smoke.sh  CI 安装后检查（用户 unit + 认证流）
.github/workflows/build-deb.yml
                             build / install-test / release 工作流
.work/                       源码、node_modules、pnpm store（gitignore）
build/                       rootfs、staging、验证临时目录（gitignore）
dist/                        .deb 与 sha256（gitignore）
```

## GitHub Actions

`.github/workflows/build-deb.yml` 目前只保留 `workflow_dispatch`，便于手动控制构建：

| 运行方式 | 行为 |
| --- | --- |
| 在 `main` 上手动运行 | 构建 + `make verify` + 安装测试 + 上传 14 天 artifact |
| 在 tag `dsh-v*` 上手动运行 | 额外创建/更新 GitHub Release（tag 必须等于 `release.conf` 的 `DSH_REF`） |

如果需要 push/PR 自动构建，在 workflow 的 `on:` 下加回 `push` / `pull_request` 即可；
并发组会按 ref 自动取消旧运行。

CI 使用 `ubuntu-24.04` + Node 24，安装测试会先从 NodeSource 安装 `nodejs` 包（满足
deb 依赖），再用 `dpkg`/apt 安装本包，并运行 `scripts/ci-install-smoke.sh`：

- 断言 unit 只在 `/usr/lib/systemd/user`，不存在 root 系统 unit；
- 断言安装用户的 `default.target.wants` 下已 enable；
- 如果有可用的 systemd 用户会话，通过 `dsh-web-url` 取地址；否则直接运行包内
  ExecStart，并验证 401 → token 303 → cookie 200 的认证流。

输入在编译前校验，配错不会浪费完整构建时间：

- `dsh_ref`：上游 tag 或完整 40 位 commit。`v0.2.2-rc.5` 会自动解析为
  `dsh-v0.2.2-rc.5`；不存在的 tag 直接报错。
- `deb_revision`：只写 Debian revision，例如 `alex1`，最终版本是
  `0.2.2~rc.5-alex1`。不要写 `v0.2.2-alex1`；revision 不能包含 `-`。

手动触发示例：

```bash
# 使用 release.conf 的 pin 和 revision
gh workflow run build-deb.yml

# 指定上游 tag + 本地 revision；tag 的两种写法都可以
gh workflow run build-deb.yml -f dsh_ref=v0.2.2-rc.5 -f deb_revision=alex1
gh workflow run build-deb.yml -f dsh_ref=dsh-v0.2.2-rc.5 -f deb_revision=alex1

# 从 dsh-release 仓库的 tag 触发并发布 Release（tag 需先存在）
gh workflow run build-deb.yml --ref dsh-v0.2.2-rc.5
```

常见失败：

- `tag not found upstream: v0.2.2-rc.5`：上游 tag 带 `dsh-` 前缀。workflow 会自动补；
  直接运行 `make DSH_REF=...` 时需要写完整 tag。
- `deb_revision ... is not valid`：只保留 `alex1` 这类后缀，不要带版本号或 `-`。

tag 构建会强制校验 tag 与 `release.conf` 的 `DSH_REF` 一致；发布使用
`GITHUB_TOKEN` 和 job 级 `contents: write`，不需要额外 secrets。

## 许可证

打包脚本以 MIT 提供；DSH 本身是 MIT，第三方依赖清单随包安装为
`/usr/share/doc/deepseek-harness/THIRD_PARTY_NOTICES.md`。
