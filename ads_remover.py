#!/usr/bin/env python3
"""
纯 FFmpeg 实现：自动下载 + 分析分辨率变化 + 无损剪辑广告
不依赖 OpenCV，保留原始编码、音频、字幕
"""
# conda activate pytorch_cpu
# cd D:\0_cxhfiles\pyProject\common\funny_tools
# pyinstaller --onefile --noconfirm --name "ads_remover" ads_remover.py

import io
import json
import os
import platform
import pprint
import re
import shutil
import sqlite3
import subprocess
import tempfile
import threading
import time
import tkinter as tk
import traceback
from pathlib import Path
from queue import Queue
from tkinter import ttk, messagebox

import cv2
import imagehash
import numpy as np
import requests
from PIL import Image
from PIL import ImageTk  # 需要 pip install pillow
from tqdm import tqdm

# 配置文件的路径
CONFIG_FILE_PATH = 'config.json'


def load_or_create_config():
    """
    加载或创建配置文件。
    如果文件不存在，则创建并写入默认配置。
    最后返回配置内容的字典。
    """
    if not os.path.exists(CONFIG_FILE_PATH):
        default_config = {
            "fps": 25,
            "threads": 8,
            "queue_size": 300,
            "resize": [1280, 720],
            'threshold': 5,
            'skip_frame': 'nokey'
        }
        with open(CONFIG_FILE_PATH, 'w', encoding='utf-8') as f:
            json.dump(default_config, f, ensure_ascii=False, indent=4)

    with open(CONFIG_FILE_PATH, 'r', encoding='utf-8') as f:
        config = json.load(f)

    return config


my_config = load_or_create_config()

print(f'当前配置: \n{pprint.pformat(my_config, indent=4)}')

DB_PATH = "ad_fingerprints.db"
SAMPLE_DIR = "sample"


def parse_time(time_input):
    """
    将时间转换为秒数
    支持: 1. 数字 (120), 2. 字符串秒 ("120.5"), 3. 时间格式 ("04:58", "01:04:58")
    """
    if isinstance(time_input, (int, float)):
        return float(time_input)

    if isinstance(time_input, str):
        # 检查是否为 HH:MM:SS 或 MM:SS 格式
        # 支持匹配: 4:58, 04:58, 1:04:58, 01:04:58
        match = re.match(r'(?:(\d+):)?(\d{1,2}):(\d{2})', time_input)
        if match:
            groups = match.groups()
            # 处理 4:58 (只有分钟和秒) 和 1:04:58 (时分秒) 的情况
            # 如果第一组是None，说明没有小时
            h = int(groups[0]) if groups[0] is not None else 0
            m = int(groups[1])
            s = int(groups[2])
            return h * 3600 + m * 60 + s

        # 如果不是时间格式，尝试直接转浮点数 (如 "120.5")
        try:
            return float(time_input)
        except ValueError:
            pass

    raise ValueError(f"无法解析时间格式: {time_input}")


def init_db():
    """初始化数据库，存储广告片段的哈希值"""
    with sqlite3.connect(DB_PATH) as conn:
        conn.execute('''
            CREATE TABLE IF NOT EXISTS ad_samples (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,  -- 广告名称，如 "伊利纯牛奶"
                video_path TEXT,     -- 样本视频路径
                start_frame_hash TEXT, -- 开头帧哈希 (pHash)
                end_frame_hash TEXT,   -- 结尾帧哈希 (pHash)
                duration REAL,         -- 广告时长，用于跳过
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        ''')


def add_ad_sample(name, video_path, start_time, end_time):
    """
    手动添加广告样本
    注意：这里需要调用 FFmpeg 提取关键帧生成哈希
    """
    timestamp = time.strftime("%Y%m%d_%H%M%S")  # 年月日_时分秒格式
    name = f"{timestamp}_{name}"
    start_time = parse_time(str(start_time))
    end_time = parse_time(str(end_time))
    video_path = str(video_path)
    os.makedirs(SAMPLE_DIR, exist_ok=True)
    # 1. 使用 FFmpeg 提取开始和结束时间的画面路径
    start_img = f"{SAMPLE_DIR}/temp_start_{name}.jpg"
    end_img = f"{SAMPLE_DIR}/temp_end_{name}.jpg"

    # 调用 FFmpeg 截图（复用你脚本里的 ffmpeg_path）
    ffmpeg_path, _ = get_ffmpeg_paths()

    # 提取开始帧
    subprocess.run([ffmpeg_path, "-y", "-ss", str(start_time), "-i", video_path, "-vframes", "1", start_img])
    # 提取结束帧
    subprocess.run([ffmpeg_path, "-y", "-ss", str(end_time), "-i", video_path, "-vframes", "1", end_img])

    # 2. 计算感知哈希 (pHash)
    # 需要安装: pip install imagehash pillow
    from PIL import Image
    import imagehash

    def get_hash(img_path):
        if os.path.exists(img_path):
            hash_val = imagehash.phash(Image.open(img_path))
            # os.remove(img_path)  # 删除临时文件
            return str(hash_val)
        return None

    start_hash = get_hash(start_img)
    end_hash = get_hash(end_img)

    if start_hash and end_hash:
        with sqlite3.connect(DB_PATH) as conn:
            conn.execute('''
                INSERT INTO ad_samples (name, video_path, start_frame_hash, end_frame_hash, duration)
                VALUES (?, ?, ?, ?, ?)
            ''', (name, video_path, start_hash, end_hash, end_time - start_time))
        print(f"✅ 广告样本 '{name}' 已存入数据库")


def is_similar(hash1_str, hash2_str, threshold=5):
    """判断两个哈希值是否相似"""
    try:
        hash1 = imagehash.hex_to_hash(hash1_str)
        hash2 = imagehash.hex_to_hash(hash2_str)
        return hash1 - hash2 < threshold  # 汉明距离
    except:
        return False


