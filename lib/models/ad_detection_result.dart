import 'dart:convert';
import '../models/ad_interval.dart';

class AdDetectionResult {
  final String videoPath;
  final String sampleName;
  final double startTime;
  final double endTime; // reference: startTime + sample.duration
  final String? videoFramePath; // extracted frame from video at startTime
  final String? videoEndFramePath; // extracted frame from video at endTime
  final String? sampleFramePath; // sample's start frame image
  final String? sampleEndFramePath; // sample's end frame image
  final bool endMatched; // whether end hash matched
  bool confirmed;

  AdDetectionResult({
    required this.videoPath,
    required this.sampleName,
    required this.startTime,
    required this.endTime,
    this.videoFramePath,
    this.videoEndFramePath,
    this.sampleFramePath,
    this.sampleEndFramePath,
    this.endMatched = false,
    this.confirmed = true,
  });

  Map<String, dynamic> toJson() => {
        'videoPath': videoPath,
        'sampleName': sampleName,
        'startTime': startTime,
        'endTime': endTime,
        'videoFramePath': videoFramePath,
        'videoEndFramePath': videoEndFramePath,
        'sampleFramePath': sampleFramePath,
        'sampleEndFramePath': sampleEndFramePath,
        'endMatched': endMatched,
        'confirmed': confirmed,
      };

  factory AdDetectionResult.fromJson(Map<String, dynamic> json) =>
      AdDetectionResult(
        videoPath: json['videoPath'] as String,
        sampleName: json['sampleName'] as String,
        startTime: (json['startTime'] as num).toDouble(),
        endTime: (json['endTime'] as num).toDouble(),
        videoFramePath: json['videoFramePath'] as String?,
        videoEndFramePath: json['videoEndFramePath'] as String?,
        sampleFramePath: json['sampleFramePath'] as String?,
        sampleEndFramePath: json['sampleEndFramePath'] as String?,
        endMatched: json['endMatched'] as bool? ?? false,
        confirmed: json['confirmed'] as bool? ?? true,
      );
}
