# Ads Remover — 视频广告自动切除工具

基于 FFmpeg 的无损视频广告切除工具，支持 Windows / Linux / macOS / Android。

## 功能概览

| 模式 | 说明 | 适用场景 |
|------|------|----------|
| **分辨率突变检测** | 自动分析视频中分辨率变化的片段（如 1080p→480p→1080p），切除低分辨率片段 | 电视录制、混流视频 |
| **手动选取样本** | 预览视频，手动选取广告起止时间，存入样本库 | 简单快速切除已知广告 |
| **数据库指纹匹配** | 用样本库中的帧指纹（pHash）自动扫描视频，匹配到相同广告后切除 | 批量处理固定片头/尾广告 |

## 快速开始

### 1. 准备 FFmpeg

> `ffmpeg_bins/` 目录未包含在仓库中，请手动下载 ffmpeg/ffprobe 后按以下结构放置：

下载 ffmpeg 和 ffprobe，放到 `ffmpeg_bins/你的系统/` 目录下：

```
ads_remover/
└── ffmpeg_bins/
    ├── win/          ← Windows
    │   ├── ffmpeg.exe
    │   └── ffprobe.exe
    ├── linux/        ← Linux
    │   ├── ffmpeg
    │   └── ffprobe
    └── macos/        ← macOS
        ├── ffmpeg
        └── ffprobe
```

