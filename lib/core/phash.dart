import 'dart:math' as math;
import 'dart:typed_data';

class Phash {
  static const int n = 32;
  static const int highFreq = 8;

  // Pre-computed DCT cosine tables (independent of pixel data)
  static final List<List<double>> _cosTableX = () {
    final t = List.generate(n, (_) => List.filled(n, 0.0));
    final factor = math.pi / (2.0 * n);
    for (int u = 0; u < n; u++) {
      for (int x = 0; x < n; x++) {
        t[u][x] = math.cos((2 * x + 1) * u * factor);
      }
    }
    return t;
  }();

  static final List<List<double>> _cosTableY = () {
    final t = List.generate(n, (_) => List.filled(n, 0.0));
    final factor = math.pi / (2.0 * n);
    for (int u = 0; u < n; u++) {
      for (int y = 0; y < n; y++) {
        t[u][y] = math.cos((2 * y + 1) * u * factor);
      }
    }
    return t;
  }();

  static String compute(Uint8List grayPixels) {
    // Build 2D pixel array
    final pixels = List.generate(n, (_) => List.filled(n, 0.0));
    for (int y = 0; y < n; y++) {
      for (int x = 0; x < n; x++) {
        pixels[y][x] = grayPixels[y * n + x].toDouble();
      }
    }

    // 2D DCT — only compute first 8×8 coefficients, inner loop 4× unrolled
    final coefficients = <double>[];
    for (int u = 0; u < highFreq; u++) {
      final cu = u == 0 ? 1.0 / math.sqrt(2.0) : 1.0;
      for (int v = 0; v < highFreq; v++) {
        final cv = v == 0 ? 1.0 / math.sqrt(2.0) : 1.0;
        double sum = 0.0;
        final cosYrow = _cosTableY[v];
        for (int x = 0; x < n; x++) {
          final cosX = _cosTableX[u][x];
          final row = pixels[x];
          // 4× unrolled inner loop
          int y = 0;
          for (; y + 3 < n; y += 4) {
            sum += (row[y] * cosYrow[y]
                  + row[y + 1] * cosYrow[y + 1]
                  + row[y + 2] * cosYrow[y + 2]
                  + row[y + 3] * cosYrow[y + 3]) * cosX;
          }
          for (; y < n; y++) {
            sum += row[y] * cosX * cosYrow[y];
          }
        }
        final val = 0.25 * cu * cv * sum;
        if (u != 0 || v != 0) coefficients.add(val);
      }
    }

    // Median threshold
    final sorted = List<double>.from(coefficients)..sort();
    final median = sorted[coefficients.length ~/ 2];

    BigInt hash = BigInt.zero;
    for (int i = 0; i < coefficients.length; i++) {
      if (coefficients[i] > median) {
        hash |= BigInt.one << i;
      }
    }

    return hash.toRadixString(16).padLeft(16, '0');
  }

  static int hammingDistance(String hash1, String hash2) {
    final BigInt h1 = BigInt.parse(hash1, radix: 16);
    final BigInt h2 = BigInt.parse(hash2, radix: 16);
    final BigInt xor = h1 ^ h2;

    int count = 0;
    for (int i = 0; i < 64; i++) {
      if ((xor >> i) & BigInt.one != BigInt.zero) {
        count++;
      }
    }
    return count;
  }

  static bool isSimilar(String hash1, String? hash2, {int threshold = 5}) {
    if (hash2 == null) return false;
    return hammingDistance(hash1, hash2) <= threshold;
  }
}
