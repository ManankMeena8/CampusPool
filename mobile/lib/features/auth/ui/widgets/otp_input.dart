import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Six code boxes driven by one hidden text field, so typing, paste, SMS/email autofill and
/// backspace all behave like a normal input without juggling focus between six fields.
class OtpInput extends StatefulWidget {
  const OtpInput({
    super.key,
    required this.controller,
    required this.onCompleted,
    this.enabled = true,
    this.hasError = false,
  });

  static const length = 6;

  final TextEditingController controller;
  final ValueChanged<String> onCompleted;
  final bool enabled;
  final bool hasError;

  @override
  State<OtpInput> createState() => _OtpInputState();
}

class _OtpInputState extends State<OtpInput> {
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    if (value.length == OtpInput.length) widget.onCompleted(value);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Verification code',
      child: GestureDetector(
        onTap: widget.enabled ? _focus.requestFocus : null,
        child: Stack(
          children: [
            ListenableBuilder(
              listenable: Listenable.merge([widget.controller, _focus]),
              builder: (context, _) {
                final text = widget.controller.text;
                return Row(
                  children: List.generate(OtpInput.length, (i) {
                    final isActive =
                        _focus.hasFocus &&
                        (i == text.length ||
                            (i == OtpInput.length - 1 &&
                                text.length == OtpInput.length));
                    final borderColor = widget.hasError
                        ? scheme.error
                        : isActive
                        ? scheme.primary
                        : scheme.outline;
                    // Boxes share the width, so the row never overflows on narrow phones.
                    return Expanded(
                      child: Container(
                        height: 56,
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: borderColor,
                            width: isActive ? 2 : 1,
                          ),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          i < text.length ? text[i] : '',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                      ),
                    );
                  }),
                );
              },
            ),
            Positioned.fill(
              child: Opacity(
                opacity: 0,
                child: TextField(
                  key: const Key('otp-hidden-field'),
                  controller: widget.controller,
                  focusNode: _focus,
                  enabled: widget.enabled,
                  autofocus: true,
                  showCursor: false,
                  keyboardType: TextInputType.number,
                  autofillHints: const [AutofillHints.oneTimeCode],
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(OtpInput.length),
                  ],
                  onChanged: _onChanged,
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    counterText: '',
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
