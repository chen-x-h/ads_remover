import 'dart:convert' show JsonEncoder;
import 'dart:io' show File, Directory;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../models/ad_sample.dart';
import '../models/ad_interval.dart';
import '../models/ad_detection_result.dart';
import '../core/video_processor.dart';
import '../core/resolution_analyzer.dart';
import '../core/ad_detector.dart';
import '../core/phash.dart';
import '../db/database.dart';

enum ProcessingMode { resolution, manual, database }

enum ProcessStatus { idle, processing, done, error, cancelled }

class ProcessingState extends ChangeNotifier {
  ProcessStatus status = ProcessStatus.idle;
  ProcessingMode mode = ProcessingMode.resolution;
  String? currentVideoPath;
  String? outputVideoPath;
  String? jsonReportPath;
  String log = '';
  String progressLine = '';
  double progress = 0;
  String? errorMessage;

  // store for json export
  List<AdInterval> _keepIntervals = [];
  List<RemovedSegment> _removedSegments = [];
  double _totalDuration = 0;
  bool keyframeOnly = false;
  int parallelism = 4;
  double? detectStartTime;
  double? detectEndTime;

  String outputDirName = 'clean';

  // Detection review flow (database mode)
  List<AdDetectionResult>? detectionResults;
  String? detectionReportPath;

  void toggleFrames(bool v) {
    keyframeOnly = v;
    notifyListeners();
  }

  void setParallelism(int v) {
    parallelism = v.clamp(1, 16);
    notifyListeners();
  }

  void setDetectRange(double? start, double? end) {
    detectStartTime = start;
    detectEndTime = end;
    notifyListeners();
  }

  void setMode(ProcessingMode m) {
    mode = m;
    clearLog();
    notifyListeners();
  }

  void appendLog(String msg) {
    log += '$msg\n';
    progressLine = '';
    notifyListeners();
  }

  void setProgressLine(String msg) {
    progressLine = msg;
    notifyListeners();
  }

  void clearLog() {
    log = '';
    progressLine = '';
    progress = 0;
    status = ProcessStatus.idle;
    errorMessage = null;
    outputVideoPath = null;
    jsonReportPath = null;
    _keepIntervals = [];
    _removedSegments = [];
    _totalDuration = 0;
    detectStartTime = null;
    detectEndTime = null;
    detectionResults = null;
    detectionReportPath = null;
    notifyListeners();
  }

  void cancel() {
    VideoProcessor.cancelCurrentProcess();
    status = ProcessStatus.cancelled;
    appendLog('User cancelled processing');
    errorMessage = null;
    notifyListeners();
  }

  Future<void> processVideo(String videoPath) async {
    currentVideoPath = videoPath;
    VideoProcessor.resetCancel();
    status = ProcessStatus.processing;
    progress = 0;
    log = '';
    errorMessage = null;
    outputVideoPath = null;
    jsonReportPath = null;
    notifyListeners();

    try {
      switch (mode) {
        case ProcessingMode.resolution:
          await _processByResolution(videoPath);
        case ProcessingMode.manual:
          throw Exception('Manual mode: use time selector GUI first');
        case ProcessingMode.database:
          await _processByDatabase(videoPath);
      }

      if (VideoProcessor.isCancelled) {
        status = ProcessStatus.cancelled;
        return;
      }

      await _writeJsonReport(videoPath);

      status = ProcessStatus.done;
      progress = 1.0;
    } catch (e) {
      if (e is ProcessCancelledException) {
        status = ProcessStatus.cancelled;
        appendLog('User cancelled processing');
      } else {
        status = ProcessStatus.error;
        errorMessage = e.toString();
        appendLog('ERROR: $e');
      }
    }

    notifyListeners();
  }

