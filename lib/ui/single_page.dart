import 'dart:io' show Platform, Directory, File;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:provider/provider.dart';
import 'package:file_selector/file_selector.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import '../core/video_processor.dart';
import 'processing_state.dart';
import 'time_selector_page.dart';
import 'review_page.dart';

class SinglePage extends StatefulWidget {
  final String? batchDir;
  final List<File>? batchVideos;

  const SinglePage({super.key, this.batchDir, this.batchVideos});

  @override
  State<SinglePage> createState() => _SinglePageState();
}

class _SinglePageState extends State<SinglePage> {
  final ScrollController _logScrollCtrl = ScrollController();
  bool _fileSelected = false;
  String _fileName = '';
  double _duration = 0;
  int _batchIndex = 0;
  int _batchTotal = 0;
  List<File>? _batchFiles;
  Set<int> _batchSelected = {};
  final _rangeSH = TextEditingController();
  final _rangeSM = TextEditingController();
  final _rangeSS = TextEditingController();
  final _rangeEH = TextEditingController();
  final _rangeEM = TextEditingController();
  final _rangeES = TextEditingController();
  final _outputDirCtrl = TextEditingController(text: 'clean');

  bool get _isBatch => _batchFiles != null && _batchFiles!.isNotEmpty;

  @override
  void initState() {
    super.initState();
    final videos = widget.batchVideos;
    if (videos != null && videos.isNotEmpty) {
      setState(() {
        _batchFiles = videos;
        _batchSelected = Set.from(List.generate(videos.length, (i) => i));
        _batchTotal = videos.length;
        _fileSelected = true;
        _fileName = videos.first.path;
      });
      _loadDuration(videos.first.path);
    }
  }

  @override
  void dispose() {
    _logScrollCtrl.dispose();
    _rangeSH.dispose();
    _rangeSM.dispose();
    _rangeSS.dispose();
    _rangeEH.dispose();
    _rangeEM.dispose();
    _rangeES.dispose();
    _outputDirCtrl.dispose();
    super.dispose();
  }

