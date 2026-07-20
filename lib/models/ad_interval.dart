import '../core/time_format.dart';

class AdInterval {
  final double start;
  final double end;

  AdInterval(this.start, this.end);

  double get duration => end - start;

  @override
  String toString() => 'AdInterval(${fmtPrecise(start)} ~ ${fmtPrecise(end)})';
}
