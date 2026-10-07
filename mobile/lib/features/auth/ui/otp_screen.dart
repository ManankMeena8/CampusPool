import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/api/api_error.dart';
import '../../../core/router/routes.dart';
import '../../../core/widgets/form_message.dart';
import '../../../core/widgets/submit_button.dart';
import '../providers/auth_notifier.dart';
import 'widgets/auth_scaffold.dart';
import 'widgets/otp_input.dart';

class OtpScreen extends ConsumerStatefulWidget {
  const OtpScreen({super.key, required this.email, this.initialCooldown = 0});

  final String email;

  /// Seconds before "Resend code" is enabled (60 when a code was just sent).
  final int initialCooldown;

  @override
  ConsumerState<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends ConsumerState<OtpScreen> {
  static const _cooldown = 60;

  final _code = TextEditingController();
  Timer? _timer;
  int _secondsLeft = 0;
  bool _verifying = false;
  bool _resending = false;
  String? _error;
  String? _info;

  @override
  void initState() {
    super.initState();
    _runCountdown(widget.initialCooldown);
    if (widget.initialCooldown <= 0) {
      // Arrived from login with an unverified account: no code was just sent.
      _info = 'Tap "Resend code" to get a new code by email.';
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _code.dispose();
    super.dispose();
  }

  void _startCooldown(int seconds) => setState(() => _runCountdown(seconds));

  void _runCountdown(int seconds) {
    _timer?.cancel();
    _secondsLeft = seconds;
    if (seconds <= 0) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _secondsLeft--);
      if (_secondsLeft <= 0) t.cancel();
    });
  }

  Future<void> _verify() async {
    final code = _code.text;
    if (_verifying || code.length != OtpInput.length) return;
    setState(() {
      _verifying = true;
      _error = null;
      _info = null;
    });
    try {
      await ref
          .read(authProvider.notifier)
          .verifyOtp(email: widget.email, code: code);
      // Success: the router takes the now signed-in user home.
    } on ApiError catch (e) {
      if (!mounted) return;
      _code.clear();
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  Future<void> _resend() async {
    if (_resending || _secondsLeft > 0) return;
    setState(() {
      _resending = true;
      _error = null;
      _info = null;
    });
    try {
      await ref.read(authProvider.notifier).resendOtp(widget.email);
      if (!mounted) return;
      _code.clear();
      setState(
        () => _info = 'A new code is on its way. Older codes no longer work.',
      );
      _startCooldown(_cooldown);
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
      // RATE_LIMITED tells us how long to wait; sync the countdown to the server.
      if (e.code == 'RATE_LIMITED') {
        _startCooldown(e.retryAfterSeconds ?? _cooldown);
      }
    } finally {
      if (mounted) setState(() => _resending = false);
    }
  }

  String get _resendLabel {
    if (_secondsLeft <= 0) return 'Resend code';
    final m = _secondsLeft ~/ 60;
    final s = (_secondsLeft % 60).toString().padLeft(2, '0');
    return 'Resend code in $m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final busy = _verifying || _resending;
    return AuthScaffold(
      title: 'Verify your email',
      subtitle:
          'Enter the 6-digit code sent to ${widget.email}. It expires in 5 minutes.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OtpInput(
            controller: _code,
            enabled: !busy,
            hasError: _error != null,
            onCompleted: (_) => _verify(),
          ),
          const SizedBox(height: 16),
          if (_error != null) ...[
            FormMessage(_error!),
            const SizedBox(height: 16),
          ],
          if (_info != null) ...[
            FormMessage(_info!, isError: false),
            const SizedBox(height: 16),
          ],
          ListenableBuilder(
            listenable: _code,
            builder: (context, _) => SubmitButton(
              label: 'Verify',
              loading: _verifying,
              onPressed: _code.text.length == OtpInput.length && !_resending
                  ? _verify
                  : null,
            ),
          ),
          const SizedBox(height: 8),
          TextButton(
            key: const Key('resend-button'),
            onPressed: busy || _secondsLeft > 0 ? null : _resend,
            child: _resending
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(_resendLabel),
          ),
          TextButton(
            onPressed: busy ? null : () => context.go(Routes.signup),
            child: const Text('Wrong email? Sign up again'),
          ),
        ],
      ),
    );
  }
}