def remove_ads_by_image_match(input_path, output_path):
    """
    基于图像指纹数据库移除广告
    逻辑：扫描视频 -> 匹配广告区间 -> 反转区间(保留部分) -> 无损拼接
    """
    if not input_path.is_file():
        print(f"❌ 文件不存在: {input_path}")
        return

    ffmpeg_path, ffprobe_path = get_ffmpeg_paths()
    fps = my_config.get('fps', 25)
    threads = my_config.get('threads', 8)

    # 1. 获取视频总时长 (用于计算保留区间)
    total_duration = get_duration(ffprobe_path, str(input_path))
    if total_duration == 0:
        print("❌ 无法获取视频时长")
        return

    # 2. 扫描广告 (核心步骤)
    # 调用之前写好的 scan_video_for_ads 函数
    # 返回格式: [(start_time, end_time), ...]
    print(f"\n🔍 正在扫描视频中的已知广告...")
    ad_intervals = scan_video_for_ads(str(input_path), fps=fps, thread_count=threads)

    if not ad_intervals:
        print("✅ 未检测到任何已知广告，无需处理。")
        # 可以选择直接复制原文件，或者不做任何操作
        return

    # 3. 格式化输出检测到的广告
    print(f"\n🗑️ 检测到 {len(ad_intervals)} 个广告片段，准备移除:")
    for i, (start_t, end_t) in enumerate(ad_intervals, 1):
        duration = end_t - start_t
        print(f"   [{i}] {format_time(start_t)} ~ {format_time(end_t)} (时长: {duration:.2f}s)")

    # 4. 计算保留区间 (Keep Intervals)
    # 逻辑：总时长 - 广告区间 = 保留区间
    keep_intervals = []
    current_pos = 0.0

    # 先对广告区间按时间排序，防止乱序
    ad_intervals.sort()

    for ad_start, ad_end in ad_intervals:
        # 如果广告开始时间 > 当前进度，说明中间有一段是正片
        if ad_start > current_pos:
            keep_intervals.append((current_pos, ad_start))

        # 更新进度到广告结束时间
        current_pos = ad_end

    # 处理最后一段（如果广告结束后还有内容）
    if current_pos < total_duration:
        keep_intervals.append((current_pos, total_duration))

    # 5. 最终检查与执行剪辑
    if not keep_intervals:
        print("\n❌ 警告：整个视频都被识别为广告，无法保留任何内容！")
        return

    print(f"\n✂️ 最终将保留 {len(keep_intervals)} 个片段:")
    for i, (s, e) in enumerate(keep_intervals, 1):
        print(f"   [{i}] {format_time(s)} ~ {format_time(e)}")

    # 6. 执行无损剪辑
    # 复用你现有的 lossless_trim_and_concat 函数
    print("\n🚀 正在执行无损剪辑...")
    try:
        lossless_trim_and_concat(ffmpeg_path, str(input_path), str(output_path), keep_intervals)
        print(f"\n✅ 图像匹配去广告完成！输出文件: {output_path}")
    except Exception as e:
        print(f"\n❌ 剪辑执行失败: {e}")


# --- 更新匹配

def is_similar_optimized(hash1_array, hash2_array, threshold=5):
    """使用numpy计算汉明距离，更快"""
    return np.count_nonzero(hash1_array != hash2_array) < threshold


def hex_to_numpy_hash(hex_str):
    """将十六进制哈希字符串转换为numpy布尔数组"""
    hash_obj = imagehash.hex_to_hash(hex_str)
    return np.array(hash_obj.hash, dtype=np.bool_)


def precompute_sample_hashes():
    """预计算所有样本的哈希数组"""
    with sqlite3.connect(DB_PATH) as conn:
        samples = conn.execute('SELECT name, start_frame_hash, end_frame_hash, duration FROM ad_samples').fetchall()

    processed_samples = []
    for name, start_hash_db, end_hash_db, duration in samples:
        current_start_img_path = os.path.join(SAMPLE_DIR, f"temp_start_{name}.jpg")
        current_end_img_path = os.path.join(SAMPLE_DIR, f"temp_end_{name}.jpg")

        # 从图像文件重新计算哈希，确保与检测时的处理流程一致
        def calculate_hash_from_image(img_path):
            if os.path.exists(img_path):
                # 先用PIL读取图像（对特殊字符文件名支持更好）
                pil_img = Image.open(img_path)
                # 转换为numpy数组
                img_np = np.array(pil_img)
                # 如果是RGB格式，转换为BGR（OpenCV默认格式）
                if len(img_np.shape) == 3:
                    img_np = cv2.cvtColor(img_np, cv2.COLOR_RGB2BGR)

                if img_np is not None:
                    gray = cv2.cvtColor(img_np, cv2.COLOR_BGR2GRAY)
                    resized = cv2.resize(gray, my_config.get('resize', [1280, 720]))
                    current_hash_obj = imagehash.phash(Image.fromarray(resized))
                    return np.array(current_hash_obj.hash, dtype=np.bool_)
            return None

        processed_samples.append({
            'name': name,
            'start_hash': calculate_hash_from_image(current_start_img_path),
            'end_hash': calculate_hash_from_image(current_end_img_path),
            'duration': duration
        })
    return processed_samples