**下载地址：**
- **Windows**：[ffmpeg-master-latest-win64-gpl.zip](https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip)（`bin/` 里的两个 exe）
- **Linux**：[ffmpeg-release-amd64-static.tar.xz](https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz)
- **macOS**：[ffmpeg-macos-arm64.zip](https://evermeet.cx/ffmpeg/)

> 如果系统已安装 FFmpeg 且加入了 PATH，程序会自动找到，可以跳过此步。

### 2. 运行程序

**Windows 用户**：双击 `ads_remover.exe`（打包后）或运行 `flutter run -d windows`

**Android 用户**：安装 APK 后打开，FFmpeg 已内置

## 使用流程

> 分辨率/数据库模式支持**单文件**和**批量处理**两种方式：
> - **单文件**：点击卡片进入，选择视频文件后处理
> - **批量**：**长按**首页卡片直接选文件夹，或在处理页点「选择文件夹」
> - 批量模式下点击 `N/M` 按钮可查看/勾选具体文件列表

### 模式一：分辨率突变检测

```
单文件：选择视频 → [开始处理] → 自动分析 → 自动切除 → 输出到 clean/
批量：  选择文件夹 → 点击文件列表 → [开始批量处理] → 逐个处理
```

1. 点击「选择文件」或「选择文件夹」
2. 选择扫描模式（默认**混合模式**）：
   - **混合**：先做关键帧扫描定位突变点，再对突变区域做全帧精确扫描，兼顾速度与精度
   - **全帧**：逐帧扫描，精度最高但速度最慢
   - **关键帧**：只扫 I 帧，速度最快但边界可能不够精确
3. 点击「开始处理」或「开始批量处理」
4. 处理完成后在 `clean/` 目录下找到输出视频（`clean_` 前缀 = 有广告被切除，`not_detected_` 前缀 = 未检测到广告）

### 模式二：手动选取样本

```
选择视频 → 选取广告区间 → 设开始/结束 → [确定] → 存入样本库
```

1. 点击「选择视频文件」
2. 点击「选取广告区间」
3. 拖动滑块或直接输入时间（时:分:秒）
4. 点击「设为开始」和「设为结束」
5. 点击「确定」存入样本库

### 模式三：数据库指纹匹配

```
单文件：选择视频 → [开始检测] → 审核结果 → [裁剪] → 输出到 clean/
批量：  选择文件夹 → [开始批量处理] → 检测+裁剪一步完成
```

**步骤 1 — 检测**：扫描视频，自动匹配样本库中的广告

**步骤 2 — 审核**（仅单文件模式）：
- 显示每个检测到的候选广告
- 缩略图从左到右：视频开头帧 → 视频结尾帧 → 样本开头帧 → 样本结尾帧
- ✅ 图标 = 结尾帧匹配，❌ = 不匹配（默认不勾选）
- 点击缩略图可放大查看
- 勾选确认需要切除的广告，去掉误判的

**步骤 3 — 裁剪**：只切除已确认的广告段

> **可选的检测范围**：在「检测时段」输入起止时间（HH:MM:SS），只扫描视频的某一段。

## 输出文件结构

处理后的文件统一放在视频旁边的 `clean/` 目录下：

```
视频所在目录/
└── clean/                    ← 输出目录名可自定义（默认 clean）
    ├── clean_视频名.mp4       ← 检测到广告并裁剪后的视频
    ├── not_detected_视频名.mp4 ← 未检测到广告，原始视频原样复制
    └── json/
        ├── detections.json         ← 数据库检测结果（可再次导入审核）
        └── 视频名_ads_report.json  ← 分析报告（含切除的详细区间）
```

## 样本数据库

首次使用会创建 `ad_fingerprints.db`（SQLite 数据库），存放在程序运行目录。

**手动添加样本**：使用「手动选取样本」模式，预览视频并选定广告的起止时间。

**共享数据库**：在不同的视频文件之间，数据库是全局共享的。手动添加的样本会持续积累。

> 如果你有 Python 旧版的 `ad_fingerprints.db` 和 `sample/` 目录，可以直接复制过来使用。

## 界面说明

### 主页
三种模式选择卡片 + 右上角批量处理和指纹库入口

### 单文件处理页
- **顶部**：显示已选视频文件和时长
- **扫描模式**：分辨率模式可选混合/全帧/关键帧三种扫描策略（默认混合），数据库模式可选检测时段
- **输出目录**：可自定义输出目录名称（默认 `clean`）
- **进度显示**：实时进度条 + 帧处理计数
- **日志面板**：显示处理过程中的详细信息
- **结果**：处理完成后显示输出路径和报告路径

### 广告指纹库管理
查看所有已存储的广告样本，可删除不需要的样本。

## 常见问题

**Q: 切出来的视频不完整/画质变差？**
分辨率模式采用 `-c copy` 无损截取，不重新编码，画质无损。如果检测结果不理想，尝试切换扫描模式（推荐先用**混合**模式，若边界不准再换**全帧**）。

**Q: 数据库匹配没找到已知广告？**
- 样本库中是否已有该广告的样本？
- 尝试调整检测时段范围
- 检查审核页面，看是否有未确认的候选

**Q: 程序卡住了/没反应？**
- 长视频需要较多时间分析，进度条会持续更新
- 如果长时间无响应，可点击「中断」重新尝试
- 中断后可以重新开始，无需关闭程序

**Q: 如何自定义输出目录？**
在视频处理页面的「输出目录」输入框中输入自定义名称，视频会输出到 `自定义名称/` 目录下。

**Q: FFmpeg 报错/找不到？**
确认 `ffmpeg_bins/你的系统/` 目录下有 ffmpeg 和 ffprobe 可执行文件。

## 技术特点

- **纯原生计算**：pHash 的 DCT 计算用纯 Dart 实现，无需 Python 或 OpenCV
- **后台 Isolate**：哈希匹配跑在独立线程，UI 不卡顿
- **流式处理**：FFmpeg pipe 边读取边处理，不占满内存
- **批量处理**：支持批量处理多个视频，实时显示日志
- **审核机制**：数据库模式支持检测→审核→裁剪分步操作

---

# For Developers

## 技术栈

| 层 | 技术 |
|----|------|
| UI 框架 | Flutter 3.16+ / Dart 3.0+ |
| 状态管理 | Provider (ChangeNotifier) |
| 桌面 FFmpeg | `dart:io` Process 启动 ffmpeg/ffprobe |
| Android FFmpeg | `ffmpeg_kit_flutter_min_gpl` |
| 数据库 | SQLite via `sqflite` / `sqflite_ffi` |
| 图像处理 | 纯 Dart pHash（DCT + 余弦表预计算） |
| 并行计算 | `dart:isolate` 后台 Isolate |
| 文件选择 | `file_selector` / `image_picker` |

## 项目结构

```
lib/
├── main.dart                          # 入口：自定义 Binding 禁用语义树（防 Win AXTree 报错）
├── models/
│   ├── ad_interval.dart               # AdInterval, RemovedSegment
│   ├── ad_sample.dart                 # 广告样本（帧哈希 + 时长）
│   └── ad_detection_result.dart       # 检测结果（toJson/fromJson）
├── db/
│   └── database.dart                  # SQLite 兼容层（桌面 FFI / 移动端原生）
├── core/
│   ├── phash.dart                     # pHash (DCT 32×32 → 取前 8×8 系数 → 中位数阈值 → 64bit)
│   ├── video_processor.dart           # FFmpeg/FFprobe 跨平台封装（获取时长、帧数、分辨率分析、帧提取、裁剪拼接）
│   ├── resolution_analyzer.dart       # 分辨率分析（帧分组 → 找主分辨率 → 构建区间 + 去重叠合并）
│   └── ad_detector.dart               # 数据库匹配（Isolate worker：流式接收帧 → DCT → hash → 比对样本）
└── ui/
    ├── processing_state.dart          # ChangeNotifier 状态中心（进度/日志/并行数/检测结果/裁剪）
    ├── home_page.dart                 # 首页（三种模式选择卡片）
    ├── single_page.dart               # 单文件处理页
    ├── batch_page.dart                # 批量处理页
    ├── time_selector_page.dart        # 手动选取时间段（滑块 + 数字输入 + 帧预览）
    ├── review_page.dart               # 审核页（缩略图对比 + 尾部匹配指示 + 勾选确认）
    └── db_manager_page.dart           # 广告指纹库管理

ffmpeg_bins/                           # FFmpeg 二进制（按平台分目录，自动搜索）
  ├── win/   ffmpeg.exe + ffprobe.exe
  ├── linux/ ffmpeg + ffprobe
  └── macos/ ffmpeg + ffprobe

ad_fingerprints.db                     # SQLite 数据库（自动创建）
sample/                                # 样本帧图片（temp_start_xxx.jpg / temp_end_xxx.jpg）
```

## 架构设计

### 分辨率检测流程

三种扫描模式：
- **全帧**：直接 ffprobe 全帧扫描 → parse → segment → buildIntervals
- **关键帧**：同全帧，但只扫 I 帧（`-skip_frame nokey`），速度快但边界粗
- **混合**（默认）：先关键帧扫描定位突变段 → 对突变区域做全帧精确扫描 → 合并 CSV → 走标准 pipeline

```
视频文件
  │
  ├─[全帧/关键帧] ffprobe -show_frames (流式读取 pts_time,width,height)
  │                ↓
  │                parseFfprobeOutput → List<FrameInfo>
  │
  ├─[混合] Phase 1: 关键帧扫描 → 突变段定位
  │         Phase 2: 全帧扫描突变区域 → 合并 CSV
  │         ↓
  │         parseFfprobeOutput → List<FrameInfo>
  │
  ▼
segmentByResolution → List<Segment>          ← 按分辨率变化分段
  │
  ▼
findMainResolution → (width, height)         ← 持续时间最长的分辨率
  │
  ▼
buildIntervals → (keep, removed)            ← 非主分辨率 = 广告候补
  │
  ▼ ffmpeg -c copy (无损截取)
trimAndConcat → clean_视频.mp4
```

### 数据库匹配流程

```
                    Main Isolate                          Worker Isolate
                  ─────────────                        ───────────────
视频文件 → ffmpeg -r FPS 流式输出 rawvideo
                  │
                  ▼ 逐帧读取 stdout
          缓冲 100 帧一批 ──SendPort──→ 接收帧批次
                  │                      │
                  │                      ▼ 逐帧：
                  │                    Phash.compute()
                  │                    DCT 32×32 → 前 8×8 系数
                  │                      │ 余弦表预计算（静态常量）
                  │                      │ Float64x4 内循环展开 4 路
                  │                      ▼ 与样本 start 哈希比对
                  │                    ←─SendPort── 匹配通知
                  │                      │
                  │  onMatch → appendLog  │ 每 50 帧报告进度
                  │  onProgress ←─SendPort── frameIdx
                  │
          全部帧发送完毕 → 'done'
                  │
                  ▼ ←─SendPort── Map<sampleName, List<startTime>>
           结束帧验证（偏移 -2.0 ~ +2.0s 逐帧 hash 比对）
                  │
                  ▼
            AdDetectionResult 列表 → 保存帧 JPEG → detections.json
                  │
                  ▼
            ReviewPage 审核 → 确认/取消 → 裁剪
```

### DCT 优化历程

| 版本 | 实现 | 每帧耗时 | 提速 |
|------|------|---------|------|
| 原始 | 四重循环 + `math.cos` 每轮重算 | ~100ms | 1× |
| V2 | 余弦表预计算为静态常量 | ~1ms | 100× |
| V3 | 外循环从 32² 缩至 8²（只算 hash 所需系数）| ~0.06ms | 16× |
| V4 | 内层 Y 循环 4 路手动展开 | ~0.04ms | 25× |

### 取消/中断机制

```
UI 点击中断
  │
  ▼
ProcessingState.cancel()
  │
  ├─▶ VideoProcessor.cancelCurrentProcess()
  │     │
  │     ├─ 杀死 _currentProcess（单进程 ffprobe）
  │     └─ 杀死 _processes[ ] 列表（并行 ffmpeg 进程）
  │
  ├─▶ status = ProcessStatus.cancelled
  └─▶ notifyListeners() → UI 显示 "已中断"
         │
         ▼  Worker Isolate（仍在运行）
         │
         ├─▶ 检测到 isCancelled → 进程被 kill → stream 结束 → catch
         ├─▶ catch → workerPort.send('cancel') → Worker 返回部分结果
         └─▶ mainPort.close() → Worker 的 _trySend 捕获异常 → cmd.close()
```

## 开发环境搭建

```bash
# 前提
flutter --version           # 需 3.16+
dart --version              # 需 3.0+

# 安装依赖
cd ads_remover
flutter pub get

# 生成平台工程（首次）
flutter create --platforms=windows,android .

# 运行
flutter run -d windows      # Windows 桌面
flutter run -d android      # Android
```

### Android 额外设置

`ffmpeg_kit_flutter_min_gpl` 会自动打包 FFmpeg，无需外部二进制。

### Windows 编译注意事项

`Float64x4` 在 Windows AOT 下不可用，已改用 4 路循环展开替代。

## 数据库表结构

```sql
CREATE TABLE ad_samples (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  name            TEXT NOT NULL,              -- 样本名称
  video_path      TEXT,                        -- 来源视频路径（参考）
  start_frame_hash TEXT NOT NULL,              -- 开始帧 pHash (64 bit hex)
  end_frame_hash   TEXT NOT NULL,              -- 结束帧 pHash (64 bit hex)
  duration         REAL NOT NULL,              -- 广告时长 (秒)
  created_at       TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

样本帧图片存放在 `sample/` 目录：`temp_start_{name}.jpg`、`temp_end_{name}.jpg`。

## FFmpeg 命令参考

| 用途 | 命令 |
|------|------|
| 分辨率分析 | `ffprobe -v quiet -select_streams v:0 -show_frames -show_entries frame=pts_time,width,height -of csv=p=0 [-skip_frame nokey] -i video` |
| 批量帧提取 | `ffmpeg -v error -ss start -to end -i video -r fps -f rawvideo -pix_fmt gray -s 32x32 -` |
| 单帧 JPEG | `ffmpeg -y -ss time -i video -vframes 1 -q:v 2 out.jpg` |
| 单帧 pHash | `ffmpeg -y -ss time -i video -vframes 1 -f rawvideo -pix_fmt gray -s 32x32 out.gray` |
| 无损裁剪 | `ffmpeg -y -ss start -to end -i video -c copy -avoid_negative_ts make_zero out.mp4` |
| 拼接 | `ffmpeg -y -f concat -safe 0 -i concat.txt -c copy out.mp4` |

## 依赖管理

```yaml
dependencies:
  provider: ^6.0.0           # 状态管理
  sqflite: ^2.3.0            # Android/iOS SQLite
  sqflite_common_ffi: ^2.3.0 # 桌面端 SQLite
  path_provider: ^2.1.0      # 路径获取
  path: ^1.9.0               # 路径操作
  file_selector: ^1.0.0      # 桌面文件选择
  image_picker: ^1.0.0       # 移动端文件选择
  ffmpeg_kit_flutter_min_gpl: ^6.0.3  # Android FFmpeg
```

## 许可证

本项目基于 MIT 许可证。FFmpeg 使用 GPL 许可证。
