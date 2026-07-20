import 'dart:async';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import '../models/ad_sample.dart';
import '../models/ad_detection_result.dart';
import 'phash.dart';
import 'video_processor.dart';
import 'time_format.dart';

// --- Worker isolate: receives frame batches, sends progress & matches in real time ---
void _hashWorker(SendPort mainPort) {
  final cmd = ReceivePort();
  mainPort.send(cmd.sendPort);

  List<String> sampleNames = [];
  List<String> sampleHashes = [];
  double timeStep = 0;
  int threshold = 5;
  int frameIdx = 0;
  final starts = <String, List<double>>{};
  int lastProgress = 0;

  void _trySend(dynamic msg) {
    try { mainPort.send(msg); } catch (_) { cmd.close(); }
  }

  cmd.listen((msg) {
    if (msg is List<Object> && sampleNames.isEmpty) {
      sampleNames = (msg[0] as List).cast<String>();
      sampleHashes = (msg[1] as List).cast<String>();
      timeStep = msg[2] as double;
      threshold = msg[3] as int;
      for (final n in sampleNames) starts[n] = [];
      return;
    }

    if (msg is String) {
      if (msg == 'done') {
        _trySend(starts);
        cmd.close();
      } else if (msg == 'cancel') {
        _trySend(starts); // partial results
        cmd.close();
      }
      return;
    }

    // Frame batch
    if (msg is List<Uint8List>) {
      for (int j = 0; j < msg.length; j++) {
        final time = frameIdx * timeStep;
        final hash = Phash.compute(msg[j]);
        for (int si = 0; si < sampleNames.length; si++) {
          if (Phash.isSimilar(hash, sampleHashes[si], threshold: threshold)) {
            final list = starts[sampleNames[si]]!;
            if (list.isEmpty || time - list.last > 1.0) {
              list.add(time);
              _trySend(<dynamic>[time, sampleNames[si]]);
            }
          }
        }
        frameIdx++;
        if (frameIdx - lastProgress >= 50) {
          _trySend(frameIdx);
          lastProgress = frameIdx;
        }
      }
    }
  });
}

class AdDetector {
  /// Detect suspected ad starts via hash matching. Returns detection results
  /// (start times + sample names). No end-frame verification — pure detection.
  static Future<List<AdDetectionResult>> detectAds(
    String videoPath,
    List<AdSample> samples, {
    double fps = 15,
    int threshold = 5,
    double? detectStart,
    double? detectEnd,
    void Function(double progress, int current, int total)? onProgress,
    void Function(double time, String sampleName)? onMatch,
    bool Function()? isCancelled,
  }) async {
    if (samples.isEmpty) return [];

    final duration = await VideoProcessor.getDuration(videoPath);
    if (duration <= 0) return [];

    final originalFps = await VideoProcessor.getFps(videoPath);
    final sampleInterval = (originalFps / fps).ceil().clamp(1, 100);
    final scanDuration = (detectEnd ?? duration) - (detectStart ?? 0.0);
    final totalCheckable = ((scanDuration * originalFps).round() + sampleInterval - 1) ~/ sampleInterval;
    final outputFps = originalFps / sampleInterval;
    final timeStep = 1.0 / outputFps;

    final rangeInfo = detectStart != null
        ? ' [${fmtTime(detectStart!)} ~ ${fmtTime(detectEnd!)}]'
        : '';
    debugPrint('[AdDetector] totalCheckable=$totalCheckable$rangeInfo');

    // Launch background worker Isolate
    final mainPort = ReceivePort();
    await Isolate.spawn(_hashWorker, mainPort.sendPort);

    final workerCompleter = Completer<SendPort>();
    final resultCompleter = Completer<Map<String, List<double>>>();
    bool _cancelled() => isCancelled != null && isCancelled();
    mainPort.listen((msg) {
      if (msg is SendPort) {
        workerCompleter.complete(msg);
      } else if (msg is int) {
        if (_cancelled()) return;
        onProgress?.call(msg / totalCheckable, msg, totalCheckable);
      } else if (msg is List && msg.length == 2) {
        if (_cancelled()) return;
        onMatch?.call(msg[0] as double, msg[1] as String);
      } else if (msg is Map<String, List<double>> && !resultCompleter.isCompleted) {
        resultCompleter.complete(msg);
      }
    });
    final workerPort = await workerCompleter.future;

    workerPort.send(<Object>[
      samples.map((s) => s.name).toList(),
      samples.map((s) => s.startFrameHash).toList(),
      timeStep,
      threshold,
    ]);

    final batch = <Uint8List>[];
    try {
      final extractStart = detectStart ?? 0.0;
      final extractEnd = detectEnd ?? duration;
      await VideoProcessor.streamFramesRawBatch(
        videoPath, extractStart, extractEnd, outputFps,
        isCancelled: isCancelled,
        onFrameBytes: (frame, idx) {
          batch.add(frame);
          if (batch.length >= 100) {
            workerPort.send(List<Uint8List>.from(batch));
            batch.clear();
          }
        },
      );
    } catch (e) {
      debugPrint('[AdDetector] extraction failed: $e');
      if (_cancelled()) {
        workerPort.send('cancel');
        mainPort.close();
        return [];
      }
    }
    if (batch.isNotEmpty) workerPort.send(List<Uint8List>.from(batch));
    workerPort.send('done');

    final raw = await resultCompleter.future
        .timeout(const Duration(seconds: 10), onTimeout: () => <String, List<double>>{});
    mainPort.close();

    debugPrint('[AdDetector] detection done, building results');

    // Build detection results (no end-frame verification — pure detection)
    final results = <AdDetectionResult>[];
    for (final sample in samples) {
      final starts = raw[sample.name] ?? [];
      for (final startTime in starts) {
        results.add(AdDetectionResult(
          videoPath: videoPath,
          sampleName: sample.name,
          startTime: startTime,
          endTime: startTime + sample.duration,
          confirmed: true,
        ));
      }
    }
    results.sort((a, b) => a.startTime.compareTo(b.startTime));
    return results;
  }
}