def scan_video_for_ads_optimized(video_path, fps=15, thread_count=8):
    """
    优化版本：使用OpenCV直接读取视频，减少FFmpeg开销
    """
    # 预加载所有样本
    processed_samples = precompute_sample_hashes()
    if not processed_samples:
        return []

    # 初始化结果存储
    suspected_starts_map = {sample['name']: [] for sample in processed_samples}

    # 打开视频
    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        print(f"❌ 无法打开视频: {video_path}")
        return []

    # 获取视频信息
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    total_duration = cap.get(cv2.CAP_PROP_POS_MSEC) / 1000.0
    original_fps = cap.get(cv2.CAP_PROP_FPS)

    # 如果没有获取到总时长，尝试用帧数和FPS计算
    if total_duration <= 0 and total_frames > 0 and original_fps > 0:
        total_duration = total_frames / original_fps

    # 计算采样间隔
    sample_interval = max(1, int(original_fps / fps))

    print(f"\n⚡ 启动优化扫描：加载了 {len(processed_samples)} 个样本，使用 {thread_count} 个线程...")
    print(f"   视频总时长: {total_duration:.2f}s, FPS: {original_fps:.2f}, 采样间隔: {sample_interval}")

    # 使用队列进行生产者-消费者模式
    frame_queue = Queue(maxsize=my_config.get('queue_size', 300))  # 限制队列大小防止内存占用过多

    # 线程安全锁
    lock = threading.Lock()
    pbar = tqdm(total=total_frames, desc="全样本扫描", unit="帧", dynamic_ncols=True)

    def worker(pbar=None):
        while True:
            item = frame_queue.get()
            if item is None:  # 结束信号
                break

            frame_idx, frame = item
            current_time = frame_idx / original_fps

            try:
                # 转换为灰度并调整大小以加快处理
                gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
                resized = cv2.resize(gray, my_config.get('resize', [1280, 720]))

                # 计算当前帧哈希
                current_hash_obj = imagehash.phash(Image.fromarray(resized))
                current_hash_array = np.array(current_hash_obj.hash, dtype=np.bool_)

                # 与所有样本进行比较
                for sample in processed_samples:
                    name = sample['name']

                    # 比较开头哈希
                    if is_similar_optimized(current_hash_array, sample['start_hash'],
                                            threshold=my_config.get('threshold', 5)):
                        with lock:
                            # 简单去重：如果该样本最近1秒内已经记录过，则跳过
                            starts = suspected_starts_map[name]
                            last_time = starts[-1] if starts else -99
                            if current_time - last_time > 1.0:
                                pbar.write(f'find ads head in {format_time(current_time)}')
                                starts.append(current_time)

            except Exception as e:
                with lock:
                    pbar.write(str(e))
                pass  # 忽略处理错误的帧
            finally:
                frame_queue.task_done()

    # 启动工作线程
    threads = []
    for _ in range(thread_count):
        t = threading.Thread(
            target=worker, args=(pbar, )
        )
        t.daemon = True
        t.start()
        threads.append(t)

    # 读取视频帧并放入队列
    frame_idx = 0

    try:
        while True:
            ret, frame = cap.read()
            if not ret:
                break

            # 根据采样间隔决定是否处理此帧
            if frame_idx % sample_interval == 0:
                # 将帧添加到队列（非阻塞）
                try:
                    frame_queue.put((frame_idx, frame.copy()), timeout=1)
                except:
                    pass  # 队列满时跳过该帧

            frame_idx += 1
            pbar.update(1)

    except KeyboardInterrupt:
        print("\n⚠️ 用户中断扫描")
    finally:
        cap.release()
        pbar.close()

        # 发送结束信号给所有线程
        for _ in range(thread_count):
            frame_queue.put(None)

        # 等待所有线程结束
        for t in threads:
            t.join(timeout=5)  # 5秒超时

    print(f"\n🔍 扫描完成，正在验证 {sum(len(v) for v in suspected_starts_map.values())} 个疑似片段...")

    final_ads = []

    for sample in processed_samples:
        name = sample['name']
        end_hash_db = sample['end_hash']
        ad_duration = sample['duration']
        starts = suspected_starts_map[name]

        # 打开视频文件
        cap = cv2.VideoCapture(str(video_path))
        if not cap.isOpened():
            print(f"❌ 无法打开视频文件: {video_path}")
            continue

        fps = cap.get(cv2.CAP_PROP_FPS)

        for start_time in starts:
            end_time = start_time + ad_duration

            # 设置视频位置到结尾时间点
            base_frame_pos = end_time * 1000  # 基准时间点（毫秒）
            time_window = 2000  # ±2秒窗口（毫秒）
            best_match_found = False

            # 在时间窗口内尝试匹配
            for offset_ms in range(-time_window, time_window + 1, 500):  # 每500ms检查一次
                target_time_ms = base_frame_pos + offset_ms
                if target_time_ms < 0:
                    continue

                cap.set(cv2.CAP_PROP_POS_MSEC, target_time_ms)
                ret, verify_img_cv = cap.read()

                if ret and verify_img_cv is not None:
                    # 按照检测时的相同方式进行预处理
                    gray = cv2.cvtColor(verify_img_cv, cv2.COLOR_BGR2GRAY)
                    resized = cv2.resize(gray, my_config.get('resize', [1280, 720]))  # 与检测时相同的尺寸

                    # 计算当前帧哈希
                    verify_hash_obj = imagehash.phash(Image.fromarray(resized))
                    verify_hash_array = np.array(verify_hash_obj.hash, dtype=np.bool_)

                    if is_similar_optimized(verify_hash_array, end_hash_db,
                                            threshold=my_config.get('threshold', 5)):
                        actual_time = target_time_ms / 1000.0  # 转回秒
                        adjusted_start = actual_time - ad_duration
                        print(
                            f"✅ 验证通过: {name} ({adjusted_start:.2f}s ~ {actual_time:.2f}s) [偏移: {offset_ms / 1000.0:+.1f}s]")
                        final_ads.append((adjusted_start, actual_time))
                        best_match_found = True
                        break  # 找到匹配就跳出循环
                else:
                    print(f"⚠️ 无法读取视频帧: 时间点 {target_time_ms / 1000.0}s")

            if not best_match_found:
                print(f"❌ 验证失败: {name} 在时间 {end_time}s 附近未找到匹配帧")

        cap.release()  # 释放视频资源

    return final_ads


# 为了兼容原有代码，保留原始函数名（但使用优化版本）
scan_video_for_ads = scan_video_for_ads_optimized


