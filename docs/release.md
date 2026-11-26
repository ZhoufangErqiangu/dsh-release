# 发布版本方案

本仓库把 DeepSeek Harness 的上游源码打成 Debian 包，并用一套自有版本号发布。
本文说明版本格式、构建号规则、脚本用法，以及 tag 触发 CI 的完整流程。

## 1. 目标

- 发布版本形如 **`v<上游版本>-alex.<N>`**，例如 `v0.2.2-rc.5-alex.1`。
- `<上游版本>` 与 `release.conf` 里的 `DSH_REF` 指向的源码**完全一致**：直接取该
  commit 的 `package.json` 版本，不手写、不猜测。
- `alex.<N>` 是本仓库的构建标识：`alex` 可在 `release.conf` 的
  `DSH_RELEASE_ID` 中修改，`<N>` 是由 tag 推导的、全仓库单调递增的构建号。
- 运行一个脚本即可推进版本并 push tag；GitHub Actions 从 tag 自动构建、验证并发布。

## 2. 版本格式与映射

`scripts/fetch-source.sh` 从锁定 commit 的 `package.json` 读取 `version`，再按下面的
规则生成三个互相一致的版本：

| 位置 | 格式 | 示例 |
| --- | --- | --- |
| `release.conf` 的 `DSH_REF` | 上游 tag 或 40 位 commit | `dsh-v0.2.2-rc.5` |
| 上游 `package.json` 版本 | 上游原样 | `0.2.2-rc.5` |
| 发布 tag | `v<上游版本>-alex.<N>` | `v0.2.2-rc.5-alex.1` |
| Debian 版本 | `<上游版本，- 换成 ~>-alex.<N>` | `0.2.2~rc.5-alex.1` |
| 包文件名 | `<包名>_<Debian 版本>_<架构>.deb` | `deepseek-harness_0.2.2~rc.5-alex.1_amd64.deb` |

稳定版上游（如 `dsh-v0.2.2`）得到的就是最直观的形式：

```text
tag:    v0.2.2-alex.2
deb:    0.2.2-alex.2
file:   deepseek-harness_0.2.2-alex.2_amd64.deb
```

几个不能改的细节：

- **tag 用 `-`，deb 用 `~`**：Debian 的 upstream version 不允许含 `-`（它是
  upstream 与 revision 的分隔符），所以 `0.2.2-rc.5` 写成 `0.2.2~rc.5`。`~` 在
  Debian 排序中低于空串，正好让 rc 排在正式版之前。tag 是给人和 Git 看的，保留
  上游原始写法。
- **deb 版本不带 `v`**：`v` 只属于发布 tag / Release 名称；Debian 版本从数字开始。
- **上游版本不来自 ref 字符串**：`DSH_REF` 可以是 tag，也可以是 40 位 commit。
  唯一可信的版本来源是锁定 commit 里的 `package.json`，避免 tag 名与实际内容不符。
- **`0.2.2` 与 `0.2.2-rc.5` 是两条线**：正式版 `0.2.2-alex.*` 按 Debian 规则排在
  `0.2.2~rc.5-alex.*` 之后，升级方向正确。

## 3. 构建号 `<N>` 规则

- `N` 是**全仓库单调递增**的构建号：`v0.2.2-rc.5-alex.1`、`v0.2.2-rc.5-alex.2`、
  换 pin 后是 `v0.2.3-alex.3`，**不按上游版本重置**。这样任何一次构建都有唯一标识，
  不会因为换上游版本而复用 `alex.1`。
- 计算方式：取本仓库所有 `v*-<id>.<N>` tag 的最大 `N`，加一。脚本在计算前会
  `git fetch --tags origin`，因此多人/多机器发布也不会撞号。
- 如果 tag 已存在（本地或 origin），脚本在改任何文件前就报错退出，不会覆盖已发布版本。
- `release.conf` 的 `DEB_REVISION` 记录**最近一次发布**的值：直接 `make` 复现该
  版本；`scripts/release.sh` 总是自己算下一个值，不依赖手改。
- 需要跳过若干号时用 `--build-number N`，但必须大于现有最大值（只能前进）。

## 4. 脚本

### 4.1 `scripts/release.sh` — 推进版本并推送 tag

默认行为（无参数）：计算下一个版本 → 解析/校验上游 pin 得到上游版本 → 写回
`release.conf` → 提交 → 打 annotated tag → push tag 和分支。

它**不做任何构建**。push 的 tag 就是交给 CI 的发布信号：CI 校验 tag、构建、安装
测试并创建 GitHub Release。

