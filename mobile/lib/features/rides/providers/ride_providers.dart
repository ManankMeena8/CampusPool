import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/ride_models.dart';
import '../data/ride_repository.dart';

final rideProvider = FutureProvider.autoDispose.family<Ride, String>(
  (ref, id) => ref.watch(rideRepositoryProvider).getRide(id),
);
