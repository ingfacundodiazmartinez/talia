/// Call Action Buttons Widget
///
/// Displays accept and decline buttons for incoming calls.
/// ✅ PHASE 1C: Provides clear, accessible call controls.

import 'package:flutter/material.dart';

class CallActionButtons extends StatelessWidget {
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final bool isVideo;
  final bool isLoading;

  const CallActionButtons({
    Key? key,
    required this.onAccept,
    required this.onDecline,
    this.isVideo = true,
    this.isLoading = false,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        // Decline button
        _CallActionButton(
          onPressed: isLoading ? null : onDecline,
          backgroundColor: Colors.red,
          icon: Icons.call_end,
          label: 'Decline',
        ),

        // Accept button
        _CallActionButton(
          onPressed: isLoading ? null : onAccept,
          backgroundColor: Colors.green,
          icon: isVideo ? Icons.videocam : Icons.call,
          label: 'Accept',
          isLoading: isLoading,
        ),
      ],
    );
  }
}

class _CallActionButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final Color backgroundColor;
  final IconData icon;
  final String label;
  final bool isLoading;

  const _CallActionButton({
    Key? key,
    required this.onPressed,
    required this.backgroundColor,
    required this.icon,
    required this.label,
    this.isLoading = false,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Large circular button
        Material(
          color: backgroundColor.withOpacity(onPressed == null ? 0.5 : 1.0),
          shape: const CircleBorder(),
          elevation: onPressed == null ? 0 : 8,
          shadowColor: backgroundColor.withOpacity(0.4),
          child: InkWell(
            onTap: onPressed,
            customBorder: const CircleBorder(),
            child: Container(
              width: 70,
              height: 70,
              alignment: Alignment.center,
              child: isLoading
                  ? const SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : Icon(
                      icon,
                      color: Colors.white,
                      size: 32,
                    ),
            ),
          ),
        ),

        const SizedBox(height: 12),

        // Label
        Text(
          label,
          style: TextStyle(
            color: onPressed == null
                ? Colors.grey
                : Theme.of(context).textTheme.bodyMedium?.color,
            fontSize: 16,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
