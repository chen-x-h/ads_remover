class AdInterval {
  final double start;
  final double end;

  AdInterval(this.start, this.end);

  double get duration => end - start;

  @override
  String toString() => 'AdInterval(${_fmt(start)} ~ ${_fmt(end)})';

  String _fmt(double s) {
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${sec.toStringAsFixed(3).padLeft(6, '0')}';
  }
}
