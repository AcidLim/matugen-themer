# Matugen Themer

Noctalia v5 插件：壁纸换掉时自动用 [matugen](https://github.com/InioX/matugen) 重新生成整套配色。

它一次性接替了工作区里原本三套脚本的活：

| 原脚本 | 做的事 | 现在 |
| --- | --- | --- |
| `matugen.sh` + `[hooks] wallpaper_changed` | 换壁纸时跑 matugen | `themer` 服务自己监听壁纸路径 |
| `mpv/mpv-hook.lua` | mpv 载入视频时 ffmpeg 取帧 → 设成 Noctalia 壁纸 | 服务读 mpvpaper 的分配文件 → 取帧 → 取色 |
| `mpv/mpvpaper-sync.sh` | inotify 盯 `assignments.json`，取帧并设壁纸 | 同上，但不用 inotify、不用 jq |

```
matugen-themer/
├── plugin.toml            # 清单：条目 + 设置项 + 翻译键
├── util.luau              # 设置读取、~ 展开、哈希
├── video.luau             # 视频壁纸：分配文件解析、ffmpeg 取帧、帧缓存
├── matugen.luau           # 共用模块：拼命令行、跑进程、防并发、取帧后交接
├── themer.luau            # [[service]] 后台监听
├── refresh.luau           # [[shortcut]] 控制中心手动刷新磁贴
└── translations/
    ├── en.json
    └── zh-Hans.json
```

## 与旧脚本的对应关系

| 旧做法 | 现在的实现 |
| --- | --- |
| `noctalia msg wallpaper-get` | `noctalia.wallpaperPath(connector)`，逐输出在进程内读 |
| `config.json` + `jq` | 同名设置项，在 设置 → 插件 → Matugen Themer 里改 |
| `~/.local/state/noctalia/matugen.log` | 写 Noctalia 日志（`journalctl --user -u noctalia`） |
| `ffmpeg -ss 1 -vframes 1` + md5 文件名 | 同一套 ffmpeg 取帧，缓存键换成 路径+mtime+尺寸 |
| `inotifywait` 盯 `assignments.json` | 每个 tick 一次 `stat`，mtime 变了才重新解析 |

### 为什么还是轮询

v5 的插件 API **没有**壁纸变更事件：`onOutputsChanged()` 只在输出集合/几何变化时触发，`wallpaperPath()` 只是查询。所以监听只能用服务的 `update()` 定时比对，默认 1 秒（可调 250–10000 毫秒），每次开销只是几次进程内取值 + 一次 stat。

## 视频壁纸

matugen 只能读静态图片，所以视频壁纸会先用 ffmpeg 取一帧：

```
ffmpeg -nostdin -y -loglevel error -ss <frame_offset> -i <video> \
       -frames:v 1 -vf scale=<frame_width>:-2 -q:v 2 <cache>/<hash>.jpg
```

几个和原脚本不同的地方：

- **帧源**：优先读 mpvpaper 插件的 `assignments.json`（`$XDG_STATE_HOME/noctalia/mpvpaper/assignments.json`）。因为视频接管某个输出后，Noctalia 自己的壁纸路径还停在上一次的静态图上——只盯 `wallpaperPath` 是发现不了视频换了的。没有分配文件时退回 `wallpaperPath`，所以「直接把视频路径设成壁纸」也能用。
- **缓存失效**：键是 `路径 + mtime + 尺寸 + 取帧位置 + 取帧宽度`，换视频、重新录制同一个文件都会重新取帧，不会拿到旧画面。缓存目录是 `pluginDataDir()/frames/`，超过 24 个帧时裁到 12 个（正在被当成壁纸用的帧不会被删）。
- **取帧失败兜底**：视频比 `frame_offset` 短时，自动退回第 0 秒再试一次。
- **交接给外壳**：`shell_wallpaper = true` 时会把这帧 `setWallpaper` 给对应输出，让 Noctalia 自己的配色（主题来源 = 壁纸）也跟着视频走——就是原来 `mpv-hook.lua` / `mpvpaper-sync.sh` 干的事。默认关闭，因为它会覆盖该输出原本配置的壁纸路径。

> 如果你原来装了 `mpv-hook.lua` 或跑着 `mpvpaper-sync.sh`，打开 `shell_wallpaper` 之后就可以把它们删掉，否则同一件事会做两遍。

## 安装

目录名要和 id 里 `/` 后面的部分一致（`matugen-themer`）。

```bash
ln -s /path/to/matugen-themer ~/.local/share/noctalia/plugins/matugen-themer

# 或者把所在目录加成一个 path 源
noctalia msg plugins source add dev path ~/.local/share/noctalia/plugins

noctalia msg plugins enable matugen-noctalia/matugen-themer
```

启用后 `.luau` 改动会热重载，`plugin.toml` 改动在下次配置重载时生效。别忘了把旧的 hook 区块从配置里删掉，否则换壁纸会各跑一次：

```toml
[hooks]
wallpaper_changed = "bash ~/.config/noctalia/scripts/matugen/matugen.sh"
```

## 设置项

| 键 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `matugen_path` | string | `matugen` | 命令名或完整路径（`~` 会展开） |
| `config_file` | file | 空 | 传 `--config`，留空用 matugen 默认配置 |
| `type` | select | `scheme-tonal-spot` | 9 种方案算法 |
| `mode` | select | `dark` | `dark` / `light` / `auto`（跟随外壳明暗） |
| `prefer` | select | `saturation` | 源色偏好 |
| `source_index` | int | 0 | 取第几个提取色（0–4） |
| `contrast` | double | 0.0 | 对比度（-1–1） |
| `video_mode` | select | `auto` | `auto` 取帧取色 / `off` 忽略视频 |
| `shell_wallpaper` | bool | false | 把取帧结果设成该输出的壁纸，让外壳配色跟随 |
| `ffmpeg_path` | string | `ffmpeg` | 高级；ffmpeg 命令名或路径 |
| `frame_offset` | double | 1.0 | 高级；从第几秒取帧 |
| `frame_width` | int | 1280 | 高级；取帧缩放宽度，0 = 原尺寸 |
| `assignments_file` | file | 空 | 高级；留空自动用 mpvpaper 的 `assignments.json` |
| `extra_args` | string_list | 空 | 高级；追加参数，一行一个 |
| `interval` | int | 1000 | 高级；轮询间隔毫秒 |
| `run_on_start` | bool | true | 高级；插件加载时先按当前壁纸生成一次 |
| `notify_errors` | bool | true | 高级；失败弹通知，失败信息始终写日志 |

`mode = auto` 会读 `noctalia.isDarkMode()`：外壳从深色切到浅色也会触发一次重新生成。

## 行为细节

- **多显示器**：每个输出的「当前画面来源」单独记录（视频或静态图），谁变了就用谁生成——matugen 一次只产出一套配色，最后一个变化者生效。
- **不会重复跑**：正在运行时新请求会被合并成一次，等当前进程结束后再跑；锁带 120 秒兜底，进程异常退出不会把插件卡死。
- **取帧串行**：取帧和 matugen 共用同一把锁，不会出现两路同时写同一批模板文件。
- **设置改了立刻生效**：实现了 `onConfigChanged()`，Noctalia 会保留服务现场并重新生成，而不是重启服务后一直等到下次换壁纸。
- **壁纸源是文件夹时**（Noctalia 轮播壁纸），直接跳过并记日志，不会每 tick 报错。
- **手动刷新**：控制中心磁贴 `Matugen 配色`，左键重新生成，右键打开插件设置，运行中变灰。

## IPC

```bash
# 手动重新生成（视频会自动取帧）
noctalia msg plugin matugen-noctalia/matugen-themer:themer all refresh

# 查看最近一次状态（会显示 视频 -> 帧 的路径）
noctalia msg plugin matugen-noctalia/matugen-themer:themer all status

# 磁贴也可以直接触发
noctalia msg plugin matugen-noctalia/matugen-themer:refresh all refresh
```

## 排错

1. 日志里 `matugen: failed (exit ...)`，通知里有 stderr 摘要：先手动跑一次
   `matugen image /path/to/wallpaper.jpg --type scheme-tonal-spot --mode dark`，确认模板路径和写权限没问题。
2. `toast: 无法从视频中取帧`：多半是 ffmpeg 读不了这个编码，先手动试
   `ffmpeg -ss 1 -i 视频 -frames:v 1 /tmp/t.jpg`；也可以把 `frame_offset` 调小。
3. 通知提示找不到 matugen / ffmpeg：把路径填成绝对路径（例如 `/usr/bin/matugen`），
   Nix profile 和系统级安装的路径不一定在 GUI 会话的 `$PATH` 里。
4. 换了壁纸没反应：确认 `interval` 没被调得很大，并且壁纸确实换了路径（同一路径覆盖内容不会触发，此时用磁贴手动刷新）。
5. 视频壁纸取色了但外壳配色没变：这是 `shell_wallpaper` 的开关，或者外壳的主题来源本来就不是「壁纸」。
