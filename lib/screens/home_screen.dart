import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

import '../models/forecast.dart';
import '../services/open_meteo.dart';
import '../wmo.dart';

const _defaultPlace = Place(
  name: 'New York',
  latitude: 40.7143,
  longitude: -74.006,
  admin1: 'New York',
  country: 'United States',
);

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _service = OpenMeteoService();

  Place _place = _defaultPlace;
  Forecast? _forecast;
  String? _error;
  bool _useFahrenheit = true;

  @override
  void initState() {
    super.initState();
    _restoreAndLoad();
  }

  Future<void> _restoreAndLoad() async {
    final prefs = await SharedPreferences.getInstance();
    final savedPlace = prefs.getString('place');
    setState(() {
      _useFahrenheit = prefs.getBool('useFahrenheit') ?? true;
      if (savedPlace != null) {
        _place = Place.fromJson(jsonDecode(savedPlace) as Map<String, dynamic>);
      }
    });
    await _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final forecast = await _service.fetchForecast(_place);
      if (!mounted) return;
      setState(() => _forecast = forecast);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  Future<void> _selectPlace(Place place) async {
    setState(() {
      _place = place;
      _forecast = null;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('place', jsonEncode(place.toJson()));
    await _load();
  }

  Future<void> _toggleUnit() async {
    setState(() => _useFahrenheit = !_useFahrenheit);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('useFahrenheit', _useFahrenheit);
  }

  String _temp(double celsius) {
    final value = _useFahrenheit ? celsius * 9 / 5 + 32 : celsius;
    return '${value.round()}°';
  }

  Future<void> _openSearch() async {
    final selected = await showSearch<Place?>(
      context: context,
      delegate: _PlaceSearchDelegate(_service),
    );
    if (selected != null) {
      await _selectPlace(selected);
    }
  }

  @override
  Widget build(BuildContext context) {
    final forecast = _forecast;
    final code = forecast?.current.weatherCode ?? 0;
    final isDay = forecast?.current.isDay ?? true;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 600),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: Wmo.gradient(code, isDay: isDay),
        ),
      ),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          foregroundColor: Colors.white,
          title: Text(_place.name),
          actions: [
            TextButton(
              onPressed: _toggleUnit,
              child: Text(
                _useFahrenheit ? '°F' : '°C',
                style: const TextStyle(color: Colors.white, fontSize: 18),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.search),
              onPressed: _openSearch,
              tooltip: 'Search city',
            ),
          ],
        ),
        body: _buildBody(forecast),
      ),
    );
  }

  Widget _buildBody(Forecast? forecast) {
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, color: Colors.white70, size: 48),
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Colors.white)),
            const SizedBox(height: 12),
            FilledButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }
    if (forecast == null) {
      return const Center(
          child: CircularProgressIndicator(color: Colors.white));
    }

    final now = DateTime.now();
    final upcomingHours = forecast.hourly
        .where((h) => h.time.isAfter(now.subtract(const Duration(hours: 1))))
        .take(24)
        .toList();

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          _CurrentPanel(
            current: forecast.current,
            temp: _temp,
          ),
          const SizedBox(height: 24),
          _HourlyStrip(hours: upcomingHours, temp: _temp),
          const SizedBox(height: 24),
          _DailyList(days: forecast.daily, temp: _temp),
          const SizedBox(height: 24),
          const Center(
            child: Text(
              'Data: Open-Meteo.com — no ads, ever.',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _CurrentPanel extends StatelessWidget {
  const _CurrentPanel({required this.current, required this.temp});

  final CurrentWeather current;
  final String Function(double) temp;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 24),
        Icon(
          Wmo.icon(current.weatherCode, isDay: current.isDay),
          color: Colors.white,
          size: 72,
        ),
        Text(
          temp(current.temperatureC),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 96,
            fontWeight: FontWeight.w200,
            height: 1.1,
          ),
        ),
        Text(
          Wmo.label(current.weatherCode),
          style: const TextStyle(color: Colors.white, fontSize: 22),
        ),
        const SizedBox(height: 8),
        Text(
          'Feels like ${temp(current.apparentC)}  ·  '
          'Humidity ${current.humidity}%  ·  '
          'Wind ${current.windSpeedKmh.round()} km/h',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
      ],
    );
  }
}