# --- 辅助函数：获取时长 (如果你的脚本里没有，请加上这个) ---
def get_duration(ffprobe_path, video_path):
    cmd = [
        ffprobe_path,
        "-v", "error",
        "-show_entries", "format=duration",
        "-of", "default=nw=1:nokey=1",  # <--- 修改点：加上 :nokey=1
        video_path
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        res_str = result.stdout.strip()
        res_str = res_str.replace('duration=', '')
        return float(res_str)
    except Exception as e:
        print(f'❌ 获取时长失败: {str(e)}')
        return 0.0


# ======================
# 1. 自动下载 FFmpeg
# ======================

def download_ffmpeg_to_temp():
    system = platform.system().lower()
    machine = platform.machine().lower()

    if system == "windows":
        url = "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip"
        exe_name = "ffmpeg.exe"
        ffprobe_name = "ffprobe.exe"
        zip_subdir = "ffmpeg-master-latest-win64-gpl/bin"
    elif system == "darwin":
        if "arm" in machine or "m1" in machine or "m2" in machine:
            url = "https://evermeet.cx/ffmpeg/ffmpeg-115820-ga9184c4e0d-macos-arm64.zip"
        else:
            url = "https://evermeet.cx/ffmpeg/ffmpeg-115820-ga9184c4e0d-macos-amd64.zip"
        exe_name = "ffmpeg"
        ffprobe_name = "ffprobe"
    elif system == "linux":
        url = "https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz"
        exe_name = "ffmpeg"
        ffprobe_name = "ffprobe"
        zip_subdir = "ffmpeg-*-amd64-static"
    else:
        raise OSError(f"不支持的系统: {system}")

    print(f"📥 正在自动下载 FFmpeg（仅本次使用）...")
    temp_dir = Path(tempfile.mkdtemp(prefix="ffmpeg_auto_"))
    archive_path = temp_dir / ("ffmpeg.zip" if system != "linux" else "ffmpeg.tar.xz")

    # 下载
    resp = requests.get(url, stream=True)
    resp.raise_for_status()
    total = int(resp.headers.get('content-length', 0))
    with open(archive_path, 'wb') as f, tqdm(
            desc="下载 FFmpeg",
            total=total,
            unit='B',
            unit_scale=True,
            unit_divisor=1024,
            leave=False
    ) as pbar:
        for chunk in resp.iter_content(chunk_size=8192):
            f.write(chunk)
            pbar.update(len(chunk))

    # 解压
    if system == "windows":
        import zipfile
        with zipfile.ZipFile(archive_path) as zf:
            members = [m for m in zf.namelist() if m.startswith(zip_subdir) and (exe_name in m or ffprobe_name in m)]
            zf.extractall(temp_dir, members=members)
            ffmpeg_path = temp_dir / members[0].replace("ffprobe.exe", "ffmpeg.exe") if "ffprobe" in members[
                0] else temp_dir / members[0]
            ffprobe_path = temp_dir / members[0].replace("ffmpeg.exe", "ffprobe.exe")
    elif system == "darwin":
        import zipfile
        with zipfile.ZipFile(archive_path) as zf:
            zf.extractall(temp_dir)
            ffmpeg_path = temp_dir / exe_name
            ffprobe_path = temp_dir / ffprobe_name
    else:  # Linux
        import tarfile
        with tarfile.open(archive_path) as tf:
            members = [m for m in tf.getmembers() if exe_name in m.name or ffprobe_name in m.name]
            tf.extractall(temp_dir, members=members)
            ffmpeg_path = temp_dir / members[0].name if exe_name in members[0].name else temp_dir / members[1].name
            ffprobe_path = temp_dir / members[1].name if ffprobe_name in members[1].name else temp_dir / members[0].name

    ffmpeg_path.chmod(0o755)
    ffprobe_path.chmod(0o755)
    return str(ffmpeg_path), str(ffprobe_path)


def get_ffmpeg_paths():
    """返回 (ffmpeg_path, ffprobe_path)"""
    system = platform.system().lower()
    exe_ext = ".exe" if system == "windows" else ""

    # 1. 先尝试系统 PATH（用户可能已安装）
    ffmpeg_sys = shutil.which("ffmpeg")
    ffprobe_sys = shutil.which("ffprobe")
    if ffmpeg_sys and ffprobe_sys:
        return ffmpeg_sys, ffprobe_sys

    # 2. 再尝试当前脚本目录下的 ffmpeg/ffprobe（你预放的文件）
    script_dir = Path('./ffmpeg_bins/win')
    ffmpeg_local = script_dir / f"ffmpeg{exe_ext}"
    ffprobe_local = script_dir / f"ffprobe{exe_ext}"

    if ffmpeg_local.is_file() and ffprobe_local.is_file():
        # 赋予执行权限（Linux/macOS 需要）
        ffmpeg_local.chmod(0o755)
        ffprobe_local.chmod(0o755)
        return str(ffmpeg_local.absolute()), str(ffprobe_local.absolute())

    # 3. 都没有？才自动下载
    try:
        return download_ffmpeg_to_temp()
    except Exception as e:
        raise RuntimeError(f"无法获取 FFmpeg/ffprobe: {e}")


# ======================
# 2. 用 ffprobe 分析每帧分辨率
# ======================

def analyze_frame_resolutions(ffprobe_path, video_path):
    """
    仅分析关键帧（I帧），大幅加速！
    返回: [(pts_time, width, height), ...]
    """
    import subprocess
    import csv
    from tqdm import tqdm

    skip_frame = my_config.get('skip_frame', None)

    # 获取总关键帧数（可选）
    cmd_count = [
        ffprobe_path,
        "-v", "quiet",
        "-select_streams", "v:0",
        "-count_packets",  # 注意：用 packets 更快
        "-show_entries", "stream=nb_read_packets",
        "-of", "csv=p=0",
    ]
    if skip_frame is not None:
        cmd_count.extend(
            ["-skip_frame", skip_frame]
        )
    else:
        print('分析所有帧')
    cmd_count.append(video_path)

    try:
        result = subprocess.run(cmd_count, capture_output=True, text=True, timeout=10)
        total_keyframes = int(result.stdout.strip()) if result.stdout.strip().isdigit() else None
    except Exception:
        total_keyframes = None

    # 主分析命令：只读关键帧
    cmd = [
        ffprobe_path,
        "-v", "quiet",
        "-select_streams", "v:0",
        "-show_frames",
        "-show_entries", "frame=pts_time,width,height",
        "-of", "csv=p=0",
        # "-skip_frame", "nokey",  # 👈 关键！跳过非关键帧
        # "-i", video_path
    ]

    if skip_frame is not None:
        cmd.extend(
            ["-skip_frame", skip_frame]
        )
    cmd.extend(['-i', video_path])

    frames = []
    process = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding='utf-8',
        bufsize=1
    )

    tqdm.write("⏳ 正在分析关键帧（I帧）...（速度提升 10x+）")
    pbar = tqdm(desc="分析关键帧", unit="关键帧", dynamic_ncols=True)
    if total_keyframes is not None:
        pbar.total = total_keyframes

    try:
        reader = csv.reader(iter(process.stdout.readline, ''))
        for row in reader:
            if len(row) == 3:
                try:
                    pts = float(row[0])
                    w, h = int(row[1]), int(row[2])
                    if w > 0 and h > 0:
                        frames.append((pts, w, h))
                    pbar.update(1)
                except (ValueError, IndexError):
                    continue
    finally:
        pbar.close()

    stderr = process.stderr.read()
    if process.wait() != 0:
        raise RuntimeError(f"ffprobe 失败: {stderr}")

    tqdm.write(f"✅ 分析完成，共 {len(frames)} 个关键帧")
    return frames


