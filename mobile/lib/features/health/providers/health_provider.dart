import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/health_repository.dart';

final healthProvider = FutureProvider.autoDispose<void>((ref) {
  return ref.watch(healthRepositoryProvider).check();
});
