import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/api/api_client.dart';
import '../../../core/api/api_error.dart';
import '../../../core/router/routes.dart';
import '../../../core/validation/validators.dart';
import '../../../core/widgets/form_message.dart';
import '../../../core/widgets/submit_button.dart';
import '../providers/auth_notifier.dart';
import 'widgets/auth_scaffold.dart';
import 'widgets/password_field.dart';

class SignupScreen extends ConsumerStatefulWidget {
  const SignupScreen({super.key});

  @override
  ConsumerState<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends ConsumerState<SignupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _submitting = false;
  ApiError? _error;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting || !_formKey.currentState!.validate()) return;
    final email = Validators.normalizeEmail(_email.text);
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ref
          .read(authProvider.notifier)
          .signup(
            name: _name.text.trim(),
            email: email,
            password: _password.text,
          );
      if (!mounted) return;
      context.go(Routes.verifyOtpFor(email, cooldownSeconds: 60));
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final domain = ref.watch(appConfigProvider).allowedEmailDomain;
    final error = _error;
    final rateLimited = error?.code == 'RATE_LIMITED';

    return AuthScaffold(
      title: 'Create account',
      subtitle: 'Use your @$domain email. We will send you a 6-digit code.',
      child: Form(
        key: _formKey,
        child: AutofillGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _name,
                enabled: !_submitting,
                textCapitalization: TextCapitalization.words,
                autofillHints: const [AutofillHints.name],
                textInputAction: TextInputAction.next,
                validator: Validators.name,
                autovalidateMode: AutovalidateMode.onUserInteraction,
                decoration: const InputDecoration(
                  labelText: 'Full name',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _email,
                enabled: !_submitting,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                autofillHints: const [AutofillHints.email],
                textInputAction: TextInputAction.next,
                validator: (v) => Validators.collegeEmail(v, domain),
                autovalidateMode: AutovalidateMode.onUserInteraction,
                decoration: InputDecoration(
                  labelText: 'College email',
                  hintText: 'you@$domain',
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              PasswordField(
                controller: _password,
                enabled: !_submitting,
                validator: Validators.password,
                autofillHints: const [AutofillHints.newPassword],
                helperText:
                    'At least 8 characters, with a letter and a number.',
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 16),
              if (error != null) ...[
                FormMessage(
                  rateLimited
                      ? '${error.message}\nA code was sent recently. Check your inbox and enter it.'
                      : error.message,
                ),
                if (rateLimited)
                  TextButton(
                    onPressed: () => context.go(
                      Routes.verifyOtpFor(
                        Validators.normalizeEmail(_email.text),
                        cooldownSeconds: error.retryAfterSeconds ?? 60,
                      ),
                    ),
                    child: const Text('I already have a code'),
                  ),
                const SizedBox(height: 16),
              ],
              SubmitButton(
                label: 'Sign up',
                loading: _submitting,
                onPressed: _submit,
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _submitting ? null : () => context.go(Routes.login),
                child: const Text('Already have an account? Log in'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
