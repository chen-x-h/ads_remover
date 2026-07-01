import 'package:flutter/foundation.dart';
import '../models/ad_interval.dart';

class _CsvLine {
  final double pts;
  final String raw;
  _CsvLine(this.pts, this.raw);
}

class FrameInfo {
  final double ptsTime;
  final int width;
  final int height;

  FrameInfo(this.ptsTime, this.width, this.height);
}

class Segment {
  final int startIdx;
  final int endIdx;
  final int width;
  final int height;

  Segment(this.startIdx, this.endIdx, this.width, this.height);
}

class ResolutionAnalyzer {
  /// Merge sorted CSV segments, deduplicating boundary frames (tolerance 0.001s).
  static String mergeCsvSegments(List<String> csvs) {
    final lines = <_CsvLine>[];
    for (final csv in csvs) {
      for (final raw in csv.trim().split('\n')) {
        final l = raw.trim();
        if (l.isEmpty) continue;
        final parts = l.split(',');
        final pts = double.tryParse(parts[0]);
        if (pts == null) continue;
        lines.add(_CsvLine(pts, l));
      }
    }
    if (lines.isEmpty) return '';
    lines.sort((a, b) => a.pts.compareTo(b.pts));
    final deduped = <String>[lines.first.raw];
    double lastPts = lines.first.pts;
    for (int i = 1; i < lines.length; i++) {
      if ((lines[i].pts - lastPts).abs() > 0.001) {
        deduped.add(lines[i].raw);
        lastPts = lines[i].pts;
      }
    }
    debugPrint('[ResolutionAnalyzer] mergeCsvSegments: ${lines.length} raw -> ${deduped.length} deduped');
    return deduped.join('\n');
  }

  static List<FrameInfo> parseFfprobeOutput(String csv) {
    final frames = <FrameInfo>[];
    for (final line in csv.trim().split('\n')) {
      final parts = line.split(',');
      if (parts.length < 3) continue;
      final pts = double.tryParse(parts[0]);
      final w = int.tryParse(parts[1]);
      final h = int.tryParse(parts[2]);
      if (pts != null && w != null && h != null && w > 0 && h > 0) {
        frames.add(FrameInfo(pts, w, h));
      }
    }
    return frames;
  }

  static List<Segment> segmentByResolution(
    List<FrameInfo> frames, {
    void Function(Segment seg, double ptsTime)? onSegment,
  }) {
    if (frames.isEmpty) return [];

    final segments = <Segment>[];
    int startIdx = 0;
    var currentRes = (frames[0].width, frames[0].height);

    for (int i = 1; i < frames.length; i++) {
      final res = (frames[i].width, frames[i].height);
      if (res != currentRes) {
        final seg = Segment(startIdx, i - 1, currentRes.$1, currentRes.$2);
        segments.add(seg);
        onSegment?.call(seg, frames[startIdx].ptsTime);
        startIdx = i;
        currentRes = res;
      }
    }
    final seg = Segment(startIdx, frames.length - 1, currentRes.$1, currentRes.$2);
    segments.add(seg);
    onSegment?.call(seg, frames[startIdx].ptsTime);

    return segments;
  }

  static (int, int) findMainResolution(List<Segment> segments, List<FrameInfo> frames) {
    final durations = <(int, int), double>{};

    for (final seg in segments) {
      final dur = frames[seg.endIdx].ptsTime - frames[seg.startIdx].ptsTime;
      final key = (seg.width, seg.height);
      durations[key] = (durations[key] ?? 0.0) + dur;
    }

    return durations.entries.reduce((a, b) => a.value > b.value ? a : b).key;
  }

  static (List<AdInterval>, List<RemovedSegment>) buildIntervals(
    List<FrameInfo> frames,
    List<Segment> segments,
    (int, int) mainRes, {
    double minDuration = 1.0,
    void Function(RemovedSegment seg)? onAdCandidate,
  }) {
    final removed = <RemovedSegment>[];
    final keep = <AdInterval>[];

    for (final seg in segments) {
      final startPts = frames[seg.startIdx].ptsTime;
      final endPts = frames[seg.endIdx].ptsTime;
      final dur = endPts - startPts;

      if (seg.width == mainRes.$1 && seg.height == mainRes.$2) {
        if (dur >= minDuration) {
          keep.add(AdInterval(startPts, endPts));
        } else {
          final rs = RemovedSegment(startPts, endPts, 'too short');
          removed.add(rs);
          onAdCandidate?.call(rs);
        }
      } else {
        final rs = RemovedSegment(startPts, endPts, 'non-main ${seg.width}x${seg.height}');
        removed.add(rs);
        onAdCandidate?.call(rs);
      }
    }

    return (keep, removed);
  }
}

class RemovedSegment {
  final double start;
  final double end;
  final String reason;
  RemovedSegment(this.start, this.end, this.reason);
}
