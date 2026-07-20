String fmtTime(double s) {
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = s % 60;
  return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${sec.toStringAsFixed(0).padLeft(2, '0')}';
}

String fmtPrecise(double s) {
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = s % 60;
  return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${sec.toStringAsFixed(3).padLeft(6, '0')}';
}
