import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_error.dart';
import '../../../core/widgets/form_message.dart';
import '../../../core/widgets/loading_view.dart';
import '../../auth/data/auth_models.dart';
import '../../auth/providers/auth_notifier.dart';
import '../data/user_repository.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  bool _savingRole = false;
  bool _loggingOut = false;
  String? _error;

  Future<void> _changeRole(Role role) async {
    setState(() {
      _savingRole = true;
      _error = null;
    });
    try {
      final user = await ref.read(userRepositoryProvider).updateRole(role);
      ref.read(authProvider.notifier).setUser(user);
    } on ApiError catch (e) {
      // The selector still shows the saved role, since it reads from auth state.
      if (mounted) {
        setState(() => _error = 'Could not change your role. ${e.message}');
      }
    } finally {
      if (mounted) setState(() => _savingRole = false);
    }
  }

  Future<void> _logout() async {
    setState(() => _loggingOut = true);
    await ref.read(authProvider.notifier).logout();
    // The router leaves this screen once the user is signed out.
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    if (auth is! AuthAuthenticated) {
      // Momentary: shown while signing out, until the router leaves this screen.
      return const Scaffold(body: LoadingView());
    }
    final user = auth.user;
    final textTheme = Theme.of(context).textTheme;
    final busy = _savingRole || _loggingOut;

    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          CircleAvatar(
            radius: 36,
            child: Text(
              user.name.isNotEmpty ? user.name[0].toUpperCase() : '?',
              style: textTheme.headlineMedium,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            user.name,
            style: textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          Text(
            user.email,
            style: textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            user.ratingCount == 0
                ? 'No ratings yet'
                : '★ ${user.ratingAvg.toStringAsFixed(1)} (${user.ratingCount})',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          Text('I want to', style: textTheme.titleMedium),
          const SizedBox(height: 8),
          SegmentedButton<Role>(
            segments: const [
              ButtonSegment(
                value: Role.rider,
                label: Text('Ride'),
                icon: Icon(Icons.hail),
              ),
              ButtonSegment(
                value: Role.driver,
                label: Text('Drive'),
                icon: Icon(Icons.directions_car),
              ),
              ButtonSegment(
                value: Role.both,
                label: Text('Both'),
                icon: Icon(Icons.swap_horiz),
              ),
            ],
            selected: {user.role},
            showSelectedIcon: false,
            onSelectionChanged: busy
                ? null
                : (selection) => _changeRole(selection.first),
          ),
          if (_savingRole) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ],
          if (_error != null) ...[
            const SizedBox(height: 16),
            FormMessage(_error!),
          ],
          const SizedBox(height: 32),
          OutlinedButton.icon(
            onPressed: busy ? null : _logout,
            icon: _loggingOut
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.logout),
            label: const Text('Log out'),
          ),
        ],
      ),
    );
  }
}
