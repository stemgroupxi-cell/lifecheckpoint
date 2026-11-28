import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../data/evacuation_centers_data.dart';
import '../models/evacuation_center.dart';
import '../providers/emergency_provider.dart';
import '../providers/settings_provider.dart';
import '../utils/action_feedback.dart';
import '../utils/app_theme.dart';
import '../utils/location_service.dart';
import '../utils/manila_route_service.dart';
import '../utils/pwa_bridge.dart';
import '../widgets/manila_map_picker.dart';
import '../widgets/responsive_container.dart';

class EvacuationMapScreen extends StatefulWidget {
  const EvacuationMapScreen({super.key});

  @override
  State<EvacuationMapScreen> createState() => _EvacuationMapScreenState();
}

class _EvacuationMapScreenState extends State<EvacuationMapScreen> {
  static const LatLng _manilaCenter = LatLng(14.5900, 120.9820);

  final MapController _mapController = MapController();
  final ScrollController _mobileScrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  final GlobalKey _mapSectionKey = GlobalKey();

  EvacuationCenter? _selectedCenter;
  bool _isPanningMobileMap = false;
  double _currentZoom = 13.0;

  EvacuationRouteResult? _activeStreetRoute;
  String? _activeRouteKey;
  bool _isDownloadingMap = false;
  int _mapDownloadDone = 0;
  int _mapDownloadTotal = 0;
  int _cachedTileCount = 0;

  @override
  void initState() {
    super.initState();
    _refreshCachedTileCount();
  }

  Future<void> _refreshCachedTileCount() async {
    if (!supportsOfflineMapDownload) return;
    final count = await getCachedMapTileCount();
    if (mounted) {
      setState(() => _cachedTileCount = count);
    }
  }

