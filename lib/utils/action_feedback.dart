import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/emergency_provider.dart';
import '../providers/settings_provider.dart';
import 'app_theme.dart';

class ActionFeedback {
  static bool get _isDesktopWeb {
    if (!kIsWeb) return false;
    return defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS;
  }

  static Future<void> callWithFeedback(
    BuildContext context,
    EmergencyProvider emergency,
    String phoneNumber,
    String label,
  ) async {
    final isFil = _readIsFil(context);
    if (_isDesktopWeb) {
      if (!context.mounted) return;
      _showFallbackDialog(
        context: context,
        title: isFil ? 'Tawagan: $label' : 'Dial $label',
        detailLabel: isFil ? 'Numero ng Hotline' : 'Hotline Number',
        valueToCopy: phoneNumber,
        explanation: isFil
            ? 'Sa laptop/PC, kopyahin ang numero o i-dial gamit ang iyong telepono:'
            : 'On desktop browsers, copy the hotline number to dial from your phone or try opening your call app:',
        isFil: isFil,
        retryActionLabel: isFil ? 'Buksan ang Call App' : 'Open Call App',
        onRetryLaunch: () => emergency.makePhoneCall(phoneNumber),
      );
      return;
    }

    final launched = await emergency.makePhoneCall(phoneNumber);
    if (!launched && context.mounted) {
      _showFallbackDialog(
        context: context,
        title: isFil ? 'Tawagan: $label' : 'Dial $label',
        detailLabel: isFil ? 'Numero ng Hotline' : 'Hotline Number',
        valueToCopy: phoneNumber,
        explanation: isFil
            ? 'Hindi mabuksan ng browser ang phone dialer. Kopyahin ang numero sa ibaba para i-dial:'
            : 'Your current device or browser cannot launch a direct cellular call. Copy the number below to dial manually:',
        isFil: isFil,
      );
    }
  }

  static Future<void> smsWithFeedback(
    BuildContext context,
    EmergencyProvider emergency,
    String phoneNumber,
    String message,
  ) async {
    final isFil = _readIsFil(context);
    if (_isDesktopWeb) {
      if (!context.mounted) return;
      _showFallbackDialog(
        context: context,
        title: isFil ? 'Emergency SMS Text' : 'Emergency SMS Text',
        detailLabel: isFil ? 'Padadalhan: $phoneNumber' : 'Recipient: $phoneNumber',
        valueToCopy: message,
        explanation: isFil
            ? 'Sa laptop/PC, kopyahin ang emergency message sa ibaba para ipadala sa SMS, Messenger, o Viber:'
            : 'On desktop browsers, copy the emergency GPS message below to send via SMS, Messenger, or Viber:',
        isFil: isFil,
        retryActionLabel: isFil ? 'Buksan ang SMS App' : 'Open SMS App',
        onRetryLaunch: () => emergency.sendEmergencySms(
          phoneNumber: phoneNumber,
          message: message,
        ),
      );
      return;
    }

    final launched = await emergency.sendEmergencySms(
      phoneNumber: phoneNumber,
      message: message,
    );
    if (!launched && context.mounted) {
      _showFallbackDialog(
        context: context,
        title: 'Emergency SMS Text',
        detailLabel: isFil ? 'Padadalhan: $phoneNumber' : 'Recipient: $phoneNumber',
        valueToCopy: message,
        explanation: isFil
            ? 'Hindi mabuksan ng browser ang SMS app. Kopyahin ang emergency message sa ibaba:'
            : 'Your browser cannot open an SMS app directly. Copy the emergency message below to send via Messenger or SMS:',
        isFil: isFil,
      );
    }
  }

  static Future<void> openMapWithFeedback(
    BuildContext context,
    EmergencyProvider emergency,
    double lat,
    double lng,
    String label,
  ) async {
    final isFil = _readIsFil(context);
    final launched = await emergency.openMapLocation(lat, lng, label);
    if (!launched && context.mounted) {
      final coords = '$lat, $lng';
      _showFallbackDialog(
        context: context,
        title: label,
        detailLabel: isFil ? 'Offline GPS Coordinates' : 'Offline GPS Coordinates',
        valueToCopy: coords,
        explanation: isFil
            ? 'Hindi mabuksan ang external maps (maaaring offline). Gamitin ang mapa sa app o kopyahin ang GPS coordinates:'
            : 'External maps could not be opened (you may be offline). Use the in-app map or copy the GPS coordinates:',
        isFil: isFil,
      );
    }
  }

  static bool _readIsFil(BuildContext context) {
    try {
      return context.read<SettingsProvider>().isFilipino;
    } catch (_) {
      return false;
    }
  }

  static void _showFallbackDialog({
    required BuildContext context,
    required String title,
    required String detailLabel,
    required String valueToCopy,
    required String explanation,
    required bool isFil,
    String? retryActionLabel,
    Future<bool> Function()? onRetryLaunch,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bodyColor = isDark ? Colors.white70 : AppTheme.mutedSlate;
    final boxBg = isDark ? AppTheme.darkElevated : AppTheme.surfaceBg;
    final boxBorder = isDark ? AppTheme.darkBorder : AppTheme.lightBorder;
    final valueColor = isDark ? Colors.white : AppTheme.darkSlate;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          title,
          style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              explanation,
              style: TextStyle(fontSize: 13, color: bodyColor, height: 1.4),
            ),
            const SizedBox(height: 12),
            Text(
              detailLabel,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: bodyColor,
              ),
            ),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: boxBg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: boxBorder),
              ),
              child: SelectableText(
                valueToCopy,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: valueColor,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(isFil ? 'Isara' : 'Close'),
          ),
          if (retryActionLabel != null && onRetryLaunch != null)
            OutlinedButton(
              onPressed: () async {
                Navigator.pop(ctx);
                await onRetryLaunch();
              },
              child: Text(retryActionLabel),
            ),
          FilledButton.icon(
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: Text(isFil ? 'Kopyahin' : 'Copy'),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: valueToCopy));
              Navigator.pop(ctx);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    backgroundColor: AppTheme.safeGreen,
                    content: Text(
                      isFil ? 'Nakopya sa clipboard!' : 'Copied to clipboard!',
                    ),
                  ),
                );
              }
            },
          ),
        ],
      ),
    );
  }
}
