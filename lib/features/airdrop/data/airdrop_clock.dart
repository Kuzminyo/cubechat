import 'package:flutter_riverpod/flutter_riverpod.dart';

/// "Now", for everything in AirDrop that counts minutes — injectable so tests
/// can stand at a moment of their choosing.
final airdropClockProvider =
    Provider<DateTime Function()>((ref) => DateTime.now);