  Future<void> _processByResolution(String videoPath) async {
    // phase 1: count frames for progress
    appendLog('Estimating frame count (${keyframeOnly ? "keyframes" : "all frames"})...');
    final totalFrames = await VideoProcessor.getFrameCount(videoPath, keyframeOnly: keyframeOnly);
    if (VideoProcessor.isCancelled) return;
    appendLog('Estimated total: $totalFrames');
    progress = 0.02;
    notifyListeners();

    // phase 2: streaming analysis (0.02 ~ 0.30)
    appendLog('Analyzing frame resolutions...');
    final csv = await VideoProcessor.analyzeResolutions(
      videoPath,
      keyframeOnly: keyframeOnly,
      onFrame: (count) {
        if (VideoProcessor.isCancelled) return;
        if (totalFrames > 0) {
          progress = 0.02 + 0.28 * (count / totalFrames);
          final pct = (count * 100 / totalFrames).toStringAsFixed(1);
          setProgressLine('  $modeStr frame $count/$totalFrames ($pct%)');
        }
        notifyListeners();
      },
      onResolutionChange: (pts, w, h) {
        appendLog('  突变: ${_fmtTime(pts)} → ${w}x$h');
      },
    );

    if (VideoProcessor.isCancelled) return;
    final frames = ResolutionAnalyzer.parseFfprobeOutput(csv);
    if (frames.isEmpty) throw Exception('No frames detected');
    appendLog('Frames analyzed: ${frames.length}');
    progress = 0.30;
    notifyListeners();

    if (VideoProcessor.isCancelled) return;
    final segments = ResolutionAnalyzer.segmentByResolution(
      frames,
      onSegment: (seg, pts) {
        appendLog('  分段: ${seg.width}x${seg.height} @ ${_fmtTime(pts)}');
      },
    );
    appendLog('Resolution segments: ${segments.length}');
    progress = 0.40;
    notifyListeners();

    if (VideoProcessor.isCancelled) return;
    final mainRes = ResolutionAnalyzer.findMainResolution(segments, frames);
    appendLog('Main resolution: ${mainRes.$1}x${mainRes.$2}');
    progress = 0.45;
    notifyListeners();

    if (VideoProcessor.isCancelled) return;
    final (keep, removed) = ResolutionAnalyzer.buildIntervals(
      frames, segments, mainRes,
      onAdCandidate: (rs) {
        appendLog('发现异常: ${_fmt(rs.start)} ~ ${_fmt(rs.end)} (${rs.reason})');
      },
    );

    _keepIntervals = keep;
    _removedSegments = removed;
    _totalDuration = frames.last.ptsTime;
    progress = 0.50;
    notifyListeners();

    if (VideoProcessor.isCancelled) return;

    if (removed.isEmpty) {
      appendLog('No ads detected, nothing to remove.');
      final outDir = await _ensureOutputDirs(videoPath);
      final out = '${outDir.path}/not_detected_${p.basename(videoPath)}';
      await File(videoPath).copy(out);
      outputVideoPath = out;
      progress = 1.0;
      return;
    }

    for (final r in removed) {
      appendLog('Remove: ${_fmt(r.start)} ~ ${_fmt(r.end)} (${r.reason})');
    }

    if (keep.isEmpty) throw Exception('No content to keep');

    final input = File(videoPath);
    final outDir = await _ensureOutputDirs(videoPath);
    final output = '${outDir.path}/${outputDirName}_${p.basename(input.path)}';
    outputVideoPath = output;

    appendLog('Trimming ${keep.length} segments...');
    progress = 0.60;
    notifyListeners();

    if (VideoProcessor.isCancelled) return;
    await VideoProcessor.trimAndConcat(videoPath, output, keep);
    if (VideoProcessor.isCancelled) return;
    appendLog('Done! Output: $output');
    progress = 0.95;
    notifyListeners();
  }

  /// Detection-only step with full status/error handling (database mode)
  Future<void> processOnlyDetection(String videoPath) async {
    currentVideoPath = videoPath;
    VideoProcessor.resetCancel();
    status = ProcessStatus.processing;
    progress = 0;
    errorMessage = null;
    outputVideoPath = null;
    notifyListeners();
    try {
      await runDetection(videoPath);
      if (VideoProcessor.isCancelled) {
        status = ProcessStatus.cancelled;
        return;
      }
      status = ProcessStatus.done;
      progress = 1.0;
    } catch (e) {
      if (e is ProcessCancelledException) {
        status = ProcessStatus.cancelled;
        appendLog('User cancelled processing');
      } else {
        status = ProcessStatus.error;
        errorMessage = e.toString();
        appendLog('ERROR: $e');
      }
    }
    notifyListeners();
  }

