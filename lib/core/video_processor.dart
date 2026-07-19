import 'package:flutter/foundation.dart';
import 'dart:convert' show utf8, LineSplitter;
import 'dart:io' show Platform, Process, ProcessResult, Directory, File;
import 'package:path_provider/path_provider.dart';
import 'package:ffmpeg_kit_flutter_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_min_gpl/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_min_gpl/return_code.dart';
import '../models/ad_interval.dart';
import 'resolution_analyzer.dart';

class VideoProcessor {
  static String? _ffmpegPath;
  static String? _ffprobePath;
  static bool _pathsInitialized = false;
  static Process? _currentProcess;
  static final List<Process> _processes = [];
  static bool _cancelRequested = false;

  static bool get isCancelled => _cancelRequested;

  static void cancelCurrentProcess() {
    _cancelRequested = true;
    _currentProcess?.kill();
    _currentProcess = null;
    for (final p in _processes) {
      try { p.kill(); } catch (_) {}
    }
    _processes.clear();
  }

  static void resetCancel() {
    _cancelRequested = false;
    _currentProcess = null;
    _processes.clear();
  }

  static Future<void> _initPaths() async {
    if (_pathsInitialized || Platform.isAndroid) return;
    _pathsInitialized = true;

    final ext = Platform.isWindows ? '.exe' : '';
    final subDir = Platform.isWindows
        ? 'win'
        : (Platform.isMacOS ? 'macos' : 'linux');

    final localDir = Directory('ffmpeg_bins${Platform.pathSeparator}$subDir');
    if (localDir.existsSync()) {
      final ff = '${localDir.path}${Platform.pathSeparator}ffmpeg$ext';
      final fp = '${localDir.path}${Platform.pathSeparator}ffprobe$ext';
      if (File(ff).existsSync() && File(fp).existsSync()) {
        _ffmpegPath = ff;
        _ffprobePath = fp;
        if (!Platform.isWindows) {
          Process.run('chmod', ['+x', ff]);
          Process.run('chmod', ['+x', fp]);
        }
        return;
      }
    }

    final cwdFf = '.${Platform.pathSeparator}ffmpeg$ext';
    final cwdFp = '.${Platform.pathSeparator}ffprobe$ext';
    if (File(cwdFf).existsSync() && File(cwdFp).existsSync()) {
      _ffmpegPath = cwdFf;
      _ffprobePath = cwdFp;
      if (!Platform.isWindows) {
        Process.run('chmod', ['+x', cwdFf]);
        Process.run('chmod', ['+x', cwdFp]);
      }
      return;
    }

    _ffmpegPath = 'ffmpeg$ext';
    _ffprobePath = 'ffprobe$ext';
  }

  /// Count frame packets for progress estimation (matches py script behavior)
  static Future<int> getFrameCount(String videoPath, {bool keyframeOnly = true}) async {
    final args = [
      '-v', 'error',
      '-select_streams', 'v:0',
      '-count_packets',
      '-show_entries', 'stream=nb_read_packets',
      '-of', 'csv=p=0',
      if (keyframeOnly) ...['-skip_frame', 'nokey'],
      videoPath,
    ];
    final raw = (await _execFFprobe(args)).trim();
    // csv format: "stream|nb_read_packets\n1234" or just "1234"
    final lines = raw.split('\n');
    return int.tryParse(lines.last) ?? 0;
  }