def segment_by_resolution(frames):
    """
    输入: [(pts_time, width, height), ...]
    输出: [(start_frame_idx, end_frame_idx, (w, h)), ...]
    """
    if not frames:
        return []

    segments = []
    start_idx = 0
    current_res = (frames[0][1], frames[0][2])

    for i in range(1, len(frames)):
        t, w, h = frames[i]
        res = (w, h)
        if res != current_res:
            # 结束上一段：[start_idx, i-1]
            segments.append((start_idx, i - 1, current_res))
            start_idx = i
            current_res = res

    # 最后一段
    segments.append((start_idx, len(frames) - 1, current_res))
    return segments


def build_keep_intervals(frames, segments, main_res, min_duration=1.0):
    """
    返回保留的时间区间列表 [(start_pts, end_pts), ...]
    并返回将被移除的区间用于显示
    """
    all_removed = []
    keep_intervals = []

    for start_idx, end_idx, res in segments:
        start_pts = frames[start_idx][0]
        end_pts = frames[end_idx][0]

        # 如果是主分辨率段 → 保留，但去掉首尾帧（如果段长度 > 2）
        if res == main_res:
            duration = end_pts - start_pts
            if duration < min_duration:
                all_removed.append((start_pts, end_pts, "太短"))
                continue

            keep_intervals.append((start_pts, end_pts))

            # # 跳过首帧和尾帧（至少保留中间部分）
            # if end_idx - start_idx >= 2:  # 至少3帧才能去掉首尾
            #     new_start = frames[start_idx + 1][0]
            #     new_end = frames[end_idx - 1][0]
            #     if new_end > new_start:
            #         keep_intervals.append((new_start, new_end))
            #     else:
            #         # 只剩一帧，看是否满足最小时间
            #         if duration >= min_duration:
            #             keep_intervals.append((start_pts, end_pts))
            #         else:
            #             all_removed.append((start_pts, end_pts, "去首尾后无效"))
            # else:
            #     # 段太短（<3帧），直接保留或丢弃
            #     if duration >= min_duration:
            #         keep_intervals.append((start_pts, end_pts))
            #     else:
            #         all_removed.append((start_pts, end_pts, "太短"))
        else:
            # 非主分辨率段 → 全部移除
            all_removed.append((start_pts, end_pts, f"非主分辨率 {res[0]}x{res[1]}"))

    return keep_intervals, all_removed


# ======================
# 3. 无损剪辑
# ======================

def lossless_trim_and_concat(ffmpeg_path, input_path, output_path, time_intervals):
    if len(time_intervals) == 0:
        raise ValueError("无可保留的时间段")

    if len(time_intervals) == 1:
        start, end = time_intervals[0]
        cmd = [
            ffmpeg_path,
            "-y",
            "-ss", str(start),
            "-to", str(end),
            "-i", input_path,
            "-c", "copy",
            "-avoid_negative_ts", "make_zero",
            output_path
        ]
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:
        temp_dir = Path(output_path).parent / "temp_ffmpeg"
        temp_dir.mkdir(exist_ok=True)
        temp_files = []

        try:
            for i, (start, end) in enumerate(time_intervals):
                temp_file = temp_dir / f"part_{i:03d}{Path(input_path).suffix}"
                cmd = [
                    ffmpeg_path,
                    "-y",
                    "-ss", str(start),
                    "-to", str(end),
                    "-i", input_path,
                    "-c", "copy",
                    str(temp_file)
                ]
                subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                temp_files.append(str(temp_file))

            concat_list = temp_dir / "concat.txt"
            with open(concat_list, 'w', encoding='utf-8') as f:
                for tf in temp_files:
                    f.write(f"file '{os.path.abspath(tf)}'\n")

            cmd = [
                ffmpeg_path,
                "-y",
                "-f", "concat",
                "-safe", "0",
                "-i", str(concat_list),
                "-c", "copy",
                "-avoid_negative_ts", "make_zero",
                output_path
            ]
            subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        finally:
            for tf in temp_files:
                try:
                    os.remove(tf)
                except:
                    pass
            try:
                concat_list.unlink(missing_ok=True)
                temp_dir.rmdir()
            except:
                pass


def format_time(seconds):
    """将秒转为 HH:MM:SS.sss"""
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    s = seconds % 60
    return f"{h:02d}:{m:02d}:{s:06.3f}"


# ======================
# 4. 主流程
# ======================

def remove_ads(input_path, output_path, min_duration=1.0):
    if not input_path.is_file():
        print(f"❌ 文件不存在: {input_path}")
        return

    # 获取 FFmpeg 路径
    ffmpeg_path, ffprobe_path = get_ffmpeg_paths()

    # 分析帧
    print("🔍 正在分析每帧分辨率（使用 ffprobe）...")
    frames = analyze_frame_resolutions(ffprobe_path, str(input_path))
    if not frames:
        raise ValueError("未检测到任何视频帧")

    print(f"📊 共分析 {len(frames)} 帧")

    # 分段（带帧索引）
    segments = segment_by_resolution(frames)
    print(f"🎬 检测到 {len(segments)} 个分辨率段")

    # 找主分辨率
    res_durations = {}
    for start_idx, end_idx, res in segments:
        dur = frames[end_idx][0] - frames[start_idx][0]
        res_durations[res] = res_durations.get(res, 0) + dur

    main_res = max(res_durations, key=res_durations.get)
    print(f"🎯 主分辨率为: {main_res[0]}x{main_res[1]}")

    # 构建保留区间 & 移除区间
    keep_intervals, removed_intervals = build_keep_intervals(
        frames, segments, main_res, min_duration=min_duration
    )

    # 显示将被移除的片段
    if removed_intervals:
        print("\n🗑️ 将移除以下片段:")
        for start_t, end_t, reason in removed_intervals:
            print(f"   {format_time(start_t)} ~ {format_time(end_t)} ({reason})")
    else:
        print("\n✅ 无广告片段需要移除")
        return

    # 显示将保留的片段
    if keep_intervals:
        print(f"\n✂️ 将保留 {len(keep_intervals)} 个时间段:")
        for i, (s, e) in enumerate(keep_intervals, 1):
            print(f"   [{i}] {format_time(s)} ~ {format_time(e)} (持续 {e - s:.2f}s)")
    else:
        print("\n❌ 无有效内容可保留！")
        return

    # 无损剪辑
    print("\n🚀 正在执行无损剪辑（保留原始编码）...")
    lossless_trim_and_concat(ffmpeg_path, str(input_path), str(output_path), keep_intervals)
    print(f"\n✅ 完成！输出文件: {output_path}")


