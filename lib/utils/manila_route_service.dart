import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'location_service.dart';

class EvacuationRouteResult {
  final List<LatLng> points;
  final double distanceKm;
  final int walkMinutes;
  final int driveMinutes;
  final bool isStreetRoute;
  final bool fromOfflineCache;

  const EvacuationRouteResult({
    required this.points,
    required this.distanceKm,
    required this.walkMinutes,
    required this.driveMinutes,
    required this.isStreetRoute,
    this.fromOfflineCache = false,
  });

  Map<String, dynamic> toMap() => {
        'points': points
            .map((p) => [
                  double.parse(p.latitude.toStringAsFixed(5)),
                  double.parse(p.longitude.toStringAsFixed(5)),
                ])
            .toList(),
        'distanceKm': distanceKm,
        'walkMinutes': walkMinutes,
        'driveMinutes': driveMinutes,
        'cachedAt': DateTime.now().toIso8601String(),
      };

  factory EvacuationRouteResult.fromCachedMap(Map<String, dynamic> map) {
    final rawPts = (map['points'] as List<dynamic>? ?? []);
    final pts = <LatLng>[];
    for (final item in rawPts) {
      if (item is List && item.length >= 2) {
        final lat = (item[0] as num?)?.toDouble();
        final lng = (item[1] as num?)?.toDouble();
        if (lat != null && lng != null) {
          pts.add(LatLng(lat, lng));
        }
      }
    }
    return EvacuationRouteResult(
      points: pts,
      distanceKm: ((map['distanceKm'] ?? 0) as num).toDouble(),
      walkMinutes: ((map['walkMinutes'] ?? 1) as num).toInt().clamp(1, 999),
      driveMinutes: ((map['driveMinutes'] ?? 1) as num).toInt().clamp(1, 999),
      isStreetRoute: pts.length >= 2,
      fromOfflineCache: true,
    );
  }
}

/// Fetches real Manila street-level evacuation routes via OpenStreetMap OSRM
/// with automatic local caching in SharedPreferences for offline reuse.
class ManilaRouteService {
  static const String _storageKey = 'lifecheckpoint_street_routes_v1';
  static const int _maxCachedRoutes = 15;

  static final Map<String, EvacuationRouteResult> _memoryCache = {};
  static bool _diskLoaded = false;

  static String buildCacheKey(LatLng from, LatLng to) {
    return '${from.latitude.toStringAsFixed(3)},${from.longitude.toStringAsFixed(3)}'
        '->${to.latitude.toStringAsFixed(4)},${to.longitude.toStringAsFixed(4)}';
  }

  static Future<void> _ensureDiskLoaded() async {
    if (_diskLoaded) return;
    _diskLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = json.decode(raw);
      if (decoded is Map<String, dynamic>) {
        decoded.forEach((key, value) {
          if (value is Map) {
            final parsed = EvacuationRouteResult.fromCachedMap(
              Map<String, dynamic>.from(value),
            );
            if (parsed.points.length >= 2) {
              _memoryCache[key] = parsed;
            }
          }
        });
      }
    } catch (_) {}
  }

  static Future<void> _persistCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = _memoryCache.keys.toList();
      final trimmedKeys = keys.length > _maxCachedRoutes
          ? keys.sublist(keys.length - _maxCachedRoutes)
          : keys;
      final out = <String, dynamic>{};
      for (final k in trimmedKeys) {
        final v = _memoryCache[k];
        if (v != null && v.isStreetRoute) {
          out[k] = v.toMap();
        }
      }
      await prefs.setString(_storageKey, json.encode(out));
    } catch (_) {}
  }

  static Future<EvacuationRouteResult?> getStreetRoute({
    required LatLng from,
    required LatLng to,
  }) async {
    final straightKm = LocationService.distanceInKm(
      from.latitude,
      from.longitude,
      to.latitude,
      to.longitude,
    );
    if (straightKm > 30.0 || straightKm < 0.03) return null;

    await _ensureDiskLoaded();
    final key = buildCacheKey(from, to);
    final cached = _memoryCache[key];
    if (cached != null) {
      return cached;
    }

    try {
      final uri = Uri.parse(
        'https://router.project-osrm.org/route/v1/foot/'
        '${from.longitude.toStringAsFixed(5)},${from.latitude.toStringAsFixed(5)};'
        '${to.longitude.toStringAsFixed(5)},${to.latitude.toStringAsFixed(5)}'
        '?overview=full&geometries=geojson',
      );
      final resp = await http
          .get(uri, headers: const {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 4));

      if (resp.statusCode == 200) {
        final data = json.decode(resp.body);
        if (data is Map && data['routes'] is List && (data['routes'] as List).isNotEmpty) {
          final route = data['routes'][0] as Map;
          final geom = route['geometry'];
          final coords = geom is Map ? (geom['coordinates'] as List? ?? []) : [];
          final pts = <LatLng>[];
          for (final c in coords) {
            if (c is List && c.length >= 2) {
              final lng = (c[0] as num?)?.toDouble();
              final lat = (c[1] as num?)?.toDouble();
              if (lat != null && lng != null) {
                pts.add(LatLng(lat, lng));
              }
            }
          }
          if (pts.length >= 2) {
            final meters = ((route['distance'] ?? 0) as num).toDouble();
            final km = meters > 0 ? meters / 1000.0 : straightKm;
            final walkMin = (km / 4.5 * 60).round().clamp(1, 999);
            final driveMin = (km / 18.0 * 60).round().clamp(1, 999);

            final result = EvacuationRouteResult(
              points: pts,
              distanceKm: km,
              walkMinutes: walkMin,
              driveMinutes: driveMin,
              isStreetRoute: true,
              fromOfflineCache: false,
            );
            _memoryCache[key] = result;
            await _persistCache();
            return result;
          }
        }
      }
    } catch (_) {
      // Gracefully fall back to dashed compass guidance line when offline/slow
    }
    return null;
  }
}