  /// Detection-only step (database mode): writes results + frame images + JSON
  Future<void> runDetection(String videoPath) async {
    final samples = await DatabaseHelper.instance.getSamples();
    if (VideoProcessor.isCancelled) return;
    if (samples.isEmpty) {
      appendLog('No ad samples in database. Add samples first.');
      return;
    }

    appendLog('Loaded ${samples.length} ad samples');
    detectionResults = null;
    detectionReportPath = null;
    progress = 0;
    notifyListeners();

    final rangeInfo = detectStartTime != null
        ? ' [${_fmtTime(detectStartTime!)} ~ ${_fmtTime(detectEndTime!)}]'
        : '';
    appendLog('Detecting ads$rangeInfo...');

    final detections = await AdDetector.detectAds(
      videoPath, samples,
      detectStart: detectStartTime,
      detectEnd: detectEndTime,
      onProgress: (p, cur, total) {
        if (VideoProcessor.isCancelled) return;
        progress = 0.10 + 0.40 * p;
        final pct = (cur * 100 / total).toStringAsFixed(1);
        setProgressLine('[$cur/$total] $pct%');
        notifyListeners();
      },
      onMatch: (time, name) {
        appendLog('疑似广告: ${_fmt(time)} (样本: $name)');
      },
      isCancelled: () => VideoProcessor.isCancelled,
    );

    if (VideoProcessor.isCancelled) return;
    if (detections.isEmpty) {
      appendLog('No ads detected.');
      final outDir = await _ensureOutputDirs(videoPath);
      final out = '${outDir.path}/not_detected_${p.basename(videoPath)}';
      await File(videoPath).copy(out);
      outputVideoPath = out;
      progress = 1.0;
      return;
    }

    appendLog('Detected ${detections.length} candidates, saving frame images...');

    // Save frame images + verify end frames
    final jsonDir = Directory('${File(videoPath).parent.path}/$outputDirName/json');
    if (!jsonDir.existsSync()) await jsonDir.create(recursive: true);
    final sampleDir = await DatabaseHelper.instance.getSampleDir();

    for (int i = 0; i < detections.length; i++) {
      if (VideoProcessor.isCancelled) return;
      final d = detections[i];
      final sample = samples.firstWhere((s) => s.name == d.sampleName);

      // Save video frame at start time
      final vPath = '${jsonDir.path}/detect_$i.jpg';
      String? vePath;
      bool endOk = false;
      try {
        final jpeg = await VideoProcessor.extractFrameJpeg(videoPath, d.startTime);
        await File(vPath).writeAsBytes(jpeg);
        final endTime = d.startTime + sample.duration;
        for (double off = -2.0; off <= 2.0; off += 0.5) {
          final t = endTime + off;
          if (t < 0 || t > (detectEndTime ?? (await VideoProcessor.getDuration(videoPath)))) continue;
          try {
            final raw = await VideoProcessor.extractFrameRaw(videoPath, t);
            final hash = Phash.compute(raw);
            if (Phash.isSimilar(hash, sample.endFrameHash, threshold: 5)) {
              endOk = true;
              vePath = '${jsonDir.path}/detect_${i}_end.jpg';
              final eJpeg = await VideoProcessor.extractFrameJpeg(videoPath, t);
              await File(vePath!).writeAsBytes(eJpeg);
              break;
            }
          } catch (_) {}
        }
      } catch (_) {}

      final sPath = sampleImagePath(sampleDir, d.sampleName, isStart: true);
      final sePath = sampleImagePath(sampleDir, d.sampleName, isStart: false);

      detections[i] = AdDetectionResult(
        videoPath: d.videoPath,
        sampleName: d.sampleName,
        startTime: d.startTime,
        endTime: d.endTime,
        videoFramePath: vPath,
        videoEndFramePath: vePath,
        sampleFramePath: sPath,
        sampleEndFramePath: sePath,
        endMatched: endOk,
        confirmed: endOk,
      );
      if (!endOk) {
        appendLog('  结尾不匹配: ${_fmt(d.startTime)} (${d.sampleName})');
      }
      if ((i + 1) % 5 == 0 || i == detections.length - 1) {
        progress = 0.50 + 0.20 * ((i + 1) / detections.length);
        setProgressLine('  verifying ${i + 1}/${detections.length}');
        notifyListeners();
      }
    }

    detectionResults = detections;

    // Save JSON report
    final jsonPath = '${jsonDir.path}/detections.json';
    final jsonList = detections.map((d) => d.toJson()).toList();
    await File(jsonPath).writeAsString(JsonEncoder.withIndent('  ').convert(jsonList));
    detectionReportPath = jsonPath;

    appendLog('Detection report saved: $jsonPath');
    progress = 0.70;
    notifyListeners();
  }