def get_video_files_in_folder(folder_path, video_extensions=None):
    """
    获取指定文件夹内（不递归子目录）的所有视频文件。

    Args:
        folder_path (str or Path): 目标文件夹路径
        video_extensions (set): 视频文件扩展名集合（小写），默认包含常见格式

    Returns:
        List[Path]: 视频文件的 Path 对象列表，按文件名排序
    """
    if video_extensions is None:
        video_extensions = {
            '.mp4', '.mkv', '.avi', '.mov', '.wmv', '.flv', '.webm',
            '.m4v', '.mpg', '.mpeg', '.3gp', '.ts', '.mts', '.m2ts'
        }
    else:
        # 确保扩展名是小写，便于统一比较
        video_extensions = {ext.lower() for ext in video_extensions}

    folder = Path(folder_path)
    if not folder.is_dir():
        raise ValueError(f"路径不是有效文件夹: {folder}")

    video_files = [
        f for f in folder.iterdir()
        if f.is_file() and f.suffix.lower() in video_extensions
    ]

    return sorted(video_files)  # 按文件名排序，更友好


class AdManagerApp:
    def __init__(self, root):
        self.root = root
        self.root.title("广告样本管理系统")
        self.root.geometry("900x600")

        # 确保图片目录存在
        if not os.path.exists(SAMPLE_DIR):
            os.makedirs(SAMPLE_DIR)

        # === 布局：左侧列表，右侧详情 ===
        # 左侧面板 (列表)
        left_frame = tk.Frame(root, width=300, bg="#f0f0f0")
        left_frame.pack(side=tk.LEFT, fill=tk.Y, padx=5, pady=5)

        # 列表头
        cols = ("名称", "时长")
        self.tree = ttk.Treeview(left_frame, columns=cols, show="headings", height=20)
        self.tree.heading("名称", text="广告名称")
        self.tree.heading("时长", text="时长(秒)")
        self.tree.column("名称", width=150)
        self.tree.column("时长", width=80)
        self.tree.pack(fill=tk.BOTH, expand=True)

        # 列表绑定点击事件
        self.tree.bind("<<TreeviewSelect>>", self.on_select)

        # 右侧面板 (图片与操作)
        right_frame = tk.Frame(root)
        right_frame.pack(side=tk.LEFT, fill=tk.BOTH, expand=True, padx=5, pady=5)

        # 图片显示区域
        img_frame = tk.Frame(right_frame)
        img_frame.pack(fill=tk.BOTH, expand=True)

        # 开头图片标签
        tk.Label(img_frame, text="开头帧 (Start)", font=("微软雅黑", 10, "bold")).pack()
        self.lbl_start_img = tk.Label(img_frame, text="暂无图片", bg="#ddd", relief=tk.SUNKEN)
        self.lbl_start_img.pack(fill=tk.BOTH, expand=True, pady=5)

        # 结尾图片标签
        tk.Label(img_frame, text="结尾帧 (End)", font=("微软雅黑", 10, "bold")).pack()
        self.lbl_end_img = tk.Label(img_frame, text="暂无图片", bg="#ddd", relief=tk.SUNKEN)
        self.lbl_end_img.pack(fill=tk.BOTH, expand=True, pady=5)

        # 底部按钮区
        btn_frame = tk.Frame(right_frame)
        btn_frame.pack(fill=tk.X, pady=10)

        self.btn_del = tk.Button(btn_frame, text="🗑️ 删除选中样本", bg="#ffcccc", command=self.delete_sample,
                                 state=tk.DISABLED)
        self.btn_del.pack(fill=tk.X)

        # 当前选中的名称
        self.current_name = None
        self.current_start_img_path = None
        self.current_end_img_path = None

        # 加载数据
        self.refresh_list()

    def refresh_list(self):
        """刷新左侧列表"""
        # 清空现有项
        for item in self.tree.get_children():
            self.tree.delete(item)

        try:
            conn = sqlite3.connect(DB_PATH)
            cursor = conn.execute("SELECT name, duration FROM ad_samples ORDER BY name")
            for row in cursor:
                self.tree.insert("", tk.END, values=(row[0], f"{row[1]:.1f}"))
            conn.close()
        except Exception as e:
            messagebox.showerror("错误", f"读取数据库失败:\n{e}")

    def on_select(self, event):
        """点击列表项时触发"""
        selected_items = self.tree.selection()
        if not selected_items:
            return

        # 获取选中项的值
        item = self.tree.item(selected_items[0])
        self.current_name = item['values'][0]
        self.btn_del.config(state=tk.NORMAL)

        # 构造图片路径
        self.current_start_img_path = os.path.join(SAMPLE_DIR, f"temp_start_{self.current_name}.jpg")
        self.current_end_img_path = os.path.join(SAMPLE_DIR, f"temp_end_{self.current_name}.jpg")

        # 显示图片
        self.show_image(self.lbl_start_img, self.current_start_img_path)
        self.show_image(self.lbl_end_img, self.current_end_img_path)

    def show_image(self, label, path):
        """辅助函数：缩放并显示图片"""
        if os.path.exists(path):
            try:
                # 打开图片
                img = Image.open(path)
                # 获取标签的大小
                w, h = label.winfo_width(), label.winfo_height()
                if w < 10 or h < 10:  # 如果标签还没渲染好，给个默认值
                    w, h = 300, 200

                # 缩放图片 (LANCZOS 是高质量缩放)
                img = img.resize((w, h), Image.Resampling.LANCZOS)
                # 转换为 Tk 格式
                photo = ImageTk.PhotoImage(img)
                # 保存引用，防止被垃圾回收
                label.config(image=photo, text="")
                label.image = photo
            except Exception as e:
                label.config(image="", text=f"图片加载失败:\n{e}")
                label.image = None
        else:
            label.config(image="", text="图片文件不存在")
            label.image = None

    def delete_sample(self):
        """删除样本"""
        if not self.current_name:
            return

        if messagebox.askyesno("确认删除", f"确定要删除样本 '{self.current_name}' 吗？\n(关联的图片文件也会被删除)"):
            try:
                # 1. 删除数据库记录
                conn = sqlite3.connect(DB_PATH)
                conn.execute("DELETE FROM ad_samples WHERE name = ?", (self.current_name,))
                conn.commit()
                conn.close()

                # 2. 删除图片文件
                for path in [self.current_start_img_path, self.current_end_img_path]:
                    if os.path.exists(path):
                        os.remove(path)

                # 3. 刷新界面
                self.current_name = None
                self.btn_del.config(state=tk.DISABLED)
                self.lbl_start_img.config(image="", text="暂无图片")
                self.lbl_end_img.config(image="", text="暂无图片")
                self.refresh_list()

                messagebox.showinfo("成功", "样本已删除")

            except Exception as e:
                messagebox.showerror("错误", f"删除失败:\n{e}")