  /// Streaming analysis: calls [onFrame] for each parsed frame line.
  /// [onResolutionChange] fires in real-time when width/height differs.
  static Future<String> analyzeResolutions(
    String videoPath, {
    void Function(int count)? onFrame,
    bool keyframeOnly = true,
    void Function(double ptsTime, int width, int height)? onResolutionChange,
  }) async {
    final args = [
      '-v', 'quiet',
      '-select_streams', 'v:0',
      '-show_frames',
      '-show_entries', 'frame=pts_time,width,height',
      '-of', 'csv=p=0',
      if (keyframeOnly) ...['-skip_frame', 'nokey'],
      '-i', videoPath,
    ];

    if (Platform.isAndroid) {
      return _execFFprobe(args);
    }

    await _initPaths();
    _currentProcess = await Process.start(_ffprobePath!, args);

    final output = StringBuffer();
    int count = 0;
    int? lastW, lastH;

    await for (final line
        in _currentProcess!.stdout.transform(utf8.decoder).transform(const LineSplitter())) {
      if (_cancelRequested) break;
      // detect resolution change in real time
      if (onResolutionChange != null) {
        final parts = line.split(',');
        if (parts.length >= 3) {
          final pts = double.tryParse(parts[0]);
          final w = int.tryParse(parts[1]);
          final h = int.tryParse(parts[2]);
          if (pts != null && w != null && h != null) {
            if (lastW != null && (w != lastW || h != lastH)) {
              onResolutionChange(pts, w, h);
            }
            lastW = w;
            lastH = h;
          }
        }
      }
      output.writeln(line);
      count++;
      onFrame?.call(count);
    }

    if (_cancelRequested) {
      _currentProcess?.kill();
      _currentProcess = null;
      throw ProcessCancelledException();
    }

    final stderr = await _currentProcess!.stderr.transform(utf8.decoder).join();
    final exitCode = await _currentProcess!.exitCode;
    _currentProcess = null;
    if (exitCode != 0) {
      throw Exception('ffprobe error (exit $exitCode): $stderr');
    }

    return output.toString();
  }

  /// Scan a specific time window with ffprobe.
  /// Uses [onFrame] for progress and [onResolutionChange] for real-time resolution change events.
  static Future<String> scanTimeRange(
    String videoPath,
    double startTime,
    double endTime, {
    bool keyframeOnly = false,
    void Function(int count)? onFrame,
    void Function(double ptsTime, int width, int height)? onResolutionChange,
  }) async {
    final args = [
      '-v', 'quiet',
      '-read_intervals', '${startTime.toStringAsFixed(3)}%+${(endTime - startTime).toStringAsFixed(3)}',
      '-select_streams', 'v:0',
      '-show_frames',
      '-show_entries', 'frame=pts_time,width,height',
      '-of', 'csv=p=0',
      if (keyframeOnly) ...['-skip_frame', 'nokey'],
      '-i', videoPath,
    ];

    if (Platform.isAndroid) {
      return _execFFprobe(args);
    }

    await _initPaths();
    _currentProcess = await Process.start(_ffprobePath!, args);

    final output = StringBuffer();
    int count = 0;
    int? lastW, lastH;

    await for (final line
        in _currentProcess!.stdout.transform(utf8.decoder).transform(const LineSplitter())) {
      if (_cancelRequested) {
        _currentProcess?.kill();
        _currentProcess = null;
        throw ProcessCancelledException();
      }
      if (onResolutionChange != null) {
        final parts = line.split(',');
        if (parts.length >= 3) {
          final pts = double.tryParse(parts[0]);
          final w = int.tryParse(parts[1]);
          final h = int.tryParse(parts[2]);
          if (pts != null && w != null && h != null) {
            if (lastW != null && (w != lastW || h != lastH)) {
              onResolutionChange(pts, w, h);
            }
            lastW = w;
            lastH = h;
          }
        }
      }
      output.writeln(line);
      count++;
      onFrame?.call(count);
    }

    final stderr = await _currentProcess!.stderr.transform(utf8.decoder).join();
    final exitCode = await _currentProcess!.exitCode;
    _currentProcess = null;
    if (exitCode != 0) {
      throw Exception('ffprobe window error (exit $exitCode): $stderr');
    }

    return output.toString();
  }

