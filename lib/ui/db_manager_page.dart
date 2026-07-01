import 'dart:io' show File;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../db/database.dart';
import '../models/ad_sample.dart';

class DbManagerPage extends StatefulWidget {
  const DbManagerPage({super.key});

  @override
  State<DbManagerPage> createState() => _DbManagerPageState();
}

class _DbManagerPageState extends State<DbManagerPage> {
  List<AdSample> _samples = [];
  AdSample? _selected;
  Uint8List? _startImg;
  Uint8List? _endImg;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final samples = await DatabaseHelper.instance.getSamples();
    setState(() {
      _samples = samples;
      _loading = false;
    });
  }

  Future<void> _selectSample(AdSample sample) async {
    setState(() => _selected = sample);
    await _loadImages(sample);
  }

  Future<void> _loadImages(AdSample sample) async {
    final db = DatabaseHelper.instance;
    final startPath = db.sampleImagePath(sample.name, isStart: true);
    final endPath = db.sampleImagePath(sample.name, isStart: false);

    try {
      if (File(startPath).existsSync()) {
        _startImg = await File(startPath).readAsBytes();
      } else {
        _startImg = null;
      }
    } catch (_) {
      _startImg = null;
    }

    try {
      if (File(endPath).existsSync()) {
        _endImg = await File(endPath).readAsBytes();
      } else {
        _endImg = null;
      }
    } catch (_) {
      _endImg = null;
    }

    setState(() {});
  }

  Future<void> _deleteSample(AdSample sample) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('确认删除'),
        content: Text("确定要删除样本 '${sample.name}' 吗？"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await DatabaseHelper.instance.deleteSampleByName(sample.name);
      if (_selected?.name == sample.name) {
        setState(() {
          _selected = null;
          _startImg = null;
          _endImg = null;
        });
      }
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('广告指纹库'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: Row(
        children: [
          SizedBox(
            width: 300,
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _samples.isEmpty
                    ? const Center(child: Text('暂无样本'))
                    : ListView.builder(
                        itemCount: _samples.length,
                        itemBuilder: (_, i) {
                          final sample = _samples[i];
                          final isSelected = _selected?.name == sample.name;
                          return ListTile(
                            selected: isSelected,
                            selectedTileColor: Colors.blue.withAlpha(25),
                            title: Text(sample.name, overflow: TextOverflow.ellipsis),
                            subtitle: Text('${sample.duration.toStringAsFixed(1)}s'),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete, size: 18),
                              onPressed: () => _deleteSample(sample),
                            ),
                            onTap: () => _selectSample(sample),
                          );
                        },
                      ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: _selected == null
                ? const Center(child: Text('选择一个样本查看详情'))
                : Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('名称: ${_selected!.name}',
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 4),
                        Text('时长: ${_selected!.duration.toStringAsFixed(1)} 秒'),
                        const SizedBox(height: 4),
                        Text('开始哈希: ${_selected!.startFrameHash}',
                            style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
                        Text('结束哈希: ${_selected!.endFrameHash}',
                            style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
                        const SizedBox(height: 16),
                        Expanded(
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  children: [
                                    const Text('开头帧', style: TextStyle(fontWeight: FontWeight.bold)),
                                    const SizedBox(height: 8),
                                    Expanded(
                                      child: _startImg != null
                                          ? Image.memory(_startImg!, fit: BoxFit.contain)
                                          : Container(
                                              color: Colors.grey[200],
                                              child: const Center(child: Text('无图片')),
                                            ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  children: [
                                    const Text('结尾帧', style: TextStyle(fontWeight: FontWeight.bold)),
                                    const SizedBox(height: 8),
                                    Expanded(
                                      child: _endImg != null
                                          ? Image.memory(_endImg!, fit: BoxFit.contain)
                                          : Container(
                                              color: Colors.grey[200],
                                              child: const Center(child: Text('无图片')),
                                            ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
