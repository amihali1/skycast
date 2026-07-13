/// Data models for Open-Meteo forecast and geocoding responses.
library;

class Place {
  const Place({
    required this.name,
    required this.latitude,
    required this.longitude,
    this.admin1,
    this.country,
  });

  final String name;
  final double latitude;
  final double longitude;
  final String? admin1;
  final String? country;

  String get label {
    final parts = [name, if (admin1 != null) admin1, if (country != null) country];
    return parts.join(', ');
  }

  factory Place.fromGeocodingJson(Map<String, dynamic> json) => Place(
        name: json['name'] as String,
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        admin1: json['admin1'] as String?,
        country: json['country'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'latitude': latitude,
        'longitude': longitude,
        'admin1': admin1,
        'country': country,
      };

  factory Place.fromJson(Map<String, dynamic> json) => Place(
        name: json['name'] as String,
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        admin1: json['admin1'] as String?,
        country: json['country'] as String?,
      );
}

class CurrentWeather {
  const CurrentWeather({
    required this.temperatureC,
    required this.apparentC,
    required this.humidity,
    required this.windSpeedKmh,
    required this.weatherCode,
    required this.isDay,
  });

  final double temperatureC;
  final double apparentC;
  final int humidity;
  final double windSpeedKmh;
  final int weatherCode;
  final bool isDay;
}

class HourlyPoint {
  const HourlyPoint({
    required this.time,
    required this.temperatureC,
    required this.weatherCode,
    required this.precipProbability,
  });

  final DateTime time;
  final double temperatureC;
  final int weatherCode;
  final int precipProbability;
}

class MinutelyPoint {
  const MinutelyPoint({required this.time, required this.precipitationMm});

  final DateTime time;
  final double precipitationMm;
}

class DailyPoint {
  const DailyPoint({
    required this.date,
    required this.weatherCode,
    required this.minC,
    required this.maxC,
    required this.precipProbability,
  });

  final DateTime date;
  final int weatherCode;
  final double minC;
  final double maxC;
  final int precipProbability;
}

class Forecast {
  const Forecast({
    required this.current,
    required this.hourly,
    required this.daily,
    required this.minutely,
  });

  final CurrentWeather current;
  final List<HourlyPoint> hourly;
  final List<DailyPoint> daily;

  /// 15-minute precipitation forecast; empty where the region lacks
  /// high-resolution model coverage.
  final List<MinutelyPoint> minutely;

  factory Forecast.fromJson(Map<String, dynamic> json) {
    final current = json['current'] as Map<String, dynamic>;
    final hourly = json['hourly'] as Map<String, dynamic>;
    final daily = json['daily'] as Map<String, dynamic>;
    final minutely = json['minutely_15'] as Map<String, dynamic>?;

    final minutelyTimes = (minutely?['time'] as List?)?.cast<String>() ?? const [];
    final minutelyPrecip =
        (minutely?['precipitation'] as List?)?.cast<num?>() ?? const [];

    final hourlyTimes = (hourly['time'] as List).cast<String>();
    final hourlyTemps = (hourly['temperature_2m'] as List).cast<num>();
    final hourlyCodes = (hourly['weather_code'] as List).cast<num>();
    final hourlyPrecip = (hourly['precipitation_probability'] as List?)?.cast<num?>();

    final dailyTimes = (daily['time'] as List).cast<String>();
    final dailyCodes = (daily['weather_code'] as List).cast<num>();
    final dailyMin = (daily['temperature_2m_min'] as List).cast<num>();
    final dailyMax = (daily['temperature_2m_max'] as List).cast<num>();
    final dailyPrecip = (daily['precipitation_probability_max'] as List?)?.cast<num?>();

    return Forecast(
      current: CurrentWeather(
        temperatureC: (current['temperature_2m'] as num).toDouble(),
        apparentC: (current['apparent_temperature'] as num).toDouble(),
        humidity: (current['relative_humidity_2m'] as num).toInt(),
        windSpeedKmh: (current['wind_speed_10m'] as num).toDouble(),
        weatherCode: (current['weather_code'] as num).toInt(),
        isDay: (current['is_day'] as num) == 1,
      ),
      hourly: [
        for (var i = 0; i < hourlyTimes.length; i++)
          HourlyPoint(
            time: DateTime.parse(hourlyTimes[i]),
            temperatureC: hourlyTemps[i].toDouble(),
            weatherCode: hourlyCodes[i].toInt(),
            precipProbability: hourlyPrecip?[i]?.toInt() ?? 0,
          ),
      ],
      minutely: [
        for (var i = 0; i < minutelyTimes.length; i++)
          MinutelyPoint(
            time: DateTime.parse(minutelyTimes[i]),
            precipitationMm: minutelyPrecip[i]?.toDouble() ?? 0,
          ),
      ],
      daily: [
        for (var i = 0; i < dailyTimes.length; i++)
          DailyPoint(
            date: DateTime.parse(dailyTimes[i]),
            weatherCode: dailyCodes[i].toInt(),
            minC: dailyMin[i].toDouble(),
            maxC: dailyMax[i].toDouble(),
            precipProbability: dailyPrecip?[i]?.toInt() ?? 0,
          ),
      ],
    );
  }
}