  /// Parallel segmented ffprobe analysis using streaming Process.start per segment.
  /// [onResolutionChange] fires in real-time when width/height differs from previous frame.
  static Future<String> analyzeResolutionsParallel(
    String videoPath, {
    int parallelism = 4,
    bool keyframeOnly = true,
    void Function(int segment, int cumulativeCount)? onFrame,
    void Function(double ptsTime, int width, int height)? onResolutionChange,
    bool Function()? isCancelled,
  }) async {
    debugPrint('[VideoProcessor] analyzeResolutionsParallel: segments=$parallelism, keyframeOnly=$keyframeOnly');

    if (Platform.isAndroid) {
      final csv = await analyzeResolutions(videoPath, keyframeOnly: keyframeOnly);
      return csv;
    }

    await _initPaths();
    final duration = await getDuration(videoPath);
    if (duration <= 0) return '';

    final segDuration = duration / parallelism;
    final outputs = List.generate(parallelism, (_) => StringBuffer());
    int frameCount = 0;

    final futures = List.generate(parallelism, (i) async {
      if (isCancelled != null && isCancelled()) throw ProcessCancelledException();

      final start = i * segDuration;
      final seg = segDuration.toStringAsFixed(3);
      final args = [
        '-v', 'error',
        '-read_intervals', '${start.toStringAsFixed(3)}%+$seg',
        '-select_streams', 'v:0',
        '-show_frames',
        '-show_entries', 'frame=pts_time,width,height',
        '-of', 'csv=p=0',
        if (keyframeOnly) ...['-skip_frame', 'nokey'],
        '-i', videoPath,
      ];
      debugPrint('[ffprobe segment $i] ${_ffprobePath} ${args.join(" ")}');
      final process = await Process.start(_ffprobePath!, args);
      _processes.add(process);

      // collect stderr for error reporting
      final stderrLines = <String>[];
      process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .forEach((l) => stderrLines.add(l));

      int? lastW, lastH;
      await for (final line
          in process.stdout.transform(utf8.decoder).transform(const LineSplitter())) {
        if (isCancelled != null && isCancelled()) {
          process.kill();
          throw ProcessCancelledException();
        }
        final l = line.trim();
        if (l.isEmpty) continue;
        final parts = l.split(',');
        // skip frames before nominal start (segments > 0 seek to prev keyframe)
        if (i > 0) {
          final pts = double.tryParse(parts[0]);
          if (pts != null && pts < start - 0.001) continue;
        }
        // detect resolution change in real-time
        if (parts.length >= 3) {
          final pts = double.tryParse(parts[0]);
          final w = int.tryParse(parts[1]);
          final h = int.tryParse(parts[2]);
          if (pts != null && w != null && h != null) {
            if (lastW != null && (w != lastW || h != lastH)) {
              onResolutionChange?.call(pts, w, h);
            }
            lastW = w;
            lastH = h;
          }
        }
        outputs[i].writeln(l);
        frameCount++;
        onFrame?.call(i, frameCount);
      }

      final exitCode = await process.exitCode;
      if (exitCode != 0) {
        if (isCancelled != null && isCancelled()) {
          throw ProcessCancelledException();
        }
        final msg = stderrLines.join('\n');
        debugPrint('[ffprobe segment $i] FAILED exit=$exitCode stderr=$msg');
        throw Exception('ffprobe segment $i error (exit $exitCode): $msg');
      }
    });

    try {
      await Future.wait(futures);
    } catch (e) {
      for (final p in _processes) { try { p.kill(); } catch (_) {} }
      _processes.clear();
      rethrow;
    } finally {
      _processes.clear();
    }

    final merged = ResolutionAnalyzer.mergeCsvSegments(
      outputs.map((o) => o.toString()).toList(),
    );
    debugPrint('[VideoProcessor] analyzeResolutionsParallel done: total frames=$frameCount');
    return merged;
  }