  void _scrollLogBottom() {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (_logScrollCtrl.hasClients) {
        _logScrollCtrl.jumpTo(_logScrollCtrl.position.maxScrollExtent);
      }
    });
  }

  Future<void> _pickFile() async {
    if (Platform.isAndroid || Platform.isIOS) {
      final picker = ImagePicker();
      final result = await picker.pickVideo(source: ImageSource.gallery);
      if (result != null) {
        setState(() {
          _fileSelected = true;
          _fileName = result.path;
        });
        _loadDuration(result.path);
      }
    } else {
      final result = await openFile(
        acceptedTypeGroups: [
          XTypeGroup(
            label: 'Video',
            extensions: ['mp4', 'mkv', 'avi', 'mov', 'flv', 'webm', 'm4v', 'ts'],
          ),
        ],
      );
      if (result != null) {
        setState(() {
          _fileSelected = true;
          _fileName = result.path;
        });
        _loadDuration(result.path);
      }
    }
  }

  Future<void> _runBatch() async {
    final files = _batchFiles;
    if (files == null || files.isEmpty) return;
    final state = context.read<ProcessingState>();
    final indices = _batchSelected.toList()..sort();
    for (int idx = 0; idx < indices.length; idx++) {
      if (!mounted) break;
      final i = indices[idx];
      setState(() => _batchIndex = idx + 1);
      state.clearLog();
      final vp = files[i].path;
      setState(() {
        _fileSelected = true;
        _fileName = vp;
      });
      await _loadDuration(vp);
      state.appendLog('[$idx/${indices.length}] ${p.basename(vp)}');
      await state.processVideo(vp);
      if (state.status == ProcessStatus.cancelled) break;
    }
    if (mounted) {
      setState(() => _batchTotal = 0);
      state.appendLog(state.status == ProcessStatus.cancelled ? '批量处理已中断' : '批量处理完成');
    }
  }

  Future<void> _loadDuration(String path) async {
    final dur = await VideoProcessor.getDuration(path);
    setState(() {
      _duration = dur;
      _clearDetectRange();
    });
    context.read<ProcessingState>().setDetectRange(null, null);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ProcessingState>();
    _scrollLogBottom();

    return Scaffold(
      appBar: AppBar(title: const Text('处理视频')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.video_file, color: Colors.blue[700]),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _fileSelected
                                ? _fileName.split(Platform.pathSeparator).last
                                : '未选择文件',
                            style: const TextStyle(fontSize: 16),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    if (_duration > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 8, left: 40),
                        child: Text(
                          '时长: ${_fmtDuration(_duration)}',
                          style: TextStyle(color: Colors.grey[600]),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (state.mode == ProcessingMode.manual)
              ElevatedButton.icon(
                onPressed: state.status == ProcessStatus.processing ? null : _pickFile,
                icon: const Icon(Icons.movie),
                label: const Text('选择视频文件'),
              ),
            if (state.mode != ProcessingMode.manual)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: state.status == ProcessStatus.processing ? null : _pickFile,
                        icon: const Icon(Icons.movie),
                        label: const Text('选择文件'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: state.status == ProcessStatus.processing ? null : _pickFolder,
                        icon: const Icon(Icons.folder_open),
                        label: const Text('选择文件夹'),
                      ),
                    ),
                    if (_batchTotal > 0)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: ActionChip(
                          avatar: Icon(Icons.list, size: 14, color: Colors.grey[700]),
                          label: Text('$_batchIndex/$_batchTotal', style: const TextStyle(fontSize: 11)),
                          visualDensity: VisualDensity.compact,
                          onPressed: _showBatchFilesDialog,
                        ),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text('模式: ${_modeName(state.mode)}  ', style: TextStyle(color: Colors.grey[600])),
                if (state.mode == ProcessingMode.resolution)
                  Row(
                    children: [
                      const Text('全帧', style: TextStyle(fontSize: 12)),
                      Switch(
                        value: state.keyframeOnly,
                        onChanged: (v) => state.toggleFrames(v),
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      const Text('关键帧', style: TextStyle(fontSize: 12)),
                    ],
                  ),
              ],
            ),
            if (state.mode != ProcessingMode.manual)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    const Text('输出目录: ', style: TextStyle(fontSize: 12)),
                    SizedBox(
                      width: 100,
                      child: TextField(
                        controller: _outputDirCtrl,
                        style: const TextStyle(fontSize: 12),
                        decoration: const InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (v) {
                          context.read<ProcessingState>().outputDirName =
                              v.isNotEmpty ? v : 'clean';
                        },
                      ),
                    ),
                  ],
                ),
              ),
            if (state.mode == ProcessingMode.database && _fileSelected)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text('检测时段: ', style: TextStyle(fontSize: 12)),
                        _numField(_rangeSH, 4, '时'),
                        const Text(':', style: TextStyle(fontSize: 13)),
                        _numField(_rangeSM, 2, '分'),
                        const Text(':', style: TextStyle(fontSize: 13)),
                        _numField(_rangeSS, 2, '秒'),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 4),
                          child: Text('~', style: TextStyle(fontSize: 14)),
                        ),
                        _numField(_rangeEH, 4, '时'),
                        const Text(':', style: TextStyle(fontSize: 13)),
                        _numField(_rangeEM, 2, '分'),
                        const Text(':', style: TextStyle(fontSize: 13)),
                        _numField(_rangeES, 2, '秒'),
                        IconButton(
                          icon: const Icon(Icons.clear, size: 16),
                          tooltip: '清除范围',
                          onPressed: _clearDetectRange,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 16),
            if (state.mode == ProcessingMode.manual && _fileSelected)
              ElevatedButton.icon(
                onPressed: () => _openTimeSelector(context),
                icon: const Icon(Icons.touch_app),
                label: const Text('选取广告区间'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange,
                  foregroundColor: Colors.white,
                ),
              ),
            if (state.mode == ProcessingMode.database && _fileSelected)
              Column(
                children: [
                  if (!_isBatch && state.detectionResults == null)
                    ElevatedButton.icon(
                      onPressed: state.status != ProcessStatus.processing
                          ? () => state.processOnlyDetection(_fileName)
                          : null,
                      icon: const Icon(Icons.search),
                      label: const Text('开始检测'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        minimumSize: const Size(double.infinity, 48),
                      ),
                    ),
                  if (!_isBatch && state.detectionResults != null)
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: () => _openReview(context),
                            icon: const Icon(Icons.rate_review),
                            label: Text('审核 (${state.detectionResults!.length})'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.orange,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: state.status != ProcessStatus.processing
                                ? () => state.processOnlyTrimming(_fileName)
                                : null,
                            icon: const Icon(Icons.content_cut),
                            label: const Text('裁剪'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                          ),
                        ),
                      ],
                    ),
                  if (_isBatch)
                    ElevatedButton.icon(
                      onPressed: state.status != ProcessStatus.processing
                          ? _runBatch
                          : null,
                      icon: Icon(_batchTotal > 0 && _batchIndex > 0
                          ? Icons.arrow_forward
                          : Icons.play_arrow),
                      label: Text(_batchIndex > 0
                          ? '继续批量处理'
                          : '开始批量处理 (${_batchSelected.length})'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        minimumSize: const Size(double.infinity, 48),
                      ),
                    ),
                  if (state.status == ProcessStatus.processing) ...[
                    const SizedBox(height: 8),
                    ElevatedButton.icon(
                      onPressed: () => state.cancel(),
                      icon: const Icon(Icons.stop),
                      label: const Text('中断'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        minimumSize: const Size(double.infinity, 44),
                      ),
                    ),
                  ],
                ],
              ),
            if (state.mode == ProcessingMode.resolution)
              _isBatch
                  ? ElevatedButton.icon(
                      onPressed: state.status != ProcessStatus.processing ? _runBatch : null,
                      icon: Icon(_batchIndex > 0 ? Icons.arrow_forward : Icons.play_arrow),
                      label: Text(_batchIndex > 0
                          ? '继续批量处理 (${_batchIndex}/${_batchSelected.length})'
                          : '开始批量处理 (${_batchSelected.length})'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        minimumSize: const Size(double.infinity, 48),
                      ),
                    )
                  : Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _fileSelected && state.status != ProcessStatus.processing
                          ? () => state.processVideo(_fileName)
                          : null,
                      icon: Icon(state.status == ProcessStatus.processing
                          ? Icons.hourglass_top
                          : Icons.play_arrow),
                      label: Text(state.status == ProcessStatus.processing ? '处理中...' : '开始处理'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                    ),
                  ),
                  if (state.status == ProcessStatus.processing) ...[
                    const SizedBox(width: 12),
                    ElevatedButton.icon(
                      onPressed: () => state.cancel(),
                      icon: const Icon(Icons.stop),
                      label: const Text('中断'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                    ),
                  ],
                ],
              ),
            const SizedBox(height: 16),
            if (state.status == ProcessStatus.processing) ...[
              LinearProgressIndicator(value: state.progress),
              if (state.progressLine.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    state.progressLine,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: Colors.cyanAccent,
                    ),
                  ),
                ),
            ],
            const SizedBox(height: 12),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey[900],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  controller: _logScrollCtrl,
                  child: SelectableText(
                    state.log.isEmpty ? '等待操作...' : state.log,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: Colors.greenAccent,
                    ),
                  ),
                ),
              ),
            ),
            if (state.status == ProcessStatus.done && state.outputVideoPath != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '✅ 完成!',
                      style: const TextStyle(
                        color: Colors.green,
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text('视频: ${state.outputVideoPath}', style: const TextStyle(fontSize: 12)),
                    if (state.jsonReportPath != null)
                      Text('报告: ${state.jsonReportPath}', style: const TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            if (state.status == ProcessStatus.cancelled)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text(
                  '⏹ 已中断',
                  style: TextStyle(
                    color: Colors.orange,
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                ),
              ),
            if (state.status == ProcessStatus.error)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  '❌ ${state.errorMessage}',
                  style: const TextStyle(color: Colors.red),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickFolder() async {
    final path = await getDirectoryPath();
    if (path == null) return;

    final videos = Directory(path).listSync().whereType<File>().where(
      (f) => ['.mp4', '.mkv', '.avi', '.mov', '.flv', '.webm', '.m4v', '.ts']
          .contains(p.extension(f.path).toLowerCase()),
    ).toList();
    if (videos.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('文件夹中没有视频文件')),
        );
      }
      return;
    }

    setState(() {
      _batchFiles = videos;
      _batchSelected = Set.from(List.generate(videos.length, (i) => i));
      _batchTotal = videos.length;
      _batchIndex = 0;
      _fileSelected = true;
      _fileName = videos.first.path;
    });
    _loadDuration(videos.first.path);
  }

  void _showBatchFilesDialog() {
    final files = _batchFiles;
    if (files == null || files.isEmpty) return;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('文件列表 (${_batchSelected.length}/${files.length})'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: files.length,
              itemBuilder: (_, i) => CheckboxListTile(
                dense: true,
                value: _batchSelected.contains(i),
                title: Text(p.basename(files[i].path), style: const TextStyle(fontSize: 13)),
                subtitle: Text(p.extension(files[i].path), style: const TextStyle(fontSize: 10)),
                controlAffinity: ListTileControlAffinity.trailing,
                onChanged: (v) {
                  setDialogState(() {
                    if (v == true) {
                      _batchSelected.add(i);
                    } else {
                      _batchSelected.remove(i);
                    }
                  });
                },
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: _batchSelected.length == files.length
                  ? null
                  : () => setDialogState(() => _batchSelected.addAll(List.generate(files.length, (i) => i))),
              child: const Text('全选'),
            ),
            TextButton(
              onPressed: _batchSelected.isEmpty
                  ? null
                  : () => setDialogState(() => _batchSelected.clear()),
              child: const Text('全不选'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
  }

  void _openReview(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReviewPage(videoPath: _fileName),
      ),
    );
  }

  void _openTimeSelector(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TimeSelectorPage(videoPath: _fileName),
      ),
    );
  }

  void _applyDetectRange() {
    final sh = _intOr0(_rangeSH.text);
    final sm = _intOr0(_rangeSM.text);
    final ss = _intOr0(_rangeSS.text);
    final eh = _intOr0(_rangeEH.text);
    final em = _intOr0(_rangeEM.text);
    final es = _intOr0(_rangeES.text);
    final start = sh * 3600.0 + sm * 60.0 + ss;
    final end = eh * 3600.0 + em * 60.0 + es;
    if (end > start && (sh + sm + ss > 0 || eh + em + es > 0)) {
      context.read<ProcessingState>().setDetectRange(start, end);
    } else {
      context.read<ProcessingState>().setDetectRange(null, null);
    }
  }

  void _clearDetectRange() {
    for (final c in [_rangeSH, _rangeSM, _rangeSS, _rangeEH, _rangeEM, _rangeES]) {
      c.clear();
    }
    context.read<ProcessingState>().setDetectRange(null, null);
  }

  int _intOr0(String s) => int.tryParse(s.trim()) ?? 0;

  Widget _numField(TextEditingController ctrl, double width, String label) {
    return SizedBox(
      width: 30 + width * 8,
      child: TextField(
        controller: ctrl,
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
        decoration: InputDecoration(
          contentPadding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
          labelText: label,
          labelStyle: const TextStyle(fontSize: 9),
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        onChanged: (_) => _applyDetectRange(),
      ),
    );
  }

  String _modeName(ProcessingMode mode) {
    switch (mode) {
      case ProcessingMode.resolution:
        return '分辨率突变检测';
      case ProcessingMode.manual:
        return '手动选取样本';
      case ProcessingMode.database:
        return '数据库指纹匹配';
    }
  }

  String _fmtDuration(double s) {
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${sec.toStringAsFixed(0).padLeft(2, '0')}';
  }
}
