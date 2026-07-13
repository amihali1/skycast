import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/forecast.dart';

/// Client for the free, no-key Open-Meteo APIs.
class OpenMeteoService {
  OpenMeteoService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const _forecastHost = 'api.open-meteo.com';
  static const _geocodingHost = 'geocoding-api.open-meteo.com';

  Future<List<Place>> searchPlaces(String query) async {
    if (query.trim().length < 2) return const [];
    final uri = Uri.https(_geocodingHost, '/v1/search', {
      'name': query.trim(),
      'count': '8',
      'language': 'en',
      'format': 'json',
    });
    final body = await _get(uri);
    final results = body['results'] as List?;
    if (results == null) return const [];
    return results
        .map((r) => Place.fromGeocodingJson(r as Map<String, dynamic>))
        .toList();
  }

  Future<Forecast> fetchForecast(Place place) async {
    final uri = Uri.https(_forecastHost, '/v1/forecast', {
      'latitude': place.latitude.toString(),
      'longitude': place.longitude.toString(),
      'current':
          'temperature_2m,apparent_temperature,relative_humidity_2m,is_day,weather_code,wind_speed_10m',
      'hourly': 'temperature_2m,weather_code,precipitation_probability',
      'daily':
          'weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max',
      'timezone': 'auto',
      'forecast_days': '8',
    });
    return Forecast.fromJson(await _get(uri));
  }

  Future<Map<String, dynamic>> _get(Uri uri) async {
    final response = await _client.get(uri);
    if (response.statusCode != 200) {
      throw OpenMeteoException(
          'Open-Meteo request failed (${response.statusCode})');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }
}

class OpenMeteoException implements Exception {
  OpenMeteoException(this.message);
  final String message;

  @override
  String toString() => message;
}