  static Future<Uint8List> extractFrameRaw(String videoPath, double time) async {
    final tmp = await _getTempDir();
    final outPath = '${tmp.path}/frame_${time.toStringAsFixed(3)}.gray';
    final args = [
      '-y', '-ss', time.toStringAsFixed(3),
      '-i', videoPath,
      '-vframes', '1',
      '-f', 'rawvideo',
      '-pix_fmt', 'gray',
      '-s', '32x32',
      outPath,
    ];

    await _execFFmpeg(args);

    final file = File(outPath);
    final bytes = await file.readAsBytes();
    if (bytes.length != 1024) {
      await file.delete();
      throw Exception('Expected 1024 bytes, got ${bytes.length}');
    }
    await file.delete();
    return bytes;
  }

  /// Stream raw frames at regular intervals within a time range.
  /// Calls [onFrameBytes] for each extracted frame in real time.
  /// Returns total frame count (frames are NOT accumulated in memory).
  static Future<int> streamFramesRawBatch(
    String videoPath,
    double startTime,
    double endTime,
    double outputFps, {
    void Function(Uint8List frame, int frameIndex)? onFrameBytes,
    bool Function()? isCancelled,
  }) async {
    await _initPaths();
    final args = [
      '-v', 'error',
      '-ss', startTime.toStringAsFixed(3),
      '-to', endTime.toStringAsFixed(3),
      '-i', videoPath,
      '-r', outputFps.toStringAsFixed(3),
      '-f', 'rawvideo',
      '-pix_fmt', 'gray',
      '-s', '32x32',
      '-',
    ];
    debugPrint('[streamFramesRawBatch] start=$startTime end=$endTime outputFps=$outputFps');
    final process = await Process.start(_ffmpegPath!, args);
    _processes.add(process);

    int frameIndex = 0;
    final stderrLines = <String>[];
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach((l) => stderrLines.add(l));

    // Buffer incoming bytes, assemble into 1024-byte frames
    final buffer = <int>[];
    int offset = 0;
    await for (final chunk in process.stdout) {
      if (isCancelled != null && isCancelled()) {
        process.kill();
        throw ProcessCancelledException();
      }
      buffer.addAll(chunk);
      while (buffer.length - offset >= 1024) {
        final frame = Uint8List.fromList(buffer.sublist(offset, offset + 1024));
        offset += 1024;
        frameIndex++;
        onFrameBytes?.call(frame, frameIndex);
      }
      if (offset > 65536) {
        buffer.removeRange(0, offset);
        offset = 0;
      }
    }

    final exitCode = await process.exitCode;
    if (exitCode != 0) {
      final msg = stderrLines.join('\n');
      debugPrint('[streamFramesRawBatch] FAILED exit=$exitCode stderr=$msg');
      throw Exception('batch frame extraction failed (exit $exitCode): $msg');
    }
    debugPrint('[streamFramesRawBatch] done: $frameIndex frames');
    return frameIndex;
  }

  static Future<Uint8List> extractFrameJpeg(String videoPath, double time) async {
    final tmp = await _getTempDir();
    final outPath = '${tmp.path}/frame_${time.toStringAsFixed(3)}.jpg';
    final args = [
      '-y', '-ss', time.toStringAsFixed(3),
      '-i', videoPath,
      '-vframes', '1',
      '-q:v', '2',
      outPath,
    ];

    await _execFFmpeg(args);

    final file = File(outPath);
    final bytes = await file.readAsBytes();
    await file.delete();
    return bytes;
  }

  static Future<double> getFps(String videoPath) async {
    final args = [
      '-v', 'error',
      '-select_streams', 'v:0',
      '-show_entries', 'stream=r_frame_rate',
      '-of', 'default=nw=1:nokey=1',
      videoPath,
    ];

    final output = (await _execFFprobe(args)).trim();
    if (output.contains('/')) {
      final parts = output.split('/');
      return double.parse(parts[0]) / double.parse(parts[1]);
    }
    return double.tryParse(output) ?? 25.0;
  }

