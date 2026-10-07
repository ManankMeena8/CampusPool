import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/api/api_error.dart';
import '../../../core/router/routes.dart';
import '../../../core/validation/validators.dart';
import '../../../core/widgets/form_message.dart';
import '../../../core/widgets/submit_button.dart';
import '../providers/auth_notifier.dart';
import 'widgets/auth_scaffold.dart';
import 'widgets/password_field.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
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
          .login(email: email, password: _password.text);
      // Success: the router redirects away from login.
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.code == 'EMAIL_NOT_VERIFIED') {
        context.go(Routes.verifyOtpFor(email));
        return;
      }
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Log in',
      subtitle: 'Welcome back to CampusPool.',
      child: Form(
        key: _formKey,
        child: AutofillGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _email,
                enabled: !_submitting,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                autofillHints: const [AutofillHints.email],
                textInputAction: TextInputAction.next,
                validator: Validators.email,
                autovalidateMode: AutovalidateMode.onUserInteraction,
                decoration: const InputDecoration(
                  labelText: 'College email',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              PasswordField(
                controller: _password,
                enabled: !_submitting,
                validator: Validators.loginPassword,
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 16),
              if (_error != null) ...[
                FormMessage(_error!),
                const SizedBox(height: 16),
              ],
              SubmitButton(
                label: 'Log in',
                loading: _submitting,
                onPressed: _submit,
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _submitting ? null : () => context.go(Routes.signup),
                child: const Text("New here? Create an account"),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