  /// Trim step with full status/error handling
  Future<void> processOnlyTrimming(String videoPath) async {
    currentVideoPath = videoPath;
    VideoProcessor.resetCancel();
    status = ProcessStatus.processing;
    progress = 0.7;
    errorMessage = null;
    notifyListeners();
    try {
      await runTrimming(videoPath);
      if (VideoProcessor.isCancelled) {
        status = ProcessStatus.cancelled;
        return;
      }
      status = ProcessStatus.done;
      progress = 1.0;
    } catch (e) {
      if (e is ProcessCancelledException) {
        status = ProcessStatus.cancelled;
        appendLog('User cancelled processing');
      } else {
        status = ProcessStatus.error;
        errorMessage = e.toString();
        appendLog('ERROR: $e');
      }
    }
    notifyListeners();
  }

  /// Trim using confirmed detection results
  Future<void> runTrimming(String videoPath) async {
    final results = detectionResults;
    if (results == null || results.isEmpty) {
      appendLog('No detection results to trim from.');
      return;
    }

    final confirmed = results.where((r) => r.confirmed).toList();
    if (confirmed.isEmpty) {
      appendLog('No confirmed detections.');
      return;
    }

    _totalDuration = await VideoProcessor.getDuration(videoPath);
    if (VideoProcessor.isCancelled) return;

    // Build keep intervals (inverse of ad ranges)
    double currentPos = 0;
    final keep = <AdInterval>[];
    for (final d in confirmed) {
      final start = d.startTime < d.endTime ? d.startTime : d.endTime;
      final end = d.startTime < d.endTime ? d.endTime : d.startTime;
      if (start > currentPos) {
        keep.add(AdInterval(currentPos, start));
      }
      currentPos = end;
    }
    if (currentPos < _totalDuration) {
      keep.add(AdInterval(currentPos, _totalDuration));
    }

    if (keep.isEmpty) throw Exception('Entire video is ads');

    _keepIntervals = keep;
    _removedSegments = confirmed.map((d) => RemovedSegment(
      d.startTime < d.endTime ? d.startTime : d.endTime,
      d.startTime < d.endTime ? d.endTime : d.startTime,
      'database match: ${d.sampleName}',
    )).toList();

    for (final d in confirmed) {
      appendLog('Ad: ${_fmt(d.startTime)} ~ ${_fmt(d.endTime)} (${d.sampleName})');
    }

    final input = File(videoPath);
    final outDir = await _ensureOutputDirs(videoPath);
    final output = '${outDir.path}/${outputDirName}_${p.basename(input.path)}';
    outputVideoPath = output;

    appendLog('Trimming ${keep.length} segments...');
    progress = 0.75;
    notifyListeners();

    if (VideoProcessor.isCancelled) return;
    await VideoProcessor.trimAndConcat(videoPath, output, keep);
    if (VideoProcessor.isCancelled) return;
    appendLog('Done! Output: $output');
    progress = 0.95;
    notifyListeners();
  }