class _HourlyStrip extends StatelessWidget {
  const _HourlyStrip({required this.hours, required this.temp});

  final List<HourlyPoint> hours;
  final String Function(double) temp;

  String _hourLabel(DateTime t) {
    final h = t.hour;
    if (h == 0) return '12 AM';
    if (h < 12) return '$h AM';
    if (h == 12) return '12 PM';
    return '${h - 12} PM';
  }

  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      child: SizedBox(
        height: 130,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: hours.length,
          separatorBuilder: (_, _) => const SizedBox(width: 20),
          itemBuilder: (context, i) {
            final h = hours[i];
            return Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(i == 0 ? 'Now' : _hourLabel(h.time),
                    style: const TextStyle(color: Colors.white70, fontSize: 12)),
                const SizedBox(height: 8),
                Icon(Wmo.icon(h.weatherCode, isDay: h.time.hour >= 6 && h.time.hour < 20),
                    color: Colors.white, size: 24),
                const SizedBox(height: 8),
                Text(temp(h.temperatureC),
                    style: const TextStyle(color: Colors.white, fontSize: 15)),
                if (h.precipProbability > 0)
                  Text('${h.precipProbability}%',
                      style: const TextStyle(
                          color: Colors.lightBlueAccent, fontSize: 11)),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _DailyList extends StatelessWidget {
  const _DailyList({required this.days, required this.temp});

  final List<DailyPoint> days;
  final String Function(double) temp;

  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    return _GlassCard(
      child: Column(
        children: [
          for (final (i, d) in days.indexed)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  SizedBox(
                    width: 64,
                    child: Text(
                      i == 0 && d.date.day == today.day
                          ? 'Today'
                          : _weekdays[d.date.weekday - 1],
                      style: const TextStyle(color: Colors.white, fontSize: 15),
                    ),
                  ),
                  Icon(Wmo.icon(d.weatherCode, isDay: true),
                      color: Colors.white, size: 22),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 40,
                    child: d.precipProbability > 0
                        ? Text('${d.precipProbability}%',
                            style: const TextStyle(
                                color: Colors.lightBlueAccent, fontSize: 12))
                        : const SizedBox.shrink(),
                  ),
                  const Spacer(),
                  Text(temp(d.minC),
                      style:
                          const TextStyle(color: Colors.white54, fontSize: 15)),
                  const SizedBox(width: 16),
                  Text(temp(d.maxC),
                      style:
                          const TextStyle(color: Colors.white, fontSize: 15)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _GlassCard extends StatelessWidget {
  const _GlassCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: child,
    );
  }
}

class _PlaceSearchDelegate extends SearchDelegate<Place?> {
  _PlaceSearchDelegate(this._service)
      : super(searchFieldLabel: 'Search city…');

  final OpenMeteoService _service;

  @override
  List<Widget> buildActions(BuildContext context) => [
        if (query.isNotEmpty)
          IconButton(icon: const Icon(Icons.clear), onPressed: () => query = ''),
      ];

  @override
  Widget buildLeading(BuildContext context) => IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () => close(context, null),
      );

  @override
  Widget buildResults(BuildContext context) => _resultsList();

  @override
  Widget buildSuggestions(BuildContext context) => _resultsList();

  Widget _resultsList() {
    return FutureBuilder<List<Place>>(
      future: _service.searchPlaces(query),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final places = snapshot.data ?? const <Place>[];
        if (places.isEmpty) {
          return Center(
            child: Text(query.trim().length < 2
                ? 'Type a city name'
                : 'No matches'),
          );
        }
        return ListView.builder(
          itemCount: places.length,
          itemBuilder: (context, i) {
            final place = places[i];
            return ListTile(
              leading: const Icon(Icons.location_city),
              title: Text(place.name),
              subtitle: Text(place.label),
              onTap: () => close(context, place),
            );
          },
        );
      },
    );
  }
}
