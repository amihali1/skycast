/// Current air quality from the Open-Meteo air-quality API.
class AirQuality {
  const AirQuality({
    required this.usAqi,
    required this.pm25,
    required this.pm10,
    required this.ozone,
  });

  factory AirQuality.fromJson(Map<String, dynamic> json) {
    final current = json['current'] as Map<String, dynamic>;
    return AirQuality(
      usAqi: (current['us_aqi'] as num).round(),
      pm25: (current['pm2_5'] as num?)?.toDouble() ?? 0,
      pm10: (current['pm10'] as num?)?.toDouble() ?? 0,
      ozone: (current['ozone'] as num?)?.toDouble() ?? 0,
    );
  }

  final int usAqi;
  final double pm25;
  final double pm10;
  final double ozone;

  /// EPA AQI category name.
  String get category => switch (usAqi) {
        <= 50 => 'Good',
        <= 100 => 'Moderate',
        <= 150 => 'Unhealthy for sensitive groups',
        <= 200 => 'Unhealthy',
        <= 300 => 'Very unhealthy',
        _ => 'Hazardous',
      };
}