```bash
scripts/release.sh                  # 推进版本 + commit + tag + push，CI 构建
scripts/release.sh --dsh-ref dsh-v0.2.3
                                    # 换 pin，同样只 tag + push
scripts/release.sh --no-push        # 只本地 commit + tag，稍后手动 push
scripts/release.sh --dry-run        # 只解析并打印计划，不改 release.conf / tag
```

用 `--no-push` 之后补推时，不要重跑脚本（它会计算**下一个** `N`），直接 push：

```bash
git push origin v0.2.2-rc.5-alex.1
git push origin main
```

执行顺序：

1. 检查工作树干净、当前分支是 `main`（可用 `RELEASE_BRANCH` 覆盖）、git 身份已配置。
2. 默认 push 时先 fetch origin/main，确认本次提交可以快进推送。
3. `git fetch --tags origin`，从 tag 计算下一个 `N`。
4. 用 `scripts/fetch-source.sh` 解析并校验上游 pin，得到上游版本与 commit
   （只读取版本，不构建）。
5. 推导发布 tag 和 Debian 版本，检查 tag 不在本地/远端。
6. 原子更新 `release.conf`（`DSH_REF` 与 `DEB_REVISION`），提交 `release: v...`。
7. 打 annotated tag。
8. push tag（触发 CI），再 push 分支。tag push 失败时提示只重试 push，不要重跑脚本。

参数：

| 参数 | 作用 |
| --- | --- |
| `--dsh-ref REF` | 把上游 pin 换到 tag 或完整 40 位 commit；成功后写回 `release.conf` |
| `--build-number N` | 强制构建号（必须大于现有最大 N） |
| `--no-push` | 只本地 commit + tag，不 push（之后可手动 push） |
| `--dry-run` | 解析并打印下一个版本，不改 `release.conf`、不 commit、不 tag |
| `-h`, `--help` | 帮助 |

旧参数 `--push`、`--ci`、`--no-build`、`--no-commit`、`--no-tag` 已移除；脚本只做
版本和 tag，构建固定由 CI 完成。

`RELEASE_BRANCH` 可覆盖发布分支。`DSH_RELEASE_ID` 只能改 `release.conf`：workflow 的
tag 过滤器和 `check-release-tag.sh` 都从该文件读取它，用环境变量覆盖会被拒绝，
避免本地造出 CI 不认识的 tag。

### 4.2 `scripts/check-release-tag.sh` — 校验 tag 与源码/配置一致

CI 在构建前调用；也可手动在本地验证一个 tag：

```bash
make fetch
scripts/check-release-tag.sh v0.2.2-rc.5-alex.1
```

它要求同时满足：

- tag 符合 `v<上游版本>-<id>.<N>`；
- tag 里的上游版本 == `build/source.env` 的 `DSH_VERSION`（即 pin 的真实版本）；
- `release.conf` 记录的 `DEB_REVISION` == tag 的 `<id>.<N>`；
- `build/source.env` 生成的 `DSH_RELEASE_TAG`、`DEB_REVISION`、`DEB_FULL_VERSION`
  与 tag 一致；
- tag 确实指向当前 HEAD（CI checkout 的就是 tag）。

成功后按 `GITHUB_OUTPUT` 格式输出 `release_tag`、`release_build_number`、
`release_revision`、`release_deb_version`。

### 4.3 `scripts/release-manifest.sh` — 机器可读的产物清单

`package.sh` 打包后自动生成 `dist/release.json`，把发布 tag、构建号、上游
ref/commit/version、deb 版本、文件名和 sha256 放在一个文件里，供 Release、
镜像同步或部署脚本读取：

```json
{
  "schemaVersion": 1,
  "releaseTag": "v0.2.2-rc.5-alex.1",
  "releaseVersion": "0.2.2-rc.5-alex.1",
  "buildNumber": 1,
  "revision": "alex.1",
  "debVersion": "0.2.2~rc.5-alex.1",
  "package": "deepseek-harness",
  "architecture": "amd64",
  "file": "deepseek-harness_0.2.2~rc.5-alex.1_amd64.deb",
  "sha256": "…",
  "source": {
    "ref": "dsh-v0.2.2-rc.5",
    "commit": "9c2670d3bce5275e0d1610272958121af87787bb",
    "version": "0.2.2-rc.5"
  }
}
```

`BUILD-INFO.json`（安装到 `/usr/share/doc/deepseek-harness/`）也新增了
`release` 字段，安装后可直接核对发布版本。

