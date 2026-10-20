import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/health_repository.dart';

/// No automatic retry: the home screen's banner shows the failure at once and offers Retry.
final healthProvider = FutureProvider.autoDispose<void>(
  (ref) => ref.watch(healthRepositoryProvider).check(),
  retry: (_, _) => null,
);
