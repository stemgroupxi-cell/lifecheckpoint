import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/settings_provider.dart';
import '../utils/app_theme.dart';
import 'disaster_guide_screen.dart';
import 'emergency_contacts_screen.dart';
import 'emergency_plan_screen.dart';

class SafetyHubScreen extends StatelessWidget {
  final int initialTabIndex;

  const SafetyHubScreen({super.key, this.initialTabIndex = 0});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final isFil = settings.isFilipino;

    final activeColor =
        isDark ? Colors.lightBlue.shade200 : AppTheme.primaryNavy;
    final idleColor = isDark ? Colors.white60 : AppTheme.mutedSlate;

    return DefaultTabController(
      length: 3,
      initialIndex: initialTabIndex.clamp(0, 2),
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            isFil ? 'Kaligtasan, Hotline at Plano' : 'Safety, Hotlines & Plan',
          ),
          bottom: TabBar(
            isScrollable: false,
            indicatorColor: activeColor,
            indicatorWeight: 3,
            labelColor: activeColor,
            unselectedLabelColor: idleColor,
            labelPadding: const EdgeInsets.symmetric(horizontal: 4),
            dividerColor: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
            labelStyle: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
            unselectedLabelStyle: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
            ),
            tabs: [
              Tab(
                height: 46,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.phone_in_talk_rounded, size: 16),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        isFil ? 'Hotline' : 'Hotlines',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              Tab(
                height: 46,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.menu_book_rounded, size: 16),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        isFil ? 'Gabay' : 'Guides',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              Tab(
                height: 46,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.family_restroom_rounded, size: 16),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        isFil ? 'Plano' : 'Family Plan',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            EmergencyContactsScreen(isEmbedded: true),
            DisasterGuideScreen(isEmbedded: true),
            EmergencyPlanScreen(isEmbedded: true),
          ],
        ),
      ),
    );
  }
}