def show_time_selector_gui(video_path):
    """
    弹出一个窗口，允许用户预览视频并选择开始和结束时间
    返回: (start_time_str, end_time_str) 或 None (如果取消)
    """
    video_path = str(video_path)
    print(video_path)
    ffmpeg_path, ffprobe_path = get_ffmpeg_paths()
    review = tk.Toplevel(root)
    review.title("选取广告时间段")
    review.minsize(800, 800)
    review.geometry("800x800")
    total_seconds = get_duration(ffprobe_path, video_path)

    # 变量存储时间
    slider_var = tk.IntVar(value=0)
    current_time_var = tk.StringVar(value="00:00:00")
    start_time_var = tk.StringVar(value="00:00:00")
    end_time_var = tk.StringVar(value="00:00:00")

    # 用于存储临时截图的标签
    img_label = tk.Label(review, bg="black")
    img_label.pack(fill=tk.BOTH, expand=True)

    def sync_slider_to_time(*args):
        """当滑块移动时，更新 current_time_var (秒 -> HH:MM:SS)"""
        secs = slider_var.get()
        # 简单的秒转时间字符串格式
        time_str = f"{secs // 3600:02d}:{(secs % 3600) // 60:02d}:{secs % 60:02d}"

        # 阻断循环触发：如果值已经一样就不更新了
        if current_time_var.get() != time_str:
            current_time_var.set(time_str)
            update_preview(time_str)  # 触发预览

    # --- 核心函数：提取当前时间的帧并显示 ---
    def update_preview(time_str):
        try:
            # 使用 FFmpeg 提取单帧
            # 注意：这里使用 -ss 快速跳转
            cmd = [
                ffmpeg_path,
                "-ss", time_str,
                "-i", str(video_path),  # 确保 video_path 是完整路径
                "-frames:v", "1",
                "-f", "image2pipe",
                "-vcodec", "mjpeg",
                "-"
            ]
            proc = subprocess.run(
                cmd,
                capture_output=True,
                timeout=10,
                check=False  # 先设为 False，我们要手动检查返回码
            )

            if proc.returncode != 0:
                print(f"❌ FFmpeg 执行失败！")
                print(f"⚙️ 命令: {' '.join(cmd)}")
                # 打印 FFmpeg 的错误信息（通常是解码错误或文件不存在）
                print(f"⚠️ 错误详情: {proc.stderr.decode('gbk', errors='ignore')}")
                review.quit()
                return

            if proc.stdout:
                img = Image.open(io.BytesIO(proc.stdout))
                # 缩放适应窗口
                window_w = review.winfo_width()
                target_w = window_w
                target_h = int(target_w * img.height / img.width)

                img = img.resize((target_w, target_h), Image.Resampling.LANCZOS)
                photo = ImageTk.PhotoImage(img)
                img_label.config(image=photo)
                img_label.image = photo  # 保持引用
        except Exception as e:
            traceback.print_exc()
            print(f"预览错误: {e}")
            review.quit()
            review.destroy()

    # --- 布局：控制区域 ---
    control_frame = tk.Frame(review)
    control_frame.pack(fill=tk.X, padx=10, pady=5)

    # 第一行：时间输入和设置按钮
    tk.Label(control_frame, text="预览时间:").grid(row=0, column=0, padx=5)
    time_entry = tk.Entry(control_frame, textvariable=current_time_var, width=15)
    time_entry.grid(row=0, column=1, padx=5)

    def on_time_change(event=None):
        update_preview(current_time_var.get())

    # 输入框回车绑定
    time_entry.bind("<Return>", on_time_change)

    # 设置开始时间
    btn_set_start = tk.Button(control_frame, text="设为【开始】",
                              command=lambda: start_time_var.set(current_time_var.get()))
    btn_set_start.grid(row=0, column=2, padx=10)

    # 设置结束时间
    btn_set_end = tk.Button(control_frame, text="设为【结束】", command=lambda: end_time_var.set(current_time_var.get()))
    btn_set_end.grid(row=0, column=3, padx=10)

    # === 新增：滑动控制条 ===
    # 假设视频最长 1 小时 (3600秒)，你可以根据实际情况调整 to= 的值
    # orient=tk.HORIZONTAL 表示横向滑块
    # command 参数绑定拖动事件，x 是滑块当前的数值（秒）
    time_slider = tk.Scale(
        control_frame,
        from_=0,
        to=int(total_seconds),
        orient=tk.HORIZONTAL,
        variable=slider_var,  # 绑定变量，滑块动，变量也会动
        command=lambda x: update_preview(current_time_var.get()),  # 拖动时触发预览
        label="进度拖动 (秒)",
        length=400,  # 滑块长度
        resolution=1,  # 步进值，1表示按1秒递增
        takefocus=True
    )
    time_slider.grid(
        row=1, column=0, columnspan=4,
        pady=5)  # 横跨所有列

    # 在滑块那一行前后加两个按钮
    btn_prev = tk.Button(control_frame, text="◀", width=3,
                         command=lambda: slider_var.set(slider_var.get() - 1))
    btn_prev.grid(row=1, column=0, pady=5)

    time_slider.grid(row=1, column=1, columnspan=2, sticky="ew", pady=5)

    btn_next = tk.Button(control_frame, text="▶", width=3,
                         command=lambda: slider_var.set(slider_var.get() + 1))
    btn_next.grid(row=1, column=3, pady=5)

    # 监听滑块的变量变化
    slider_var.trace_add("write", sync_slider_to_time)
    control_frame.columnconfigure(1, weight=1)

    # 第二行：显示选中的范围
    tk.Label(control_frame, text="已选范围:").grid(row=2, column=0, pady=(10, 10))
    tk.Label(control_frame, textvariable=start_time_var, fg="blue", font=("微软雅黑", 10, "bold")).grid(row=2, column=1)
    tk.Label(control_frame, text="~").grid(row=2, column=2)
    tk.Label(control_frame, textvariable=end_time_var, fg="red", font=("微软雅黑", 10, "bold")).grid(row=2, column=3)

    # 5. 底部按钮
    btn_frame = tk.Frame(review)
    btn_frame.pack(fill=tk.X, pady=10)

    result = {"status": "cancel"}

    def on_confirm():
        result["status"] = "ok"
        result["start"] = start_time_var.get()
        result["end"] = end_time_var.get()
        review.quit()
        review.destroy()

    def on_cancel():
        result["status"] = "cancel"
        review.quit()
        review.destroy()

    review.protocol("WM_DELETE_WINDOW", on_cancel)
    tk.Button(btn_frame, text="取消", command=on_cancel, width=10).pack(side=tk.LEFT, padx=20)
    tk.Button(btn_frame, text="确定选择", command=on_confirm, bg="#ddddff", width=10).pack(side=tk.RIGHT, padx=20)

    # --- 初始化 ---
    # 窗口加载后先显示第一帧
    review.after(100, lambda: update_preview("00:00:01"))

    review.mainloop()

    if result["status"] == "ok":
        return result["start"], result["end"]
    else:
        return None


