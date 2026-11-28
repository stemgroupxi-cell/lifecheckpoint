bool isDeviceOnline() => true;

void Function() listenConnectivity(void Function(bool isOnline) onChanged) {
  return () {};
}

bool canTriggerNativePwaInstall() => false;

bool isRunningAsInstalledPwa() => true;

bool isIosBrowser() => false;

Future<bool> triggerNativePwaInstall() async => false;

bool startEmergencyWhistle() => false;

void stopEmergencyWhistle() {}

void syncBrowserThemeColor(bool isDark) {}

String getBrowserNotificationPermission() => 'unsupported';

Future<String> requestBrowserNotificationPermission() async => 'unsupported';

bool showBrowserNotification({
  required String title,
  required String body,
  String tag = 'lifecheckpoint-advisory',
}) =>
    false;

void playAlertChime({bool isCritical = false}) {}
