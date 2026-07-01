import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/video_processor.dart';
import 'processing_state.dart';

class TimeSelectorPage extends StatefulWidget {
  final String videoPath;

  const TimeSelectorPage({super.key, required this.videoPath});

  @override
  State<TimeSelectorPage> createState() => _TimeSelectorPageState();
}

class _TimeSelectorPageState extends State<TimeSelectorPage> {
  double _totalDuration = 0;
  double _currentTime = 0;
  double _startTime = 0;
  double _endTime = 0;
  bool _startSet = false;
  bool _endSet = false;
  Uint8List? _previewBytes;
  bool _loading = false;

  final _hCtrl = TextEditingController();
  final _mCtrl = TextEditingController();
  final _sCtrl = TextEditingController();
  bool _syncing = false; // prevent loop when updating text from slider

  @override
  void initState() {
    super.initState();
    _loadDuration();
  }

  @override
  void dispose() {
    _hCtrl.dispose();
    _mCtrl.dispose();
    _sCtrl.dispose();
    super.dispose();
  }

  void _syncTextFromTime(double t) {
    _syncing = true;
    final h = t ~/ 3600;
    final m = (t % 3600) ~/ 60;
    final s = t % 60;
    _hCtrl.text = h.toString().padLeft(2, '0');
    _mCtrl.text = m.toString().padLeft(2, '0');
    _sCtrl.text = s.toStringAsFixed(0).padLeft(2, '0');
    _syncing = false;
  }

  double _parseTimeFromText() {
    final h = int.tryParse(_hCtrl.text) ?? 0;
    final m = int.tryParse(_mCtrl.text) ?? 0;
    final s = double.tryParse(_sCtrl.text) ?? 0;
    return h * 3600.0 + m * 60.0 + s;
  }

  void _applyTextTime() {
    if (_syncing) return;
    final t = _parseTimeFromText().clamp(0.0, _totalDuration);
    setState(() => _currentTime = t);
    _syncTextFromTime(t);
    _updatePreview(t);
  }

  Future<void> _loadDuration() async {
    final dur = await VideoProcessor.getDuration(widget.videoPath);
    setState(() {
      _totalDuration = dur;
      _endTime = dur;
      _syncTextFromTime(0);
    });
    _updatePreview(0);
  }

  Future<void> _updatePreview(double time) async {
    setState(() => _loading = true);
    try {
      final bytes = await VideoProcessor.extractFrameJpeg(widget.videoPath, time);
      setState(() {
        _previewBytes = bytes;
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('选取广告时间段')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Expanded(
              flex: 3,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: _previewBytes != null
                    ? Image.memory(
                        _previewBytes!,
                        key: ValueKey(_previewBytes),
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => const Center(
                          child: Text('预览加载失败', style: TextStyle(color: Colors.white54)),
                        ),
                      )
                    : const Center(
                        child: Text('加载中...', style: TextStyle(color: Colors.white54)),
                      ),
              ),
            ),
            const SizedBox(height: 16),
            Opacity(
              opacity: _loading ? 1.0 : 0.0,
              child: const LinearProgressIndicator(),
            ),
            Slider(
              value: _currentTime,
              min: 0,
              max: _totalDuration > 0 ? _totalDuration : 1,
              onChanged: (v) {
                setState(() {
                  _currentTime = v;
                  _syncTextFromTime(v);
                });
              },
              onChangeEnd: (v) {
                _updatePreview(v);
              },
            ),
            // Editable time input
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _TimeField(ctrl: _hCtrl, label: '时', onChanged: (_) => _applyTextTime()),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4),
                  child: Text(':', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                ),
                _TimeField(ctrl: _mCtrl, label: '分', onChanged: (_) => _applyTextTime()),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4),
                  child: Text(':', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                ),
                _TimeField(ctrl: _sCtrl, label: '秒', onChanged: (_) => _applyTextTime(), isSeconds: true),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton.icon(
                  onPressed: () {
                    setState(() {
                      _startTime = _currentTime;
                      _startSet = true;
                    });
                  },
                  icon: const Icon(Icons.check),
                  label: const Text('设为开始'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: () {
                    setState(() {
                      _endTime = _currentTime;
                      _endSet = true;
                    });
                  },
                  icon: const Icon(Icons.check),
                  label: const Text('设为结束'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    _startSet ? _fmtTime(_startTime) : '--:--:--',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: _startSet ? Colors.blue : Colors.grey,
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Text('~', style: TextStyle(fontSize: 24)),
                  ),
                  Text(
                    _endSet ? _fmtTime(_endTime) : '--:--:--',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: _endSet ? Colors.red : Colors.grey,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _startSet && _endSet ? () => _confirmSelection(context) : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('确定'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _confirmSelection(BuildContext context) {
    final start = _startTime < _endTime ? _startTime : _endTime;
    final end = _startTime < _endTime ? _endTime : _startTime;
    context.read<ProcessingState>().addManualSample(widget.videoPath, start, end);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('样本已添加: ${_fmtTime(start)} ~ ${_fmtTime(end)}')),
    );
    Navigator.pop(context);
  }

  String _fmtTime(double s) {
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${sec.toStringAsFixed(0).padLeft(2, '0')}';
  }
}

class _TimeField extends StatelessWidget {
  final TextEditingController ctrl;
  final String label;
  final ValueChanged<String> onChanged;
  final bool isSeconds;

  const _TimeField({
    required this.ctrl,
    required this.label,
    required this.onChanged,
    this.isSeconds = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 56,
      child: TextField(
        controller: ctrl,
        keyboardType: TextInputType.numberWithOptions(decimal: isSeconds),
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        decoration: InputDecoration(
          contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          labelText: label,
          labelStyle: const TextStyle(fontSize: 10),
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        onChanged: onChanged,
      ),
    );
  }
}