from tkinter import Tk, filedialog

root = Tk()
root.withdraw()  # 隐藏主窗口
root.wm_attributes('-topmost', 1)  # 置顶


def main():
    init_db()
    import argparse

    parser = argparse.ArgumentParser(description="纯 FFmpeg 无损移除分辨率广告")
    parser.add_argument("--v_path", help="输入视频路径", default=None)
    parser.add_argument("--vs_path", help='批量处理', default=None)
    parser.add_argument("-o", "--output", help="输出路径")
    parser.add_argument("--min-duration", type=float, default=1.0, help="最小保留片段时长（秒）")
    args = parser.parse_args()

    # 新增：如果没有任何输入参数，弹出图形界面选择
    if args.v_path is None and args.vs_path is None:
        try:

            choice = input(
                "请选择模式:\n"
                "[1] 单个视频\n"
                "[2] 视频文件夹\n"
                "[3] 数据库管理\n"
                "请输入, 输入q退出: ").strip()
            if choice == "1":
                path = filedialog.askopenfilename(
                    title="选择视频文件",
                    filetypes=[("视频文件", "*.mp4 *.mkv *.avi *.mov *.flv *.webm")]
                )
                if path:
                    args.v_path = path
                    print(f'path: {path}')
                else:
                    print("❌ 未选择文件")
                    return
            elif choice == "2":
                path = filedialog.askdirectory(title="选择视频文件夹")
                if path:
                    args.vs_path = path
                    print(f'path: {path}')
                else:
                    print("❌ 未选择文件夹")
                    return
            elif choice == '3':
                root.withdraw()
                manager_win = tk.Toplevel(root)
                manager_win.title("广告样本管理系统")
                manager_win.geometry("900x600")
                app = AdManagerApp(manager_win)

                def on_close():
                    manager_win.quit()
                    manager_win.destroy()  # 销毁管理窗口
                    root.withdraw()

                manager_win.protocol("WM_DELETE_WINDOW", on_close)
                manager_win.mainloop()
                return
            elif choice == 'q':
                print('end')
                # root.destroy()
                exit()
            else:
                print("❌ 无效选择")
                return
        except Exception as e:
            print(f"⚠️ 无法启动图形界面（请使用命令行）: {e}")
            parser.print_help()
            return

    style_choice = input("请选择模式:\n"
                         "[1] 分辨率突变\n"
                         "[2] 手动选择样本\n"
                         "[3] 数据库匹配\n"
                         "请输入: ").strip()
    # 后续逻辑完全不变！
    if args.v_path is not None:
        input_path = Path(args.v_path)
        output_path = args.output or (input_path.parent / ("clean_" + input_path.stem + input_path.suffix))
        if style_choice == '2':
            selected_range = show_time_selector_gui(input_path)
            if selected_range:
                start_time, end_time = selected_range
                print(f"✅ 选定时间: {start_time} - {end_time}")
                add_ad_sample(str(input_path.stem), input_path, start_time, end_time)
                # remove_ads_by_image_match(input_path, output_path)
            else:
                print("❌ 已取消操作")
        elif style_choice == '3':
            remove_ads_by_image_match(input_path, output_path)
        else:
            remove_ads(input_path, output_path, args.min_duration)
    else:
        input_path = Path(args.vs_path)
        videos = get_video_files_in_folder(input_path)
        output_path = args.output or input_path / 'clean'
        output_path.mkdir(exist_ok=True)
        for i, video in enumerate(videos):
            print(f'[{i + 1}/{len(videos)}] {video.name}')
            video_out = output_path / ("clean_" + video.name)
            if style_choice == '2':
                selected_range = show_time_selector_gui(video)
                if selected_range:
                    start_time, end_time = selected_range
                    add_ad_sample(str(video.stem), video, start_time, end_time)
                    remove_ads_by_image_match(video, video_out)
                    break
            elif style_choice == '3':
                remove_ads_by_image_match(video, video_out)
            else:
                remove_ads(video, video_out, args.min_duration)


if __name__ == "__main__":
    while True:
        main()