  String sampleImagePath(Directory sampleDir, String name, {required bool isStart}) {
    final prefix = isStart ? 'temp_start_' : 'temp_end_';
    return '${sampleDir.path}/$prefix$name.jpg';
  }

  // Legacy full process (kept for resolution mode)
  Future<void> _processByDatabase(String videoPath) async {
    await runDetection(videoPath);
    if (VideoProcessor.isCancelled) return;
    if (detectionResults != null && detectionResults!.isNotEmpty) {
      await runTrimming(videoPath);
    }
  }

  Future<void> _writeJsonReport(String videoPath) async {
    final input = File(videoPath);
    await _ensureOutputDirs(videoPath);
    final jsonPath = '${input.parent.path}/$outputDirName/json/${p.basenameWithoutExtension(input.path)}_ads_report.json';

    final report = <String, dynamic>{
      'input_file': videoPath,
      'output_file': outputVideoPath,
      'mode': mode.name,
      'processed_at': DateTime.now().toIso8601String(),
      'total_duration': '${_fmtTime(_totalDuration)} (${_totalDuration}s)',
      'ads_removed': _removedSegments.map((r) => {
        'start': _fmtTime(r.start),
        'end': _fmtTime(r.end),
        'duration': '${_fmtTime(r.end - r.start)} (${(r.end - r.start).toStringAsFixed(1)}s)',
        'reason': r.reason,
      }).toList(),
      'segments_kept': _keepIntervals.map((k) => {
        'start': _fmtTime(k.start),
        'end': _fmtTime(k.end),
        'duration': '${_fmtTime(k.duration)} (${k.duration.toStringAsFixed(1)}s)',
      }).toList(),
    };

    await File(jsonPath).writeAsString(JsonEncoder.withIndent('  ').convert(report));

    jsonReportPath = jsonPath;
    appendLog('Report saved: $jsonPath');
    notifyListeners();
  }

  Future<void> addManualSample(String videoPath, double startTime, double endTime) async {
    final name = '${DateTime.now().millisecondsSinceEpoch}_manual';
    final startHash = await _computeHash(videoPath, startTime);
    final endHash = await _computeHash(videoPath, endTime);

    final sample = AdSample(
      name: name,
      videoPath: videoPath,
      startFrameHash: startHash,
      endFrameHash: endHash,
      duration: endTime - startTime,
    );

    await DatabaseHelper.instance.addSample(sample);

    final sampleDir = await DatabaseHelper.instance.getSampleDir();
    final startJpeg = await VideoProcessor.extractFrameJpeg(videoPath, startTime);
    final endJpeg = await VideoProcessor.extractFrameJpeg(videoPath, endTime);
    await File('${sampleDir.path}/temp_start_$name.jpg').writeAsBytes(startJpeg);
    await File('${sampleDir.path}/temp_end_$name.jpg').writeAsBytes(endJpeg);

    appendLog('Sample added: $name');
    notifyListeners();
  }

  Future<String> _computeHash(String videoPath, double time) async {
    final raw = await VideoProcessor.extractFrameRaw(videoPath, time);
    return Phash.compute(raw);
  }

  String get modeStr => keyframeOnly ? 'key' : 'all';

  /// Create output dirs under video's parent: [outputDirName]/ and [outputDirName]/json/
  Future<Directory> _ensureOutputDirs(String videoPath) async {
    final parent = File(videoPath).parent.path;
    final dir = Directory('$parent/$outputDirName');
    if (!dir.existsSync()) await dir.create(recursive: true);
    final jsonDir = Directory('$parent/$outputDirName/json');
    if (!jsonDir.existsSync()) await jsonDir.create(recursive: true);
    return dir;
  }

  String _fmtTime(double s) {
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${sec.toStringAsFixed(0).padLeft(2, '0')}';
  }

  String _fmt(double s) {
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${sec.toStringAsFixed(3).padLeft(6, '0')}';
  }
}
