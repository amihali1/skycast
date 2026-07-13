import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/forecast.dart';

/// Animated precipitation radar over an OpenStreetMap base layer.
///
/// Radar tiles are NOAA NEXRAD composites served by the Iowa Environmental
/// Mesonet (IEM) tile cache — free, no API key. Coverage is US only.
/// Frames span the last ~50 minutes in 5-minute steps.
class RadarScreen extends StatefulWidget {
  const RadarScreen({super.key, required this.place});

  final Place place;

  @override
  State<RadarScreen> createState() => _RadarScreenState();
}

class _RadarFrame {
  const _RadarFrame({required this.minutesAgo, required this.layer});

  final int minutesAgo;
  final String layer;

  String get urlTemplate =>
      'https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/$layer/{z}/{x}/{y}.png';
}

const _frames = [
  _RadarFrame(minutesAgo: 50, layer: 'nexrad-n0q-900913-m50m'),
  _RadarFrame(minutesAgo: 45, layer: 'nexrad-n0q-900913-m45m'),
  _RadarFrame(minutesAgo: 40, layer: 'nexrad-n0q-900913-m40m'),
  _RadarFrame(minutesAgo: 35, layer: 'nexrad-n0q-900913-m35m'),
  _RadarFrame(minutesAgo: 30, layer: 'nexrad-n0q-900913-m30m'),
  _RadarFrame(minutesAgo: 25, layer: 'nexrad-n0q-900913-m25m'),
  _RadarFrame(minutesAgo: 20, layer: 'nexrad-n0q-900913-m20m'),
  _RadarFrame(minutesAgo: 15, layer: 'nexrad-n0q-900913-m15m'),
  _RadarFrame(minutesAgo: 10, layer: 'nexrad-n0q-900913-m10m'),
  _RadarFrame(minutesAgo: 5, layer: 'nexrad-n0q-900913-m05m'),
  _RadarFrame(minutesAgo: 0, layer: 'nexrad-n0q-900913'),
];

class _RadarScreenState extends State<RadarScreen> {
  int _index = _frames.length - 1;
  bool _playing = false;
  Timer? _playTimer;

  @override
  void dispose() {
    _playTimer?.cancel();
    super.dispose();
  }

  void _togglePlay() {
    setState(() => _playing = !_playing);
    _playTimer?.cancel();
    if (_playing) {
      _playTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (!mounted) return;
        setState(() => _index = (_index + 1) % _frames.length);
      });
    }
  }

  String _frameLabel(_RadarFrame frame) =>
      frame.minutesAgo == 0 ? 'Now' : '${frame.minutesAgo} min ago';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Radar — ${widget.place.name}')),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                FlutterMap(
                  options: MapOptions(
                    initialCenter:
                        LatLng(widget.place.latitude, widget.place.longitude),
                    initialZoom: 7,
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'dev.andym.skycast',
                    ),
                    // Stack all frames but only show the active one, so
                    // scrubbing/playing doesn't flash while tiles load.
                    for (final (i, frame) in _frames.indexed)
                      Opacity(
                        opacity: i == _index ? 0.7 : 0.0,
                        child: TileLayer(
                          urlTemplate: frame.urlTemplate,
                          userAgentPackageName: 'dev.andym.skycast',
                        ),
                      ),
                    const SimpleAttributionWidget(
                      source: Text('OpenStreetMap · NEXRAD/IEM'),
                    ),
                  ],
                ),
                Positioned(
                  top: 8,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        _frameLabel(_frames[_index]),
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  ),
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
                    icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                    onPressed: _togglePlay,
                    tooltip: _playing ? 'Pause' : 'Play',
                  ),
                  Expanded(
                    child: Slider(
                      value: _index.toDouble(),
                      min: 0,
                      max: (_frames.length - 1).toDouble(),
                      divisions: _frames.length - 1,
                      onChanged: (v) => setState(() => _index = v.round()),
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
