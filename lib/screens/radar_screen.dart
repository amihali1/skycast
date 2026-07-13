import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../models/forecast.dart';

/// Animated precipitation radar over an OpenStreetMap base layer.
///
/// Radar tiles come from RainViewer's free public API: past ~2 hours of
/// observed radar plus a short nowcast (~30 min forecast). No API key.
class RadarScreen extends StatefulWidget {
  const RadarScreen({super.key, required this.place});

  final Place place;

  @override
  State<RadarScreen> createState() => _RadarScreenState();
}

class _RadarFrame {
  const _RadarFrame({required this.time, required this.path, required this.isForecast});

  final DateTime time;
  final String path;
  final bool isForecast;
}

class _RadarScreenState extends State<RadarScreen> {
  String? _host;
  List<_RadarFrame> _frames = const [];
  int _index = 0;
  String? _error;
  bool _playing = false;
  Timer? _playTimer;

  @override
  void initState() {
    super.initState();
    _loadFrames();
  }

  @override
  void dispose() {
    _playTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadFrames() async {
    setState(() => _error = null);
    try {
      final response = await http
          .get(Uri.parse('https://api.rainviewer.com/public/weather-maps.json'));
      if (response.statusCode != 200) {
        throw Exception('RainViewer request failed (${response.statusCode})');
      }
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final host = json['host'] as String;
      final radar = json['radar'] as Map<String, dynamic>;

      List<_RadarFrame> parse(String key, bool isForecast) =>
          ((radar[key] as List?) ?? const [])
              .map((f) => _RadarFrame(
                    time: DateTime.fromMillisecondsSinceEpoch(
                        (f['time'] as num).toInt() * 1000),
                    path: f['path'] as String,
                    isForecast: isForecast,
                  ))
              .toList();

      final frames = [...parse('past', false), ...parse('nowcast', true)];
      if (frames.isEmpty) throw Exception('No radar frames available');

      if (!mounted) return;
      setState(() {
        _host = host;
        _frames = frames;
        // Start on the most recent observed frame.
        _index = frames.lastIndexWhere((f) => !f.isForecast).clamp(0, frames.length - 1);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  void _togglePlay() {
    setState(() => _playing = !_playing);
    _playTimer?.cancel();
    if (_playing) {
      _playTimer = Timer.periodic(const Duration(milliseconds: 600), (_) {
        if (!mounted) return;
        setState(() => _index = (_index + 1) % _frames.length);
      });
    }
  }

  String _frameLabel(_RadarFrame frame) {
    final t = frame.time.toLocal();
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final m = t.minute.toString().padLeft(2, '0');
    final ampm = t.hour < 12 ? 'AM' : 'PM';
    return '$h:$m $ampm${frame.isForecast ? '  (forecast)' : ''}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Radar — ${widget.place.name}')),
      body: _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_error!),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: _loadFrames, child: const Text('Retry')),
                ],
              ),
            )
          : _frames.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    Expanded(
                      child: FlutterMap(
                        options: MapOptions(
                          initialCenter: LatLng(
                              widget.place.latitude, widget.place.longitude),
                          initialZoom: 7,
                        ),
                        children: [
                          TileLayer(
                            urlTemplate:
                                'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                            userAgentPackageName: 'dev.andym.skycast',
                          ),
                          Opacity(
                            opacity: 0.7,
                            child: TileLayer(
                              urlTemplate:
                                  '$_host${_frames[_index].path}/256/{z}/{x}/{y}/2/1_1.png',
                              userAgentPackageName: 'dev.andym.skycast',
                            ),
                          ),
                          const SimpleAttributionWidget(
                            source: Text('OpenStreetMap · RainViewer'),
                          ),
                        ],
                      ),
                    ),
                    SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Row(
                          children: [
                            IconButton(
                              icon: Icon(
                                  _playing ? Icons.pause : Icons.play_arrow),
                              onPressed: _togglePlay,
                              tooltip: _playing ? 'Pause' : 'Play',
                            ),
                            Expanded(
                              child: Slider(
                                value: _index.toDouble(),
                                min: 0,
                                max: (_frames.length - 1).toDouble(),
                                divisions: _frames.length - 1,
                                onChanged: (v) =>
                                    setState(() => _index = v.round()),
                              ),
                            ),
                            SizedBox(
                              width: 110,
                              child: Text(
                                _frameLabel(_frames[_index]),
                                textAlign: TextAlign.right,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}