  static Future<double> getDuration(String videoPath) async {
    final args = [
      '-v', 'error',
      '-show_entries', 'format=duration',
      '-of', 'default=nw=1:nokey=1',
      videoPath,
    ];

    return double.tryParse((await _execFFprobe(args)).trim()) ?? 0.0;
  }

  static Future<void> trimAndConcat(
    String inputPath,
    String outputPath,
    List<AdInterval> intervals,
  ) async {
    if (intervals.isEmpty) {
      throw Exception('No segments to keep');
    }

    if (intervals.length == 1) {
      await _execFFmpeg([
        '-y',
        '-ss', intervals[0].start.toStringAsFixed(3),
        '-to', intervals[0].end.toStringAsFixed(3),
        '-i', inputPath,
        '-c', 'copy',
        '-avoid_negative_ts', 'make_zero',
        outputPath,
      ]);
      return;
    }

    final tmp = await _getTempDir();
    final parts = <String>[];

    try {
      for (int i = 0; i < intervals.length; i++) {
        if (_cancelRequested) throw ProcessCancelledException();
        final partPath = '${tmp.path}/part_${i.toString().padLeft(3, '0')}.ts';
        await _execFFmpeg([
          '-y',
          '-ss', intervals[i].start.toStringAsFixed(3),
          '-to', intervals[i].end.toStringAsFixed(3),
          '-i', inputPath,
          '-c', 'copy',
          partPath,
        ]);
        parts.add(partPath);
      }

      if (_cancelRequested) throw ProcessCancelledException();

      final concatPath = '${tmp.path}/concat.txt';
      final buf = StringBuffer();
      for (final p in parts) {
        buf.writeln("file '${p.replaceAll("'", "'\\''")}'");
      }
      await File(concatPath).writeAsString(buf.toString());

      await _execFFmpeg([
        '-y',
        '-f', 'concat',
        '-safe', '0',
        '-i', concatPath,
        '-c', 'copy',
        outputPath,
      ]);
    } finally {
      for (final p in parts) {
        try { await File(p).delete(); } catch (_) {}
      }
      final concatFile = File('${tmp.path}/concat.txt');
      if (concatFile.existsSync()) {
        try { await concatFile.delete(); } catch (_) {}
      }
    }
  }

  static Future<Directory> _getTempDir() async {
    if (Platform.isAndroid) {
      final dir = await getTemporaryDirectory();
      final sub = Directory('${dir.path}/ads_remover');
      if (!sub.existsSync()) await sub.create(recursive: true);
      return sub;
    } else {
      return Directory.systemTemp.createTemp('ads_remover_');
    }
  }

  static Future<void> _execFFmpeg(List<String> args) async {
    if (Platform.isAndroid) {
      final session = await FFmpegKit.executeWithArguments(args);
      if (!ReturnCode.isSuccess(await session.getReturnCode())) {
        final logs = await session.getAllLogsAsString();
        throw Exception('FFmpeg failed: $logs');
      }
    } else {
      await _initPaths();
      final result = await Process.run(_ffmpegPath!, args);
      if (result.exitCode != 0) {
        throw Exception('ffmpeg error (exit ${result.exitCode})');
      }
    }
  }

  static Future<String> _execFFprobe(List<String> args) async {
    if (Platform.isAndroid) {
      final session = await FFprobeKit.executeWithArguments(args);
      if (!ReturnCode.isSuccess(await session.getReturnCode())) {
        final logs = await session.getAllLogsAsString();
        throw Exception('FFprobe failed: $logs');
      }
      return (await session.getOutput()) ?? '';
    } else {
      await _initPaths();
      final result = await Process.run(_ffprobePath!, args);
      if (result.exitCode != 0) {
        throw Exception('ffprobe error (exit ${result.exitCode}): ${result.stderr}');
      }
      return result.stdout as String;
    }
  }
}

class ProcessCancelledException implements Exception {
  @override
  String toString() => 'Process cancelled by user';
}
