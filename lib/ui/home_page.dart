import 'dart:io' show File, Directory;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;
import 'processing_state.dart';
import 'single_page.dart';
import 'db_manager_page.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ads Remover'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.storage),
            tooltip: '广告指纹库',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const DbManagerPage()),
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '基于FFmpeg的无损广告切除工具',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Colors.grey[600],
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            Expanded(
              child: ListView(
                children: [
                  _ModeCard(
                    icon: Icons.aspect_ratio,
                    title: '1. 分辨率突变检测',
                    subtitle: '自动检测视频中分辨率变化的片段并切除',
                    color: Colors.blue,
                    onTap: () => _openSingle(context, ProcessingMode.resolution),
                    onLongPress: () => _openBatch(context, ProcessingMode.resolution),
                  ),
                  const SizedBox(height: 16),
                  _ModeCard(
                    icon: Icons.touch_app,
                    title: '2. 手动选取样本',
                    subtitle: '预览视频并手动选取广告起止时间',
                    color: Colors.orange,
                    onTap: () => _openSingle(context, ProcessingMode.manual),
                  ),
                  const SizedBox(height: 16),
                  _ModeCard(
                    icon: Icons.fingerprint,
                    title: '3. 数据库指纹匹配',
                    subtitle: '使用广告指纹库自动匹配并切除',
                    color: Colors.green,
                    onTap: () => _openSingle(context, ProcessingMode.database),
                    onLongPress: () => _openBatch(context, ProcessingMode.database),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openSingle(BuildContext context, ProcessingMode mode) {
    context.read<ProcessingState>().setMode(mode);
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SinglePage()),
    );
  }

  Future<void> _openBatch(BuildContext context, ProcessingMode mode) async {
    final path = await getDirectoryPath();
    if (path == null) return;

    final videos = Directory(path).listSync().whereType<File>().where(
      (f) => ['.mp4', '.mkv', '.avi', '.mov', '.flv', '.webm', '.m4v', '.ts']
          .contains(p.extension(f.path).toLowerCase()),
    ).toList();
    if (videos.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('文件夹中没有视频文件')),
        );
      }
      return;
    }

    context.read<ProcessingState>().setMode(mode);
    if (context.mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => SinglePage(batchDir: path, batchVideos: videos),
        ),
      );
    }
  }
}

class _ModeCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _ModeCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: color.withAlpha(30),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color, size: 32),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (onLongPress != null) ...[
                          const SizedBox(width: 8),
                          Icon(Icons.folder_copy, size: 14, color: Colors.grey[400]),
                          const SizedBox(width: 2),
                          Text('批量', style: TextStyle(fontSize: 10, color: Colors.grey[400])),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(color: Colors.grey[600]),
                    ),
                  ],
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.chevron_right, color: Colors.grey[400]),
                  if (onLongPress != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text('长按批量', style: TextStyle(fontSize: 8, color: Colors.grey[400])),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
