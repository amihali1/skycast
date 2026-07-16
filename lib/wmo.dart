import 'package:flutter/material.dart';

/// WMO weather interpretation codes (WW) used by Open-Meteo,
/// mapped to a human label and an icon.
class Wmo {
  static String label(int code) => switch (code) {
        0 => 'Clear sky',
        1 => 'Mainly clear',
        2 => 'Partly cloudy',
        3 => 'Overcast',
        45 || 48 => 'Fog',
        51 || 53 || 55 => 'Drizzle',
        56 || 57 => 'Freezing drizzle',
        61 => 'Light rain',
        63 => 'Rain',
        65 => 'Heavy rain',
        66 || 67 => 'Freezing rain',
        71 => 'Light snow',
        73 => 'Snow',
        75 => 'Heavy snow',
        77 => 'Snow grains',
        80 || 81 => 'Rain showers',
        82 => 'Violent rain showers',
        85 || 86 => 'Snow showers',
        95 => 'Thunderstorm',
        96 || 99 => 'Thunderstorm with hail',
        _ => 'Unknown',
      };

  static IconData icon(int code, {required bool isDay}) => switch (code) {
        0 || 1 => isDay ? Icons.wb_sunny : Icons.nights_stay,
        2 => Icons.wb_cloudy,
        3 => Icons.cloud,
        45 || 48 => Icons.foggy,
        // Icons.grain (an 8-dot grid) read as snowfall; umbrella says
        // "light rain" without colliding with the rain or snow glyphs.
        51 || 53 || 55 => Icons.umbrella,
        // Freezing drizzle/rain is an ice hazard, not ordinary rain.
        56 || 57 || 66 || 67 => Icons.severe_cold,
        61 || 63 || 65 || 80 || 81 || 82 => Icons.water_drop,
        71 || 73 || 75 || 77 || 85 || 86 => Icons.ac_unit,
        95 || 96 || 99 => Icons.thunderstorm,
        _ => Icons.help_outline,
      };

  /// Background gradient tuned to conditions and time of day.
  static List<Color> gradient(int code, {required bool isDay}) {
    if (!isDay) {
      return const [Color(0xFF0F2027), Color(0xFF203A43), Color(0xFF2C5364)];
    }
    return switch (code) {
      0 || 1 => const [Color(0xFF2980B9), Color(0xFF6DD5FA)],
      2 || 3 => const [Color(0xFF616161), Color(0xFF9BC5C3)],
      45 || 48 => const [Color(0xFF757F9A), Color(0xFFD7DDE8)],
      >= 51 && <= 67 || >= 80 && <= 82 => const [
          Color(0xFF373B44),
          Color(0xFF4286F4)
        ],
      >= 71 && <= 77 || 85 || 86 => const [Color(0xFF83A4D4), Color(0xFFB6FBFF)],
      95 || 96 || 99 => const [Color(0xFF232526), Color(0xFF414345)],
      _ => const [Color(0xFF2980B9), Color(0xFF6DD5FA)],
    };
  }
}
