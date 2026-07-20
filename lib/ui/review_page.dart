import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/time_format.dart';
import '../models/ad_detection_result.dart';
import 'processing_state.dart';

class ReviewPage extends StatefulWidget {
  final String videoPath;
  const ReviewPage({super.key, required this.videoPath});

  @override
  State<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends State<ReviewPage> {
  @override
  Widget build(BuildContext context) {
    final state = context.watch<ProcessingState>();
    final results = state.detectionResults ?? [];

    return Scaffold(
      appBar: AppBar(
        title: Text('审核检测结果 (${results.length})'),
        actions: [
          if (results.any((r) => !r.confirmed))
            TextButton(
              onPressed: _selectAll,
              child: const Text('全选'),
            ),
          if (results.any((r) => r.confirmed))
            TextButton(
              onPressed: _deselectAll,
              child: const Text('全不选'),
            ),
        ],
      ),
      body: results.isEmpty
          ? const Center(child: Text('无检测结果'))
          : ListView.builder(
              itemCount: results.length + 1,
              itemBuilder: (ctx, idx) {
                if (idx == results.length) {
                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: ElevatedButton.icon(
                      onPressed: () => _trim(context),
                      icon: const Icon(Icons.content_cut),
                      label: Text('裁剪确认的 ${results.where((r) => r.confirmed).length} 个广告'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                    ),
                  );
                }
                return _DetectionCard(
                  result: results[idx],
                  onToggle: (v) {
                    state.detectionResults![idx].confirmed = v;
                    state.notifyListeners();
                  },
                );
              },
            ),
    );
  }

  void _selectAll() {
    final state = context.read<ProcessingState>();
    if (state.detectionResults == null) return;
    for (final r in state.detectionResults!) {
      r.confirmed = true;
    }
    state.notifyListeners();
  }

  void _deselectAll() {
    final state = context.read<ProcessingState>();
    if (state.detectionResults == null) return;
    for (final r in state.detectionResults!) {
      r.confirmed = false;
    }
    state.notifyListeners();
  }

  void _trim(BuildContext context) {
    final state = context.read<ProcessingState>();
    final confirmed = state.detectionResults?.where((r) => r.confirmed).toList() ?? [];
    if (confirmed.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('未选择任何广告')),
      );
      return;
    }
    Navigator.pop(context);
    state.processOnlyTrimming(widget.videoPath);
  }
}

class _DetectionCard extends StatelessWidget {
  final AdDetectionResult result;
  final ValueChanged<bool> onToggle;

  const _DetectionCard({required this.result, required this.onToggle});

  void _showImage(BuildContext context, String path, String label) {
    showDialog(
      context: context,
      builder: (_) => Dialog(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.file(File(path), fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Icon(Icons.broken_image, size: 64)),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final h = result.startTime ~/ 3600;
    final m = (result.startTime % 3600) ~/ 60;
    final s = result.startTime % 60;
    final timeStr = '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toStringAsFixed(0).padLeft(2, '0')}';

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Thumbnails (auto-wrap when screen is narrow)
            Expanded(
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  _thumbWithLabel(result.videoFramePath, '视频', () =>
                      _showImage(context, result.videoFramePath!, '视频帧 $timeStr')),
                  if (result.videoEndFramePath != null)
                    _thumbWithLabel(result.videoEndFramePath, '视频尾', () =>
                        _showImage(context, result.videoEndFramePath!, '视频帧(结束) ${fmtPrecise(result.endTime)}')),
                  _thumbWithLabel(result.sampleFramePath, '样本', () =>
                      _showImage(context, result.sampleFramePath!, '样本帧(开始)')),
                  if (result.sampleEndFramePath != null)
                    _thumbWithLabel(result.sampleEndFramePath, '样本尾', () =>
                        _showImage(context, result.sampleEndFramePath!, '样本帧(结束)')),
                ],
              ),
            ),
            const SizedBox(width: 4),
            // Info + end-match indicator + checkbox
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(timeStr, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    const SizedBox(width: 4),
                    Icon(
                      result.endMatched ? Icons.check_circle : Icons.cancel,
                      size: 16,
                      color: result.endMatched ? Colors.green : Colors.red,
                    ),
                  ],
                ),
                Text(result.sampleName, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                Text('~${fmtPrecise(result.endTime)}',
                    style: TextStyle(fontSize: 11, color: result.endMatched ? Colors.green : Colors.red)),
              ],
            ),
            Checkbox(
              value: result.confirmed,
              onChanged: (v) => onToggle(v ?? false),
            ),
          ],
        ),
      ),
    );
  }

  Widget _thumb(String? path, double w, double h) {
    if (path != null && File(path).existsSync()) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Image.file(File(path), width: w, height: h, fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _placeholder(w, h)),
      );
    }
    return _placeholder(w, h);
  }

  Widget _thumbWithLabel(String? path, String label, VoidCallback? onTap) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(onTap: onTap, child: _thumb(path, 80, 60)),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(label, style: TextStyle(fontSize: 9, color: Colors.grey[500])),
        ),
      ],
    );
  }

  Widget _placeholder(double w, double h) {
    return Container(
      width: w, height: h,
      decoration: BoxDecoration(
        color: Colors.grey[200],
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Icon(Icons.broken_image, size: 20, color: Colors.grey),
    );
  }

}
