import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/forecast.dart';
import '../services/nowcast.dart';

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
  final _mapController = MapController();
  int _index = _frames.length - 1;
  bool _playing = false;
  Timer? _playTimer;

  final _nowcastService = NowcastService();
  NowcastResult? _nowcast;
  bool _computingNowcast = true;
  String? _nowcastError;

  int get _timelineLength => _frames.length + (_nowcast?.frames.length ?? 0);

  @override
  void initState() {
    super.initState();
    _computeNowcast();
  }

  Future<void> _computeNowcast() async {
    setState(() => _computingNowcast = true);
    try {
      final result = await _nowcastService.computeNowcast(
          widget.place.latitude, widget.place.longitude);
      if (!mounted) return;
      setState(() => _nowcast = result);
    } catch (e) {
      // Nowcast is best-effort; observed radar still works without it —
      // but say so instead of failing silently.
      debugPrint('Nowcast failed: $e');
      if (mounted) setState(() => _nowcastError = e.toString());
    } finally {
      if (mounted) setState(() => _computingNowcast = false);
    }
  }

  @override
  void dispose() {
    _playTimer?.cancel();
    _mapController.dispose();
    super.dispose();
  }

  void _zoomBy(double delta) {
    final camera = _mapController.camera;
    _mapController.move(camera.center, camera.zoom + delta);
  }

  void _togglePlay() {
    setState(() => _playing = !_playing);
    _playTimer?.cancel();
    if (_playing) {
      _playTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (!mounted) return;
        setState(() => _index = (_index + 1) % _timelineLength);
      });
    }
  }

  String _labelAt(int index) {
    if (index < _frames.length) {
      final frame = _frames[index];
      return frame.minutesAgo == 0 ? 'Now' : '${frame.minutesAgo} min ago';
    }
    final lead = _nowcast!.frames[index - _frames.length].leadMinutes;
    return '+$lead min (est)';
  }

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
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter:
                        LatLng(widget.place.latitude, widget.place.longitude),
                    initialZoom: 7,
                    minZoom: 4,
                    maxZoom: 12,
                    interactionOptions: const InteractionOptions(
                      flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                    ),
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
                          // IEM stops serving radar tiles past this zoom;
                          // scale them up instead of dropping the layer.
                          maxNativeZoom: 10,
                        ),
                      ),
                    if (_nowcast != null && _index >= _frames.length)
                      Opacity(
                        opacity: 0.7,
                        child: OverlayImageLayer(
                          overlayImages: [
                            OverlayImage(
                              bounds: LatLngBounds(
                                LatLng(_nowcast!.south, _nowcast!.west),
                                LatLng(_nowcast!.north, _nowcast!.east),
                              ),
                              imageProvider: MemoryImage(_nowcast!
                                  .frames[_index - _frames.length].png),
                            ),
                          ],
                        ),
                      ),
                    const SimpleAttributionWidget(
                      source: Text('OpenStreetMap · NEXRAD/IEM'),
                    ),
                  ],
                ),
                Positioned(
                  right: 12,
                  bottom: 24,
                  child: Column(
                    children: [
                      FloatingActionButton.small(
                        heroTag: 'radar-zoom-in',
                        onPressed: () => _zoomBy(1),
                        tooltip: 'Zoom in',
                        child: const Icon(Icons.add),
                      ),
                      const SizedBox(height: 8),
                      FloatingActionButton.small(
                        heroTag: 'radar-zoom-out',
                        onPressed: () => _zoomBy(-1),
                        tooltip: 'Zoom out',
                        child: const Icon(Icons.remove),
                      ),
                    ],
                  ),
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
                        _labelAt(_index),
                        style: TextStyle(
                          color: _index >= _frames.length
                              ? Colors.amberAccent
                              : Colors.white,
                        ),
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
                      max: (_timelineLength - 1).toDouble(),
                      divisions: _timelineLength - 1,
                      onChanged: (v) => setState(() => _index = v.round()),
                    ),
                  ),
                  if (_computingNowcast)
                    const Padding(
                      padding: EdgeInsets.only(right: 12),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else if (_nowcastError != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Tooltip(
                        message: 'Nowcast failed: $_nowcastError',
                        child: IconButton(
                          icon: const Icon(Icons.warning_amber,
                              color: Colors.amber, size: 20),
                          onPressed: _computeNowcast,
                        ),
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
