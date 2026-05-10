import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../../core/theme/colors.dart';

class ChatInput extends StatefulWidget {
  const ChatInput({
    super.key,
    required this.hint,
    required this.sendTooltip,
    required this.onSend,
  });

  final String hint;
  final String sendTooltip;
  final ValueChanged<String> onSend;

  @override
  State<ChatInput> createState() => _ChatInputState();
}

class _ChatInputState extends State<ChatInput> {
  final _controller = TextEditingController();
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final has = _controller.text.trim().isNotEmpty;
      if (has != _hasText) setState(() => _hasText = has);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    widget.onSend(text);
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.25),
            border: Border(
              top: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
            ),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.10),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
                        borderRadius: BorderRadius.circular(22),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: TextField(
                        controller: _controller,
                        minLines: 1,
                        maxLines: 5,
                        cursorColor: AppColors.brandPrimary,
                        style: TextStyle(color: AppColors.textOnGlass, fontSize: 14.5),
                        onSubmitted: (_) => _send(),
                        textInputAction: TextInputAction.send,
                        decoration: InputDecoration(
                          isCollapsed: true,
                          contentPadding: const EdgeInsets.symmetric(vertical: 12),
                          border: InputBorder.none,
                          hintText: widget.hint,
                          hintStyle: TextStyle(color: AppColors.textOnGlassFaint, fontSize: 14.5),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _SendButton(enabled: _hasText, tooltip: widget.sendTooltip, onTap: _send),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({required this.enabled, required this.tooltip, required this.onTap});

  final bool enabled;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: enabled ? 1 : 0.5,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: enabled ? onTap : null,
            borderRadius: BorderRadius.circular(999),
            child: Container(
              width: 44,
              height: 44,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: AppColors.brandGradient,
              ),
              child: const Icon(Icons.arrow_upward, color: Colors.white, size: 20),
            ),
          ),
        ),
      ),
    );
  }
}