## 5. CI：tag 自动构建与发布

`.github/workflows/build-deb.yml` 两种入口：

| 触发 | 行为 |
| --- | --- |
| push tag `v*-alex.*` | 校验 tag → 构建 + `make verify` → 安装测试 → 创建/更新 GitHub Release |
| 手动 `workflow_dispatch` | 测试构建；上传 14 天 artifact；不发布 Release |
| 在 tag 上手动 run | 与 tag push 相同（可用来重跑失败任务） |

tag 构建的关键约束：

1. 不接受 `dsh_ref` / `deb_revision` 输入覆盖，版本只由 tag + `release.conf` 决定；
2. 构建前先 `scripts/fetch-source.sh`，再用 `scripts/check-release-tag.sh` 校验；
3. 构建后再校验一次：`dpkg-deb` 的 `Version`、`dist/release.json` 的 `releaseTag`
   必须与 tag 一致；
4. Release 资产为 `.deb`、`.sha256`、`release.json`。

发布权限使用 job 级 `contents: write` 和 `GITHUB_TOKEN`，不需要额外 secret。
如果改过 `DSH_RELEASE_ID`，记得同步 workflow 里 `on.push.tags` 的
`v*-alex.*` 过滤器。

## 6. 常见操作

### 常规发布（只推 tag，CI 构建）

```bash
scripts/release.sh
```

### 上游升级

```bash
scripts/release.sh --dsh-ref dsh-v0.2.3
# 版本变成 v0.2.3-alex.<下一个N>，deb 为 0.2.3-alex.<N>
```

如果新 pin 还没验证过构建，可以先在本地试构建（需要完整构建工具链和
pnpm 11.28.5），确认后再用脚本发版：

```bash
make DSH_REF=dsh-v0.2.3 DEB_REVISION=alex.<N>
scripts/release.sh --dsh-ref dsh-v0.2.3
```

### 只本机构建、不发布

```bash
make                     # 复现 release.conf 记录的最新版本
make DSH_REF=... DEB_REVISION=...
```

`scripts/release.sh` 不负责构建，也不产生 `dist/` 里的包。

### 预演下一个版本号

```bash
scripts/release.sh --dry-run
```

它会实际解析上游 pin（有缓存时不访问网络），可能刷新 `.work/` 里的源码缓存和
`build/source.env`，但不会修改受版本控制的文件、不会创建 tag。

### CI 失败后重试

- tag 已经 push：用 `workflow_dispatch` 在该 tag 上重跑，或 `gh run rerun <run-id>`；
- 还没 push（`--no-push` 或 push 失败）：commit/tag 已在本地，按提示只重试 push
  （`git push origin refs/tags/<tag>`、`git push origin main`），**不要重跑脚本**，
  否则本地已有 tag 会让它算到下一个 `N`；
- **不要移动或删除已发布的 tag**。若已发布版本有缺陷，修复后发下一个 `N`，
  让版本历史保持单调可追溯。

### 回滚

已安装的机器可以直接降级到旧 deb：

```bash
sudo apt install ./deepseek-harness_0.2.2~rc.5-alex.1_amd64.deb
```

Debian 会按版本比较；`~rc` 排在正式版之前，`alex.10` 排在 `alex.9` 之后。

## 7. 设计取舍

- **构建号全局递增，而不是每个上游版本从 1 开始**：构建标识要求唯一，全局递增值
  更不容易误用；代价是切到新上游后 `alex.N` 不一定从 1 开始（如 `v0.2.3-alex.4`），
  但上游版本本身已经表达了兼容线。
- **tag 保留上游的 `-rc`，deb 用 `~rc`**：两边各自符合自己的生态规则，且语义一致。
- **版本只在 `release.conf` 记录一次**：上游版本来自源码，构建号来自 tag；
  两者都不允许手写发布版本字符串，避免 tag、deb、文档三处漂移。
- **脚本只做版本和 tag，构建固定交给 CI**：本地不需要 pnpm、musl 或 dpkg 工具链
  就能发版；push 的 tag 是唯一的交接点，CI 从该 commit 复现构建。
- **默认 push**：版本推进和 tag 只有发布出去才有意义，默认一步完成；需要先检查时
  用 `--dry-run`，需要离线准备时用 `--no-push`。
- **tag 不可变**：CI 只接受由脚本生成的 tag，且 tag 必须与 `release.conf` 和源码
  `package.json` 完全一致，避免出现无法复现的发布。