  Future<void> _handleDownloadOfflineMap(
    BuildContext context,
    bool isFil,
  ) async {
    if (_isDownloadingMap) return;
    setState(() {
      _isDownloadingMap = true;
      _mapDownloadDone = 0;
      _mapDownloadTotal = 53;
    });
    final cached = await downloadManilaOfflineMap(
      onProgress: (done, total) {
        if (!mounted) return;
        setState(() {
          _mapDownloadDone = done;
          _mapDownloadTotal = total;
        });
      },
    );
    if (!mounted) return;
    final count = await getCachedMapTileCount();
    if (!mounted) return;
    setState(() {
      _isDownloadingMap = false;
      _cachedTileCount = count > cached ? count : cached;
    });
    if (context.mounted) {
      final ok = _cachedTileCount >= 20;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: ok ? AppTheme.safeGreen : AppTheme.warningAmber,
          content: Text(
            ok
                ? (isFil
                    ? 'Handa na offline ang mapa ng Lungsod ng Maynila ($_cachedTileCount tiles)!'
                    : 'City of Manila offline map ready ($_cachedTileCount tiles cached)!')
                : (isFil
                    ? 'Hindi ma-download ang mapa ngayon. Suriin ang iyong internet connection.'
                    : 'Could not cache map tiles right now. Check your internet connection.'),
          ),
        ),
      );
    }
  }

  void _ensureStreetRoute(LatLng userPoint, EvacuationCenter target) {
    final dest = LatLng(target.latitude, target.longitude);
    final key = ManilaRouteService.buildCacheKey(userPoint, dest);
    if (_activeRouteKey == key) return;
    _activeRouteKey = key;
    if (_activeStreetRoute != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _activeRouteKey == key) {
          setState(() => _activeStreetRoute = null);
        }
      });
    }
    ManilaRouteService.getStreetRoute(from: userPoint, to: dest).then((res) {
      if (!mounted || _activeRouteKey != key) return;
      if (res != null) {
        setState(() => _activeStreetRoute = res);
      }
    });
  }

  PolylineLayer _buildRoutePolylineLayer({
    required LatLng userPoint,
    required EvacuationCenter target,
    required EvacuationRouteResult? streetRoute,
    required bool isExplicitLine,
    required bool isDark,
  }) {
    final mainColor = target.isOpen
        ? (isDark ? Colors.tealAccent.shade200 : Colors.teal.shade700)
        : Colors.blueGrey.shade500;

    if (streetRoute != null &&
        streetRoute.isStreetRoute &&
        streetRoute.points.length >= 2) {
      return PolylineLayer(
        polylines: [
          Polyline(
            points: streetRoute.points,
            strokeWidth: isExplicitLine ? 7.2 : 5.8,
            color: (isDark ? const Color(0xFF0F172A) : Colors.white)
                .withAlpha(isExplicitLine ? 235 : 200),
          ),
          Polyline(
            points: streetRoute.points,
            strokeWidth: isExplicitLine ? 4.4 : 3.4,
            color: mainColor.withAlpha(isExplicitLine ? 245 : 205),
          ),
        ],
      );
    }

    return PolylineLayer(
      polylines: [
        Polyline(
          points: [
            userPoint,
            LatLng(target.latitude, target.longitude),
          ],
          strokeWidth: isExplicitLine ? 3.5 : 2.6,
          color: mainColor.withAlpha(isExplicitLine ? 235 : 175),
          pattern: StrokePattern.dashed(
            segments: const [9, 7],
            patternFit: PatternFit.scaleUp,
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _mobileScrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _safeMove(LatLng target, double zoom) {
    try {
      _mapController.move(target, zoom.clamp(5.0, 18.0));
    } catch (_) {
      // MapController may not be attached yet before first frame
    }
  }

  void _zoomBy(double delta) {
    try {
      final cam = _mapController.camera;
      _mapController.move(cam.center, (cam.zoom + delta).clamp(5.0, 18.0));
    } catch (_) {}
  }

  void _focusCenter(EvacuationCenter center, {bool scrollToMap = false}) {
    setState(() => _selectedCenter = center);
    _safeMove(LatLng(center.latitude, center.longitude), 15.0);
    if (scrollToMap && _mapSectionKey.currentContext != null) {
      Scrollable.ensureVisible(
        _mapSectionKey.currentContext!,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
        alignment: 0.04,
      );
    }
  }

  String _formatEta(double distKm, bool isFil) {
    final walkMin = (distKm / 4.5 * 60).round().clamp(1, 999);
    final driveMin = (distKm / 18.0 * 60).round().clamp(1, 999);
    if (distKm > 15.0) {
      return isFil ? '~$driveMin min biyahe' : '~$driveMin min drive';
    }
    return isFil
        ? '~$walkMin min lakad • ~$driveMin min biyahe'
        : '~$walkMin min walk • ~$driveMin min drive';
  }

  @override
  Widget build(BuildContext context) {
    final emergency = context.watch<EmergencyProvider>();
    final settings = context.watch<SettingsProvider>();
    final isDark = settings.isDarkMode;
    final isFil = settings.isFilipino;

    final centers = emergency.filteredEvacuationCenters;
    final cities = emergency.availableCities;
    final headingColor = isDark ? Colors.white : AppTheme.darkSlate;
    final subtleText = isDark ? Colors.white70 : AppTheme.mutedSlate;

    final distFromManilaKm = LocationService.distanceInKm(
      emergency.userLat,
      emergency.userLng,
      _manilaCenter.latitude,
      _manilaCenter.longitude,
    );
    final isFarFromManila = distFromManilaKm > 18.0;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          isFil ? 'Mapa ng Tulong at Shelter' : 'Nearby Map & Shelters',
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_location_alt_outlined),
            tooltip: isFil
                ? 'I-save ang Barangay / Family Shelter'
                : 'Save Barangay / Family Shelter',
            onPressed: () => _showAddShelterDialog(context, emergency, isFil),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isSplit = constraints.maxWidth >= 860;

          final headerPanel = Container(
            color: isDark ? AppTheme.darkCard : Colors.white,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: ResponsiveContainer(
              maxWidth: 1160,
              child: Column(
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(9),
                        decoration: BoxDecoration(
                          color: Colors.teal.withAlpha(isDark ? 45 : 22),
                          borderRadius: BorderRadius.circular(11),
                        ),
                        child: Icon(
                          emergency.hasLiveGps
                              ? Icons.gps_fixed_rounded
                              : Icons.location_on_outlined,
                          size: 20,
                          color: isDark
                              ? Colors.tealAccent
                              : Colors.teal.shade700,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              emergency.hasLiveGps
                                  ? (isFil
                                      ? 'Aktibo ang GPS (±${(emergency.gpsAccuracyMeters ?? 25).toStringAsFixed(0)}m)'
                                      : 'Live GPS Active (±${(emergency.gpsAccuracyMeters ?? 25).toStringAsFixed(0)}m)')
                                  : (isFil
                                      ? 'Lungsod ng Maynila (City of Manila)'
                                      : 'City of Manila'),
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: headingColor,
                              ),
                            ),
                            Text(
                              '${emergency.userLat.toStringAsFixed(4)}, ${emergency.userLng.toStringAsFixed(4)}',
                              style:
                                  TextStyle(fontSize: 12.5, color: subtleText),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (isFarFromManila) ...[
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(0, 42),
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                          ),
                          icon:
                              const Icon(Icons.location_city_rounded, size: 17),
                          label: Text(
                            isFil ? 'Maynila' : 'City of Manila',
                            style: const TextStyle(fontSize: 13),
                          ),
                          onPressed: () {
                            emergency.setManualLocation(
                              _manilaCenter.latitude,
                              _manilaCenter.longitude,
                            );
                            setState(() => _selectedCenter = null);
                            _safeMove(_manilaCenter, 13.0);
                          },
                        ),
                        const SizedBox(width: 8),
                      ],
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.teal.shade700,
                          foregroundColor: Colors.white,
                          minimumSize: const Size(0, 42),
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                        ),
                        icon: emergency.isLocating
                            ? const SizedBox(
                                width: 15,
                                height: 15,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.my_location_rounded, size: 17),
                        label: Text(
                          emergency.isLocating
                              ? (isFil ? 'Hinahanap...' : 'Locating...')
                              : (isFil ? 'GPS Ko' : 'My GPS'),
                          style: const TextStyle(fontSize: 13.5),
                        ),
                        onPressed: emergency.isLocating
                            ? null
                            : () async {
                                final ok = await emergency.detectLiveGps();
                                if (!context.mounted) return;
                                if (ok) {
                                  _safeMove(
                                    LatLng(
                                      emergency.userLat,
                                      emergency.userLng,
                                    ),
                                    14.0,
                                  );
                                }
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      ok
                                          ? (isFil
                                              ? 'Na-update ang lokasyon sa mapa!'
                                              : 'Location updated on map!')
                                          : (isFil
                                              ? 'Hindi makuha ang GPS. Ipinapakita ang mapa ng Lungsod ng Maynila.'
                                              : 'GPS unavailable. Showing City of Manila map.'),
                                    ),
                                  ),
                                );
                              },
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  // Search Bar for Manila Shelters, Hospitals, Police & Fire Stations
                  TextField(
                    controller: _searchController,
                    onChanged: (val) {
                      setState(() => _selectedCenter = null);
                      emergency.setShelterSearchQuery(val);
                    },
                    decoration: InputDecoration(
                      isDense: true,
                      prefixIcon: const Icon(Icons.search_rounded, size: 19),
                      suffixIcon: emergency.shelterSearchQuery.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.close_rounded, size: 17),
                              tooltip: 'Clear search',
                              onPressed: () {
                                _searchController.clear();
                                setState(() => _selectedCenter = null);
                                emergency.setShelterSearchQuery('');
                              },
                            )
                          : null,
                      hintText: isFil
                          ? 'Hanapin ang shelter, ospital, MPD/BFP, o kalye sa Maynila...'
                          : 'Search Manila shelter, hospital, MPD/BFP, or street...',
                      filled: true,
                      fillColor:
                          isDark ? AppTheme.darkElevated : AppTheme.surfaceBg,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: isDark
                              ? AppTheme.darkBorder
                              : AppTheme.lightBorder,
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: isDark
                              ? AppTheme.darkBorder
                              : AppTheme.lightBorder,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Facility Type Filter Chips + Open Only Toggle
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _buildFacilityChip(
                          label: isFil ? 'Lahat' : 'All Places',
                          icon: Icons.layers_outlined,
                          selected: emergency.selectedFacilityType == null,
                          color: AppTheme.primaryNavy,
                          isDark: isDark,
                          onTap: () {
                            setState(() => _selectedCenter = null);
                            emergency.setSelectedFacilityType(null);
                          },
                        ),
                        const SizedBox(width: 8),
                        _buildFacilityChip(
                          label: isFil ? 'Mga Shelter' : 'Shelters',
                          icon: Icons.roofing_rounded,
                          selected: emergency.selectedFacilityType ==
                              FacilityType.evacuationShelter,
                          color: Colors.teal.shade700,
                          isDark: isDark,
                          onTap: () {
                            setState(() => _selectedCenter = null);
                            emergency.setSelectedFacilityType(
                              FacilityType.evacuationShelter,
                            );
                          },
                        ),
                        const SizedBox(width: 8),
                        _buildFacilityChip(
                          label: isFil ? 'Ospital' : 'Hospitals',
                          icon: Icons.local_hospital_rounded,
                          selected: emergency.selectedFacilityType ==
                              FacilityType.hospital,
                          color: AppTheme.dangerRed,
                          isDark: isDark,
                          onTap: () {
                            setState(() => _selectedCenter = null);
                            emergency
                                .setSelectedFacilityType(FacilityType.hospital);
                          },
                        ),
                        const SizedBox(width: 8),
                        _buildFacilityChip(
                          label: isFil ? 'Pulis at Bumbero' : 'Police & Fire',
                          icon: Icons.local_police_rounded,
                          selected: emergency.selectedFacilityType ==
                              FacilityType.policeFire,
                          color: Colors.indigo.shade800,
                          isDark: isDark,
                          onTap: () {
                            setState(() => _selectedCenter = null);
                            emergency.setSelectedFacilityType(
                              FacilityType.policeFire,
                            );
                          },
                        ),
                        const SizedBox(width: 8),
                        FilterChip(
                          showCheckmark: false,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          avatar: Icon(
                            Icons.check_circle_outline_rounded,
                            size: 16,
                            color: emergency.onlyOpenFacilities
                                ? Colors.white
                                : AppTheme.safeGreen,
                          ),
                          label: Text(isFil ? 'Bukas Lang' : 'Open Only'),
                          selected: emergency.onlyOpenFacilities,
                          selectedColor: AppTheme.safeGreen,
                          backgroundColor: isDark
                              ? AppTheme.darkElevated
                              : AppTheme.surfaceBg,
                          side: BorderSide(
                            color: emergency.onlyOpenFacilities
                                ? AppTheme.safeGreen
                                : (isDark
                                    ? AppTheme.darkBorder
                                    : AppTheme.lightBorder),
                          ),
                          labelStyle: TextStyle(
                            color: emergency.onlyOpenFacilities
                                ? Colors.white
                                : (isDark ? Colors.white : AppTheme.darkSlate),
                            fontWeight: emergency.onlyOpenFacilities
                                ? FontWeight.w700
                                : FontWeight.w500,
                            fontSize: 13.5,
                          ),
                          onSelected: (val) {
                            setState(() => _selectedCenter = null);
                            emergency.setOnlyOpenFacilities(val);
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),

                  // District Filter Row (All City of Manila Districts)
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: cities.map((city) {
                        final isSelected = emergency.selectedCity == city;
                        return Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ChoiceChip(
                            showCheckmark: false,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            label: Text(
                              city == 'All'
                                  ? (isFil ? 'Buong Maynila' : 'All Manila')
                                  : city,
                            ),
                            selected: isSelected,
                            selectedColor: Colors.teal.shade700,
                            backgroundColor: isDark
                                ? AppTheme.darkElevated
                                : AppTheme.surfaceBg,
                            side: BorderSide(
                              color: isSelected
                                  ? Colors.teal.shade700
                                  : (isDark
                                      ? AppTheme.darkBorder
                                      : AppTheme.lightBorder),
                            ),
                            labelStyle: TextStyle(
                              color: isSelected
                                  ? Colors.white
                                  : (isDark
                                      ? Colors.white
                                      : AppTheme.darkSlate),
                              fontWeight: isSelected
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              fontSize: 13,
                            ),
                            onSelected: (_) {
                              setState(() => _selectedCenter = null);
                              emergency.setSelectedCity(city);
                              if (city == 'All') {
                                _safeMove(
                                  emergency.hasLiveGps && !isFarFromManila
                                      ? LatLng(
                                          emergency.userLat,
                                          emergency.userLng,
                                        )
                                      : _manilaCenter,
                                  13.0,
                                );
                              } else {
                                final district = manilaDistrictFilters[city];
                                if (district != null) {
                                  _safeMove(
                                    LatLng(district.lat, district.lng),
                                    14.5,
                                  );
                                }
                              }
                            },
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  _buildNearestOpenShelterStrip(
                    context,
                    emergency,
                    isDark,
                    isFil,
                    headingColor,
                    subtleText,
                    isSplit,
                  ),
                ],
              ),
            ),
          );

          final mapWidget = _buildInteractiveMap(
            context: context,
            emergency: emergency,
            centers: centers,
            isDark: isDark,
            isFil: isFil,
            isFarFromManila: isFarFromManila,
            isSplit: isSplit,
          );

          final shelterWidgets = centers.isEmpty
              ? [
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        children: [
                          Icon(
                            Icons.location_off_outlined,
                            size: 30,
                            color: subtleText,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            isFil
                                ? 'Walang nahanap na lugar sa napiling filter.'
                                : 'No Manila places match your selected filters.',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 14, color: subtleText),
                          ),
                          const SizedBox(height: 8),
                          TextButton(
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _selectedCenter = null);
                              emergency.setShelterSearchQuery('');
                              emergency.setSelectedCity('All');
                              emergency.setSelectedFacilityType(null);
                              emergency.setOnlyOpenFacilities(false);
                              _safeMove(_manilaCenter, 13.0);
                            },
                            child: Text(
                              isFil ? 'I-reset ang Filter' : 'Reset Filters',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ]
              : centers.asMap().entries.map((entry) {
                  return _buildShelterCard(
                    context,
                    entry.value,
                    emergency,
                    entry.key == 0,
                    isDark,
                    isFil,
                    isSplit,
                  );
                }).toList();

          if (isSplit) {
            return Column(
              children: [
                headerPanel,
                const Divider(height: 1),
                Expanded(
                  child: ResponsiveContainer(
                    maxWidth: 1160,
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          flex: 11,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(18),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: isDark
                                      ? AppTheme.darkBorder
                                      : AppTheme.lightBorder,
                                ),
                                borderRadius: BorderRadius.circular(18),
                              ),
                              child: mapWidget,
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          flex: 10,
                          child: ListView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.only(bottom: 36),
                            children: shelterWidgets,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          }

          // Mobile / Narrow Stacked View: page scrolls smoothly while touching outside map,
          // and touching inside the map locks page scroll so panning works effortlessly in all directions.
          return ListView(
            controller: _mobileScrollController,
            physics: _isPanningMobileMap
                ? const NeverScrollableScrollPhysics()
                : const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(bottom: 96),
            children: [
              headerPanel,
              const Divider(height: 1),
              Padding(
                key: _mapSectionKey,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Listener(
                  onPointerDown: (_) {
                    if (!_isPanningMobileMap) {
                      setState(() => _isPanningMobileMap = true);
                    }
                  },
                  onPointerUp: (_) {
                    if (_isPanningMobileMap) {
                      setState(() => _isPanningMobileMap = false);
                    }
                  },
                  onPointerCancel: (_) {
                    if (_isPanningMobileMap) {
                      setState(() => _isPanningMobileMap = false);
                    }
                  },
                  child: SizedBox(
                    height: 305,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: isDark
                                ? AppTheme.darkBorder
                                : AppTheme.lightBorder,
                          ),
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: mapWidget,
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      isFil
                          ? 'Mga Malapit na Lugar (${centers.length})'
                          : 'Nearby Manila Places (${centers.length})',
                      style: TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w800,
                        color: headingColor,
                      ),
                    ),
                    Text(
                      isFil ? 'Pinakamalapit muna' : 'Nearest first',
                      style: TextStyle(fontSize: 12, color: subtleText),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(children: shelterWidgets),
              ),
            ],
          );
        },
      ),
    );
  }

  // Subtle cartographic tile filters (100% compatible with offline OSM tile caching)
  static const ColorFilter _lightMutedMapFilter = ColorFilter.matrix(<double>[
    0.6693, 0.3004, 0.0303, 0, 12,
    0.0893, 0.8804, 0.0303, 0, 12,
    0.0893, 0.3004, 0.6103, 0, 14,
    0,      0,      0,      1,  0,
  ]);

  static const ColorFilter _darkSlateMapFilter = ColorFilter.matrix(<double>[
    -0.381, -0.363, -0.036, 0, 225,
    -0.108, -0.636, -0.036, 0, 234,
    -0.108, -0.363, -0.310, 0, 249,
     0,      0,      0,     1,   0,
  ]);

  TileLayer _buildStyledTileLayer(bool isDark) {
    return TileLayer(
      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      userAgentPackageName: 'com.lifecheckpoint.app',
      tileBuilder: (context, tileWidget, tile) => ColorFiltered(
        colorFilter: isDark ? _darkSlateMapFilter : _lightMutedMapFilter,
        child: tileWidget,
      ),
    );
  }

  EvacuationCenter? _findNearestOpenShelter(
    EmergencyProvider emergency,
    List<EvacuationCenter> centers,
  ) {
    final openShelters = centers
        .where(
          (c) => c.facilityType == FacilityType.evacuationShelter && c.isOpen,
        )
        .toList();
    if (openShelters.isEmpty) return null;
    openShelters.sort(
      (a, b) => emergency
          .distanceToCenterKm(a)
          .compareTo(emergency.distanceToCenterKm(b)),
    );
    return openShelters.first;
  }

  int _markerZPriority(
    EvacuationCenter center, {
    required String? selectedId,
    required String? nearestShelterId,
  }) {
    if (center.id == selectedId) return 4;
    if (center.id == nearestShelterId) return 3;
    if (!center.isOpen) return 0;
    if (center.facilityType == FacilityType.evacuationShelter) return 2;
    if (center.facilityType == FacilityType.hospital) return 1;
    return 0;
  }

  List<Marker> _buildPriorityMarkers({
    required List<EvacuationCenter> centers,
    required LatLng userPoint,
    required EvacuationCenter? selectedCenter,
    required EvacuationCenter? nearestOpenShelter,
    required double zoom,
    required bool isFil,
    required void Function(EvacuationCenter center) onSelectCenter,
  }) {
    final zoomedIn = zoom >= 13.8;
    final selectedId = selectedCenter?.id;
    final nearestId = nearestOpenShelter?.id;

    // Sort bottom-to-top so primary shelters, selected pins & You NEVER get buried
    final sorted = List<EvacuationCenter>.from(centers)
      ..sort(
        (a, b) => _markerZPriority(
          a,
          selectedId: selectedId,
          nearestShelterId: nearestId,
        ).compareTo(
          _markerZPriority(
            b,
            selectedId: selectedId,
            nearestShelterId: nearestId,
          ),
        ),
      );

    return [
      ...sorted.map((center) {
        final isSel = center.id == selectedId;
        final isNearest = center.id == nearestId && !isSel;
        final isHosp = center.facilityType == FacilityType.hospital;
        final isPF = center.facilityType == FacilityType.policeFire;

        final Color pinColor = !center.isOpen
            ? Colors.blueGrey.shade500
            : (isHosp
                ? AppTheme.dangerRed
                : (isPF ? Colors.indigo.shade700 : Colors.teal.shade700));
        final IconData pinIcon = !center.isOpen
            ? Icons.pause_circle_outline_rounded
            : (isHosp
                ? Icons.local_hospital_rounded
                : (isPF
                    ? Icons.local_police_rounded
                    : Icons.roofing_rounded));

        // Clear visual hierarchy: Shelters prominent, Hospitals medium, Police/Fire compact
        final double dotSize = isSel
            ? 42
            : (isNearest
                ? 34
                : (isPF
                    ? (zoomedIn ? 26 : 22)
                    : (isHosp
                        ? (zoomedIn ? 30 : 26)
                        : (zoomedIn ? 34 : 30))));
        final double iconSize = isSel
            ? 20
            : (isNearest
                ? 17
                : (isPF
                    ? (zoomedIn ? 14 : 12)
                    : (isHosp
                        ? (zoomedIn ? 16 : 14)
                        : (zoomedIn ? 18 : 16))));
        final double hitBox = isSel ? 50 : (isNearest ? 46 : 36);

        return Marker(
          point: LatLng(center.latitude, center.longitude),
          width: hitBox,
          height: hitBox,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onSelectCenter(center),
            child: Tooltip(
              message:
                  '${center.name}${isNearest ? (isFil ? ' • Pinakamalapit' : ' • Nearest Open') : ''}${center.isOpen ? '' : ' (Standby)'}',
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  width: isNearest ? dotSize + 10 : dotSize,
                  height: isNearest ? dotSize + 10 : dotSize,
                  decoration: isNearest
                      ? BoxDecoration(
                          color: Colors.teal.shade600.withAlpha(58),
                          shape: BoxShape.circle,
                        )
                      : null,
                  alignment: Alignment.center,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    width: dotSize,
                    height: dotSize,
                    decoration: BoxDecoration(
                      color: pinColor,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white,
                        width: isSel ? 2.8 : (isPF ? 1.8 : 2.2),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withAlpha(isSel ? 95 : 65),
                          blurRadius: isSel ? 10 : 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Icon(pinIcon, color: Colors.white, size: iconSize),
                  ),
                ),
              ),
            ),
          ),
        );
      }),
      // User Location Blue Dot — ALWAYS rendered on top with prominent halo
      Marker(
        point: userPoint,
        width: 40,
        height: 40,
        child: Tooltip(
          message: isFil ? 'Iyong Lokasyon' : 'Your Location',
          child: Center(
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: const Color(0xFF2563EB).withAlpha(65),
                shape: BoxShape.circle,
                border: Border.all(
                  color: const Color(0xFF2563EB).withAlpha(110),
                  width: 1.5,
                ),
              ),
              alignment: Alignment.center,
              child: Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  color: const Color(0xFF2563EB),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2.8),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF2563EB).withAlpha(140),
                      blurRadius: 8,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ];
  }

  Widget _buildGroupedMapControls({
    required bool isDark,
    required bool isFil,
    required bool hasLiveGps,
    required VoidCallback onZoomIn,
    required VoidCallback onZoomOut,
    required VoidCallback onCenterUser,
    required VoidCallback onCenterManila,
  }) {
    final bg = (isDark ? AppTheme.darkCard : Colors.white).withAlpha(244);
    final border = isDark ? AppTheme.darkBorder : AppTheme.lightBorder;
    final iconColor = isDark ? Colors.white : AppTheme.darkSlate;

    Widget buildGroup(List<Widget> children) {
      return Material(
        color: bg,
        elevation: 2.5,
        shadowColor: Colors.black.withAlpha(55),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(11),
          side: BorderSide(color: border),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(mainAxisSize: MainAxisSize.min, children: children),
      );
    }

    Widget buildSlot({
      required IconData icon,
      required String tooltip,
      required VoidCallback onTap,
      Color? color,
    }) {
      return InkWell(
        onTap: onTap,
        child: Tooltip(
          message: tooltip,
          child: SizedBox(
            width: 38,
            height: 37,
            child: Icon(icon, size: 19, color: color ?? iconColor),
          ),
        ),
      );
    }

    final divider = Container(width: 24, height: 1, color: border);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        buildGroup([
          buildSlot(
            icon: Icons.add_rounded,
            tooltip: 'Zoom In',
            onTap: onZoomIn,
          ),
          divider,
          buildSlot(
            icon: Icons.remove_rounded,
            tooltip: 'Zoom Out',
            onTap: onZoomOut,
          ),
        ]),
        const SizedBox(height: 8),
        buildGroup([
          buildSlot(
            icon: Icons.my_location_rounded,
            tooltip: isFil ? 'Punta sa GPS Ko' : 'Center on Me',
            color: hasLiveGps ? const Color(0xFF2563EB) : iconColor,
            onTap: onCenterUser,
          ),
          divider,
          buildSlot(
            icon: Icons.location_city_rounded,
            tooltip: isFil
                ? 'I-center sa Lungsod ng Maynila'
                : 'Center on City of Manila',
            onTap: onCenterManila,
          ),
        ]),
      ],
    );
  }

  Future<void> _openFullScreenNearbyMap(
    BuildContext context,
    EmergencyProvider emergency,
    List<EvacuationCenter> centers,
    bool isDark,
    bool isFil,
    bool isFarFromManila,
  ) async {
    final fullCtrl = MapController();
    final userPoint = LatLng(emergency.userLat, emergency.userLng);
    LatLng startCenter = _selectedCenter != null
        ? LatLng(_selectedCenter!.latitude, _selectedCenter!.longitude)
        : (isFarFromManila ? _manilaCenter : userPoint);
    double startZoom = _selectedCenter != null ? 15.0 : 13.5;
    try {
      startCenter = _mapController.camera.center;
      startZoom = _mapController.camera.zoom;
    } catch (_) {}

    EvacuationCenter? activeSelected = _selectedCenter;
    double fullZoom = startZoom;
    EvacuationRouteResult? fullStreetRoute = _activeStreetRoute;
    String? fullRouteKey = _activeRouteKey;

    final pickedBack = await Navigator.of(context).push<EvacuationCenter?>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setFullState) {
            final nearestOpen = _findNearestOpenShelter(emergency, centers);
            final guideTarget = activeSelected ?? nearestOpen;
            final showLine = guideTarget != null &&
                emergency.distanceToCenterKm(guideTarget) <= 30.0;
            final isExplicitLine = activeSelected != null;
            final hasStandby = centers.any((c) => !c.isOpen);

            if (showLine) {
              final dest = LatLng(guideTarget.latitude, guideTarget.longitude);
              final nextKey = ManilaRouteService.buildCacheKey(userPoint, dest);
              if (fullRouteKey != nextKey) {
                fullRouteKey = nextKey;
                fullStreetRoute = null;
                ManilaRouteService.getStreetRoute(from: userPoint, to: dest)
                    .then((res) {
                  if (ctx.mounted && fullRouteKey == nextKey && res != null) {
                    setFullState(() => fullStreetRoute = res);
                  }
                });
              }
            }

            void moveFull(LatLng target, double zoom) {
              try {
                fullCtrl.move(target, zoom.clamp(10.0, 18.5));
              } catch (_) {}
            }

            void zoomFull(double delta) {
              try {
                final cam = fullCtrl.camera;
                fullCtrl.move(cam.center, (cam.zoom + delta).clamp(10.0, 18.5));
              } catch (_) {}
            }

            return Scaffold(
              appBar: AppBar(
                title: Text(
                  isFil
                      ? 'Buong Mapa ng Maynila (${centers.length})'
                      : 'City of Manila Map (${centers.length})',
                ),
              ),
              body: Stack(
                children: [
                  FlutterMap(
                    mapController: fullCtrl,
                    options: MapOptions(
                      initialCenter: startCenter,
                      initialZoom: startZoom,
                      minZoom: 10.0,
                      maxZoom: 18.5,
                      interactionOptions: const InteractionOptions(
                        flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                      ),
                      onPositionChanged: (camera, _) {
                        final wasZoomed = fullZoom >= 13.8;
                        final nowZoomed = camera.zoom >= 13.8;
                        fullZoom = camera.zoom;
                        if (wasZoomed != nowZoomed) {
                          setFullState(() {});
                        }
                      },
                      onTap: (_, __) {
                        if (activeSelected != null) {
                          setFullState(() => activeSelected = null);
                        }
                      },
                    ),
                    children: [
                      _buildStyledTileLayer(isDark),
                      if (showLine)
                        _buildRoutePolylineLayer(
                          userPoint: userPoint,
                          target: guideTarget,
                          streetRoute: fullStreetRoute,
                          isExplicitLine: isExplicitLine,
                          isDark: isDark,
                        ),
                      MarkerLayer(
                        markers: _buildPriorityMarkers(
                          centers: centers,
                          userPoint: userPoint,
                          selectedCenter: activeSelected,
                          nearestOpenShelter: nearestOpen,
                          zoom: fullZoom,
                          isFil: isFil,
                          onSelectCenter: (center) {
                            setFullState(() => activeSelected = center);
                            moveFull(
                              LatLng(center.latitude, center.longitude),
                              15.2,
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                  Positioned(
                    top: 12,
                    right: 12,
                    child: _buildGroupedMapControls(
                      isDark: isDark,
                      isFil: isFil,
                      hasLiveGps: emergency.hasLiveGps,
                      onZoomIn: () => zoomFull(1.0),
                      onZoomOut: () => zoomFull(-1.0),
                      onCenterUser: () => moveFull(userPoint, 14.5),
                      onCenterManila: () => moveFull(_manilaCenter, 13.0),
                    ),
                  ),
                  if (activeSelected == null)
                    Positioned(
                      left: 12,
                      right: 12,
                      bottom: 14,
                      child: SafeArea(
                        top: false,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 7,
                          ),
                          decoration: BoxDecoration(
                            color: (isDark ? AppTheme.darkCard : Colors.white)
                                .withAlpha(240),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: isDark
                                  ? AppTheme.darkBorder
                                  : AppTheme.lightBorder,
                            ),
                          ),
                          child: Wrap(
                            spacing: 10,
                            runSpacing: 4,
                            children: [
                              _legendDot(
                                const Color(0xFF2563EB),
                                isFil ? 'Ikaw' : 'You',
                                isDark,
                              ),
                              _legendDot(
                                Colors.teal.shade700,
                                'Shelter',
                                isDark,
                              ),
                              _legendDot(
                                AppTheme.dangerRed,
                                isFil ? 'Ospital' : 'Hospital',
                                isDark,
                              ),
                              _legendDot(
                                isDark
                                    ? Colors.indigo.shade300
                                    : Colors.indigo.shade700,
                                isFil ? 'Pulis/Bumbero' : 'Police/Fire',
                                isDark,
                              ),
                              if (hasStandby)
                                _legendDot(
                                  Colors.blueGrey.shade500,
                                  'Standby',
                                  isDark,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (activeSelected != null)
                    Positioned(
                      left: 12,
                      right: 12,
                      bottom: 14,
                      child: SafeArea(
                        top: false,
                        child: _buildMapPopupCard(
                          ctx,
                          activeSelected!,
                          emergency,
                          isDark,
                          isFil,
                          streetRoute: fullStreetRoute,
                          onClose: () =>
                              setFullState(() => activeSelected = null),
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );

    if (mounted && pickedBack != null) {
      setState(() => _selectedCenter = pickedBack);
    }
  }

  Widget _buildInteractiveMap({
    required BuildContext context,
    required EmergencyProvider emergency,
    required List<EvacuationCenter> centers,
    required bool isDark,
    required bool isFil,
    required bool isFarFromManila,
    required bool isSplit,
  }) {
    final userPoint = LatLng(emergency.userLat, emergency.userLng);
    final initialFocus = isFarFromManila ? _manilaCenter : userPoint;
    final hasStandbyCenters = centers.any((c) => !c.isOpen);
    final nearestOpen = _findNearestOpenShelter(emergency, centers);
    final guideTarget = _selectedCenter ?? nearestOpen;
    final isExplicitLine = _selectedCenter != null;
    final showGuideLine = guideTarget != null &&
        emergency.distanceToCenterKm(guideTarget) <= 30.0;
    if (showGuideLine) {
      _ensureStreetRoute(userPoint, guideTarget);
    }

    final markers = _buildPriorityMarkers(
      centers: centers,
      userPoint: userPoint,
      selectedCenter: _selectedCenter,
      nearestOpenShelter: nearestOpen,
      zoom: _currentZoom,
      isFil: isFil,
      onSelectCenter: (center) => _focusCenter(center),
    );

    final isMapOfflineReady = _cachedTileCount >= 35;

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: initialFocus,
            initialZoom: 13.0,
            minZoom: 5.0,
            maxZoom: 18.0,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
            onPositionChanged: (camera, _) {
              final wasZoomed = _currentZoom >= 13.8;
              final nowZoomed = camera.zoom >= 13.8;
              _currentZoom = camera.zoom;
              if (wasZoomed != nowZoomed && mounted) {
                setState(() {});
              }
            },
            onTap: (_, __) {
              if (_selectedCenter != null) {
                setState(() => _selectedCenter = null);
              }
            },
          ),
          children: [
            _buildStyledTileLayer(isDark),
            if (showGuideLine)
              _buildRoutePolylineLayer(
                userPoint: userPoint,
                target: guideTarget,
                streetRoute: _activeStreetRoute,
                isExplicitLine: isExplicitLine,
                isDark: isDark,
              ),
            MarkerLayer(markers: markers),
          ],
        ),

        // Top-left Full-Screen + 1-Tap Offline Manila Map Pills
        Positioned(
          top: 12,
          left: 12,
          right: 60,
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              Material(
                color: (isDark ? AppTheme.darkCard : Colors.white).withAlpha(244),
                elevation: 2.5,
                shadowColor: Colors.black.withAlpha(55),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(11),
                  side: BorderSide(
                    color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => _openFullScreenNearbyMap(
                    context,
                    emergency,
                    centers,
                    isDark,
                    isFil,
                    isFarFromManila,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 8,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.open_in_full_rounded,
                          size: 15,
                          color: isDark
                              ? Colors.lightBlue.shade200
                              : AppTheme.primaryNavy,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          isFil ? 'Buong Mapa' : 'Full Screen',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: isDark ? Colors.white : AppTheme.darkSlate,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (supportsOfflineMapDownload)
                Material(
                  color: isMapOfflineReady
                      ? (isDark
                          ? const Color(0xFF064E3B).withAlpha(240)
                          : const Color(0xFFECFDF5).withAlpha(248))
                      : (isDark ? AppTheme.darkCard : Colors.white)
                          .withAlpha(244),
                  elevation: 2.5,
                  shadowColor: Colors.black.withAlpha(55),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(11),
                    side: BorderSide(
                      color: isMapOfflineReady
                          ? AppTheme.safeGreen.withAlpha(150)
                          : (isDark
                              ? AppTheme.darkBorder
                              : AppTheme.lightBorder),
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: _isDownloadingMap
                        ? null
                        : () => _handleDownloadOfflineMap(context, isFil),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_isDownloadingMap)
                            SizedBox(
                              width: 13,
                              height: 13,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: isDark
                                    ? Colors.tealAccent
                                    : Colors.teal.shade700,
                              ),
                            )
                          else
                            Icon(
                              isMapOfflineReady
                                  ? Icons.offline_pin_rounded
                                  : Icons.download_for_offline_outlined,
                              size: 15,
                              color: isMapOfflineReady
                                  ? AppTheme.safeGreen
                                  : (isDark
                                      ? Colors.tealAccent
                                      : Colors.teal.shade700),
                            ),
                          const SizedBox(width: 5),
                          Text(
                            _isDownloadingMap
                                ? '$_mapDownloadDone/$_mapDownloadTotal'
                                : (isMapOfflineReady
                                    ? (isFil ? 'Offline Handa' : 'Offline Ready')
                                    : (isFil ? 'Save Offline' : 'Save Map')),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: isMapOfflineReady
                                  ? (isDark
                                      ? const Color(0xFF6EE7B7)
                                      : const Color(0xFF065F46))
                                  : (isDark
                                      ? Colors.white
                                      : AppTheme.darkSlate),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),

        // Top-right Grouped Map Controls (+ / - and GPS / City of Manila)
        Positioned(
          top: 12,
          right: 12,
          child: _buildGroupedMapControls(
            isDark: isDark,
            isFil: isFil,
            hasLiveGps: emergency.hasLiveGps,
            onZoomIn: () => _zoomBy(1.0),
            onZoomOut: () => _zoomBy(-1.0),
            onCenterUser: () => _safeMove(userPoint, 14.5),
            onCenterManila: () => _safeMove(_manilaCenter, 13.0),
          ),
        ),

        // Bottom-left Compact Legend + OpenStreetMap Attribution
        if (_selectedCenter == null)
          Positioned(
            left: 10,
            bottom: 10,
            right: 10,
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: (isDark ? AppTheme.darkCard : Colors.white)
                        .withAlpha(240),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color:
                          isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                    ),
                  ),
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 4,
                    children: [
                      _legendDot(
                        const Color(0xFF2563EB),
                        isFil ? 'Ikaw' : 'You',
                        isDark,
                      ),
                      _legendDot(
                        Colors.teal.shade700,
                        'Shelter',
                        isDark,
                      ),
                      _legendDot(
                        AppTheme.dangerRed,
                        isFil ? 'Ospital' : 'Hospital',
                        isDark,
                      ),
                      _legendDot(
                        isDark ? Colors.indigo.shade300 : Colors.indigo.shade700,
                        isFil ? 'Pulis/Bumbero' : 'Police/Fire',
                        isDark,
                      ),
                      if (hasStandbyCenters)
                        _legendDot(
                          Colors.blueGrey.shade500,
                          'Standby',
                          isDark,
                        ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: (isDark ? AppTheme.darkCard : Colors.white)
                        .withAlpha(225),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '© OpenStreetMap',
                    style: TextStyle(
                      fontSize: 11,
                      color: isDark ? Colors.white70 : AppTheme.mutedSlate,
                    ),
                  ),
                ),
              ],
            ),
          ),

        // Selected Facility Floating Popup Card on Map
        if (_selectedCenter != null)
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: _buildMapPopupCard(
              context,
              _selectedCenter!,
              emergency,
              isDark,
              isFil,
              streetRoute: _activeStreetRoute,
            ),
          ),
      ],
    );
  }

  Widget _legendDot(Color color, String label, bool isDark) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: isDark ? Colors.white : AppTheme.darkSlate,
          ),
        ),
      ],
    );
  }

  Future<void> _shareShelterPin(
    BuildContext context,
    EvacuationCenter center,
    bool isFil,
  ) async {
    final lat = center.latitude.toStringAsFixed(5);
    final lng = center.longitude.toStringAsFixed(5);
    final text =
        'Meet at ${center.name}\nAddress: ${center.address}\nMap: https://maps.google.com/?q=$lat,$lng\nHotline: ${center.contactNumber}';
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: AppTheme.safeGreen,
        content: Text(
          isFil
              ? 'Nakopya ang lokasyon ng shelter — i-paste sa Messenger o SMS!'
              : 'Shelter meeting pin copied — paste into Messenger or SMS!',
        ),
      ),
    );
  }

  Widget _buildNearestOpenShelterStrip(
    BuildContext context,
    EmergencyProvider emergency,
    bool isDark,
    bool isFil,
    Color headingColor,
    Color subtleText,
    bool isSplit,
  ) {
    final openShelters = emergency.allEvacuationCenters
        .where(
          (c) => c.facilityType == FacilityType.evacuationShelter && c.isOpen,
        )
        .toList();
    if (openShelters.isEmpty) return const SizedBox.shrink();

    openShelters.sort(
      (a, b) => emergency
          .distanceToCenterKm(a)
          .compareTo(emergency.distanceToCenterKm(b)),
    );
    final nearest = openShelters.first;
    final distKm = emergency.distanceToCenterKm(nearest);

    return Material(
      color: Colors.teal.withAlpha(isDark ? 36 : 16),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _focusCenter(nearest, scrollToMap: !isSplit),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Colors.teal.withAlpha(isDark ? 90 : 55),
            ),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: AppTheme.safeGreen,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  isFil ? 'PINAKAMALAPIT' : 'NEAREST OPEN',
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${nearest.name} (${distKm.toStringAsFixed(1)} km)',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: headingColor,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              TextButton.icon(
                style: TextButton.styleFrom(
                  foregroundColor:
                      isDark ? Colors.tealAccent : Colors.teal.shade800,
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                icon: const Icon(Icons.directions_rounded, size: 16),
                label: Text(
                  isFil ? 'Ruta' : 'Go',
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                onPressed: () => ActionFeedback.openMapWithFeedback(
                  context,
                  emergency,
                  nearest.latitude,
                  nearest.longitude,
                  nearest.name,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMapPopupCard(
    BuildContext context,
    EvacuationCenter center,
    EmergencyProvider emergency,
    bool isDark,
    bool isFil, {
    EvacuationRouteResult? streetRoute,
    VoidCallback? onClose,
  }) {
    final hasRoad = streetRoute != null && streetRoute.isStreetRoute;
    final distKm =
        hasRoad ? streetRoute.distanceKm : emergency.distanceToCenterKm(center);
    final cardinal = emergency.bearingToCenter(center);
    final etaText = hasRoad
        ? (isFil
            ? '~${streetRoute.walkMinutes} min lakad • ~${streetRoute.driveMinutes} min biyahe'
            : '~${streetRoute.walkMinutes} min walk • ~${streetRoute.driveMinutes} min drive')
        : _formatEta(distKm, isFil);
    final titleColor = isDark ? Colors.white : AppTheme.darkSlate;
    final subtleText = isDark ? Colors.white70 : AppTheme.mutedSlate;

    return Card(
      elevation: 4,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    center.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w800,
                      color: titleColor,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                if (hasRoad) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.teal.withAlpha(isDark ? 55 : 22),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      streetRoute.fromOfflineCache
                          ? (isFil ? 'Ruta (Offline)' : 'Cached Route')
                          : (isFil ? 'Ruta sa Kalsada' : 'Street Route'),
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        color:
                            isDark ? Colors.tealAccent : Colors.teal.shade800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                Text(
                  hasRoad
                      ? '${distKm.toStringAsFixed(1)} km'
                      : '${distKm.toStringAsFixed(1)} km $cardinal',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: isDark ? Colors.tealAccent : Colors.teal.shade700,
                  ),
                ),
                const SizedBox(width: 4),
                InkWell(
                  onTap:
                      onClose ?? () => setState(() => _selectedCenter = null),
                  child: Icon(Icons.close_rounded, size: 19, color: subtleText),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              '${center.address} • $etaText',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: subtleText),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.teal.shade700,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(0, 38),
                    ),
                    icon: const Icon(Icons.directions_rounded, size: 16),
                    label: Text(
                      isFil ? 'Direksyon' : 'Directions',
                      style: const TextStyle(fontSize: 13),
                    ),
                    onPressed: () => ActionFeedback.openMapWithFeedback(
                      context,
                      emergency,
                      center.latitude,
                      center.longitude,
                      center.name,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 38),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  icon: const Icon(Icons.call_rounded, size: 16),
                  label: Text(
                    isFil ? 'Tawag' : 'Call',
                    style: const TextStyle(fontSize: 12.5),
                  ),
                  onPressed: () => ActionFeedback.callWithFeedback(
                    context,
                    emergency,
                    center.contactNumber,
                    center.contactPerson,
                  ),
                ),
                const SizedBox(width: 6),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 38),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  icon: const Icon(Icons.share_rounded, size: 16),
                  label: Text(
                    isFil ? 'Ibahagi' : 'Share',
                    style: const TextStyle(fontSize: 12.5),
                  ),
                  onPressed: () => _shareShelterPin(context, center, isFil),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFacilityChip({
    required String label,
    required IconData icon,
    required bool selected,
    required Color color,
    required bool isDark,
    required VoidCallback onTap,
  }) {
    return ChoiceChip(
      showCheckmark: false,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      avatar: Icon(
        icon,
        size: 16,
        color: selected ? Colors.white : (isDark ? Colors.white70 : color),
      ),
      label: Text(label),
      selected: selected,
      selectedColor: color,
      backgroundColor: isDark ? AppTheme.darkElevated : AppTheme.surfaceBg,
      side: BorderSide(
        color: selected
            ? color
            : (isDark ? AppTheme.darkBorder : AppTheme.lightBorder),
      ),
      labelStyle: TextStyle(
        color: selected
            ? Colors.white
            : (isDark ? Colors.white : AppTheme.darkSlate),
        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        fontSize: 13.5,
      ),
      onSelected: (_) => onTap(),
    );
  }

  Widget _buildShelterCard(
    BuildContext context,
    EvacuationCenter center,
    EmergencyProvider emergency,
    bool isNearest,
    bool isDark,
    bool isFil,
    bool isSplit,
  ) {
    final distKm = emergency.distanceToCenterKm(center);
    final cardinal = emergency.bearingToCenter(center);
    final etaText = _formatEta(distKm, isFil);
    final isSelected = _selectedCenter?.id == center.id;
    final isFamilySaved = emergency.isCustomCenter(center.id);

    final isHospital = center.facilityType == FacilityType.hospital;
    final isPoliceFire = center.facilityType == FacilityType.policeFire;

    final Color facilityAccent = !center.isOpen
        ? Colors.blueGrey.shade500
        : (isHospital
            ? AppTheme.dangerRed
            : (isPoliceFire ? Colors.indigo.shade600 : Colors.teal.shade700));
    final IconData facilityIcon = isHospital
        ? Icons.local_hospital_rounded
        : (isPoliceFire
            ? Icons.local_police_rounded
            : Icons.roofing_rounded);
    final String typeLabel = isHospital
        ? (isFil ? 'Ospital' : 'Hospital')
        : (isPoliceFire
            ? (isFil ? 'Pulis at Bumbero' : 'Police & Fire')
            : 'Evacuation Shelter');

    final titleColor = isDark ? Colors.white : AppTheme.darkSlate;
    final subtleText = isDark ? Colors.white70 : AppTheme.mutedSlate;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: isSelected || isNearest
            ? BorderSide(
                color: facilityAccent.withAlpha(isSelected ? 230 : 150),
                width: isSelected ? 2 : 1.3,
              )
            : BorderSide(
                color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
              ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _focusCenter(center, scrollToMap: !isSplit),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: facilityAccent.withAlpha(isDark ? 45 : 20),
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          facilityIcon,
                          size: 13,
                          color: isDark ? Colors.white : facilityAccent,
                        ),
                        const SizedBox(width: 5),
                        Text(
                          typeLabel,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: isDark ? Colors.white : facilityAccent,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (isFamilySaved) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.warningAmber.withAlpha(isDark ? 55 : 26),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Text(
                        isFil ? 'Pamilya' : 'Family Saved',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: isDark
                              ? Colors.amber.shade200
                              : const Color(0xFFB45309),
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                  if (isNearest) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: facilityAccent,
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Text(
                        isFil ? 'Pinakamalapit' : 'Nearest',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                  const Spacer(),
                  Text(
                    '${distKm.toStringAsFixed(1)} km • $cardinal',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: isDark ? Colors.tealAccent : Colors.teal.shade800,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      center.name,
                      style: TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w800,
                        color: titleColor,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: center.isOpen
                              ? AppTheme.safeGreen
                              : AppTheme.dangerRed,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        center.isOpen
                            ? (isFil ? 'Bukas' : 'Open')
                            : 'Standby',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: center.isOpen
                              ? AppTheme.safeGreen
                              : AppTheme.dangerRed,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${center.address} (${center.city})',
                style: TextStyle(fontSize: 13.5, color: subtleText),
              ),
              const SizedBox(height: 4),
              Text(
                etaText,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.tealAccent : Colors.teal.shade700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${center.facilities}${center.capacityPeople > 0 ? ' • ${isFil ? 'Kapasidad' : 'Capacity'}: ${center.capacityPeople}' : ''}',
                style: TextStyle(
                  fontSize: 13,
                  color: subtleText.withAlpha(210),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.teal.shade700,
                        foregroundColor: Colors.white,
                        minimumSize: const Size(0, 44),
                      ),
                      icon: const Icon(Icons.directions_rounded, size: 18),
                      label: Text(isFil ? 'Direksyon' : 'Directions'),
                      onPressed: () => ActionFeedback.openMapWithFeedback(
                        context,
                        emergency,
                        center.latitude,
                        center.longitude,
                        center.name,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 44),
                      ),
                      icon: const Icon(Icons.call_rounded, size: 18),
                      label: Text(isFil ? 'Tumawag' : 'Call'),
                      onPressed: () => ActionFeedback.callWithFeedback(
                        context,
                        emergency,
                        center.contactNumber,
                        center.contactPerson,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton.outlined(
                    icon: const Icon(Icons.share_rounded, size: 19),
                    tooltip: isFil
                        ? 'Ibahagi ang Lokasyon sa Pamilya'
                        : 'Share Meeting Pin',
                    onPressed: () => _shareShelterPin(context, center, isFil),
                  ),
                  if (isFamilySaved) ...[
                    const SizedBox(width: 4),
                    IconButton(
                      icon: const Icon(
                        Icons.delete_outline_rounded,
                        color: AppTheme.dangerRed,
                      ),
                      tooltip: isFil
                          ? 'Burahin ang Naka-save na Shelter'
                          : 'Delete Family Shelter',
                      onPressed: () => _confirmDeleteFamilyShelter(
                        context,
                        emergency,
                        center,
                        isFil,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDeleteFamilyShelter(
    BuildContext context,
    EmergencyProvider emergency,
    EvacuationCenter center,
    bool isFil,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          isFil ? 'Burahin ang Shelter ng Pamilya?' : 'Remove Family Shelter?',
        ),
        content: Text(
          isFil
              ? 'Aalisin ang "${center.name}" sa naka-save na listahan ng iyong pamilya.'
              : 'Remove "${center.name}" from your family\'s saved shelter list?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(isFil ? 'Kanselahin' : 'Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.dangerRed,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(isFil ? 'Burahin' : 'Remove'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      if (_selectedCenter?.id == center.id) {
        setState(() => _selectedCenter = null);
      }
      await emergency.removeCustomEvacuationCenter(center.id);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isFil
                ? 'Nabura ang "${center.name}".'
                : 'Removed "${center.name}".',
          ),
        ),
      );
    }
  }

  Future<void> _showAddShelterDialog(
    BuildContext context,
    EmergencyProvider emergency,
    bool isFil,
  ) async {
    final nameCtrl = TextEditingController();
    final addrCtrl = TextEditingController();
    final cityCtrl = TextEditingController(text: 'Manila');
    final contactCtrl = TextEditingController(text: '(02) 8568-6909');
    final dialogScrollCtrl = ScrollController();
    final miniMapCtrl = MapController();

    LatLng pickedPoint = LatLng(emergency.userLat, emergency.userLng);
    bool isPanningMap = false;
    String? nameError;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          void setPin(LatLng target, {double? zoom}) {
            setDialogState(() => pickedPoint = target);
            try {
              miniMapCtrl.move(
                target,
                (zoom ?? miniMapCtrl.camera.zoom).clamp(10.0, 18.5),
              );
            } catch (_) {}
          }

          void zoomMini(double delta) {
            try {
              final cam = miniMapCtrl.camera;
              miniMapCtrl.move(
                cam.center,
                (cam.zoom + delta).clamp(10.0, 18.5),
              );
            } catch (_) {}
          }

          return AlertDialog(
            title: Text(
              isFil
                  ? 'I-save ang Barangay / Family Shelter'
                  : 'Save Barangay / Family Shelter',
            ),
            content: SizedBox(
              width: 500,
              child: SingleChildScrollView(
                controller: dialogScrollCtrl,
                physics: isPanningMap
                    ? const NeverScrollableScrollPhysics()
                    : const ClampingScrollPhysics(),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppTheme.primaryAccent.withAlpha(20),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.lock_outline_rounded,
                            size: 16,
                            color: AppTheme.primaryAccent,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              isFil
                                  ? 'Pribado para sa iyong pamilya at naka-sync na kamag-anak — hindi binabago ang opisyal na Manila shelters.'
                                  : 'Saved privately for your household & synced relatives — does not alter official Manila shelters.',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: nameCtrl,
                      onChanged: (_) {
                        if (nameError != null) {
                          setDialogState(() => nameError = null);
                        }
                      },
                      decoration: InputDecoration(
                        labelText: isFil
                            ? 'Pangalan ng Covered Court / Safe Place *'
                            : 'Barangay Hall / Covered Court / Safe Place *',
                        errorText: nameError,
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: addrCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Address / Barangay / Landmark *',
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: cityCtrl,
                            decoration: InputDecoration(
                              labelText: isFil ? 'Lungsod' : 'City',
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: contactCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Hotline / Contact',
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: manilaDistrictFilters.entries.map((entry) {
                          return Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: ActionChip(
                              visualDensity: VisualDensity.compact,
                              label: Text(
                                entry.key,
                                style: const TextStyle(fontSize: 11.5),
                              ),
                              onPressed: () {
                                cityCtrl.text = 'Manila';
                                if (addrCtrl.text.trim().isEmpty) {
                                  addrCtrl.text = '${entry.key}, Manila';
                                }
                                setPin(
                                  LatLng(entry.value.lat, entry.value.lng),
                                  zoom: 14.8,
                                );
                              },
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          isFil
                              ? 'Ituro sa mapa:'
                              : 'Pin exact location:',
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            minimumSize: const Size(0, 32),
                          ),
                          icon: const Icon(Icons.my_location_rounded, size: 15),
                          label: Text(
                            isFil ? 'GPS Ko' : 'Use My GPS',
                            style: const TextStyle(fontSize: 12),
                          ),
                          onPressed: () async {
                            await emergency.detectLiveGps();
                            setPin(
                              LatLng(emergency.userLat, emergency.userLng),
                              zoom: 15.0,
                            );
                          },
                        ),
                        FilledButton.tonalIcon(
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(0, 32),
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                          ),
                          icon: const Icon(Icons.open_in_full_rounded, size: 14),
                          label: Text(
                            isFil ? 'Buong Mapa' : 'Full-Screen Map',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          onPressed: () async {
                            final picked = await ManilaFullScreenMapPicker.show(
                              ctx,
                              initialPoint: pickedPoint,
                              isFil: isFil,
                            );
                            if (picked != null && ctx.mounted) {
                              if (picked.suggestedAddress != null &&
                                  addrCtrl.text.trim().isEmpty) {
                                addrCtrl.text = picked.suggestedAddress!;
                              }
                              setPin(picked.coords, zoom: 16.0);
                            }
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Listener(
                      onPointerDown: (_) =>
                          setDialogState(() => isPanningMap = true),
                      onPointerUp: (_) =>
                          setDialogState(() => isPanningMap = false),
                      onPointerCancel: (_) =>
                          setDialogState(() => isPanningMap = false),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: SizedBox(
                          height: 220,
                          child: Stack(
                            children: [
                              FlutterMap(
                                mapController: miniMapCtrl,
                                options: MapOptions(
                                  initialCenter: pickedPoint,
                                  initialZoom: 14.0,
                                  minZoom: 10.0,
                                  maxZoom: 18.5,
                                  interactionOptions: const InteractionOptions(
                                    flags: InteractiveFlag.all &
                                        ~InteractiveFlag.rotate,
                                  ),
                                  onTap: (_, latLng) => setPin(latLng),
                                ),
                                children: [
                                  TileLayer(
                                    urlTemplate:
                                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                                    userAgentPackageName:
                                        'com.lifecheckpoint.app',
                                  ),
                                  MarkerLayer(
                                    markers: [
                                      Marker(
                                        point: pickedPoint,
                                        width: 40,
                                        height: 40,
                                        child: const Icon(
                                          Icons.location_pin,
                                          color: AppTheme.dangerRed,
                                          size: 38,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              Positioned(
                                right: 8,
                                bottom: 8,
                                child: Column(
                                  children: [
                                    Material(
                                      color: Colors.white,
                                      elevation: 2,
                                      borderRadius: BorderRadius.circular(8),
                                      child: InkWell(
                                        borderRadius: BorderRadius.circular(8),
                                        onTap: () => zoomMini(1.0),
                                        child: const Padding(
                                          padding: EdgeInsets.all(6),
                                          child: Icon(
                                            Icons.add_rounded,
                                            size: 19,
                                            color: AppTheme.primaryNavy,
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Material(
                                      color: Colors.white,
                                      elevation: 2,
                                      borderRadius: BorderRadius.circular(8),
                                      child: InkWell(
                                        borderRadius: BorderRadius.circular(8),
                                        onTap: () => zoomMini(-1.0),
                                        child: const Padding(
                                          padding: EdgeInsets.all(6),
                                          child: Icon(
                                            Icons.remove_rounded,
                                            size: 19,
                                            color: AppTheme.primaryNavy,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Pinned GPS: ${pickedPoint.latitude.toStringAsFixed(5)}, ${pickedPoint.longitude.toStringAsFixed(5)}',
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: AppTheme.mutedSlate,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(isFil ? 'Kanselahin' : 'Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  if (nameCtrl.text.trim().isEmpty) {
                    setDialogState(
                      () => nameError = isFil
                          ? 'Ilagay muna ang pangalan ng shelter.'
                          : 'Please enter a shelter name first.',
                    );
                    if (dialogScrollCtrl.hasClients) {
                      dialogScrollCtrl.animateTo(
                        0,
                        duration: const Duration(milliseconds: 260),
                        curve: Curves.easeOut,
                      );
                    }
                    return;
                  }
                  Navigator.pop(ctx, true);
                },
                child: Text(
                  isFil ? 'I-save para sa Pamilya' : 'Save for Family',
                ),
              ),
            ],
          );
        },
      ),
    );

    final name = nameCtrl.text.trim();
    final addr = addrCtrl.text.trim();
    final city = cityCtrl.text.trim();
    final phone = contactCtrl.text.trim();

    Future.delayed(const Duration(milliseconds: 400), () {
      nameCtrl.dispose();
      addrCtrl.dispose();
      cityCtrl.dispose();
      contactCtrl.dispose();
      dialogScrollCtrl.dispose();
    });

    if (saved == true && mounted) {
      final newCenter = EvacuationCenter(
        id: 'custom_${const Uuid().v4()}',
        name: name,
        address: addr.isEmpty ? 'Local Manila Barangay Site' : addr,
        city: city.isEmpty ? 'Manila' : city,
        latitude: pickedPoint.latitude,
        longitude: pickedPoint.longitude,
        contactPerson: 'Barangay / Family Contact',
        contactNumber: phone.isEmpty ? '(02) 8568-6909' : phone,
        capacityPeople: 0,
        facilities: 'Family-Saved Barangay Shelter / Safe Spot',
      );
      await emergency.addCustomEvacuationCenter(newCenter);
      _focusCenter(newCenter);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: AppTheme.safeGreen,
            content: Text(
              isFil
                  ? 'Nai-save ang "$name" para sa iyong pamilya!'
                  : 'Saved "$name" privately for your family!',
            ),
          ),
        );
      }
    }
  }
}
