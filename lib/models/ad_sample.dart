class AdSample {
  final int? id;
  final String name;
  final String? videoPath;
  final String startFrameHash;
  final String endFrameHash;
  final double duration;
  final String? createdAt;

  AdSample({
    this.id,
    required this.name,
    this.videoPath,
    required this.startFrameHash,
    required this.endFrameHash,
    required this.duration,
    this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'name': name,
      'video_path': videoPath,
      'start_frame_hash': startFrameHash,
      'end_frame_hash': endFrameHash,
      'duration': duration,
      if (createdAt != null) 'created_at': createdAt,
    };
  }

  factory AdSample.fromMap(Map<String, dynamic> map) {
    return AdSample(
      id: map['id'] as int?,
      name: map['name'] as String,
      videoPath: map['video_path'] as String?,
      startFrameHash: map['start_frame_hash'] as String,
      endFrameHash: map['end_frame_hash'] as String,
      duration: (map['duration'] as num).toDouble(),
      createdAt: map['created_at'] as String?,
    );
  }
}
