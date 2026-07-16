# Backlog

- [ ] **Drizzle icon looks like snow.** `Icons.grain` (an 8-dot grid) is used
  for WMO codes 51/53/55/56/57 (drizzle + freezing drizzle) in
  `lib/wmo.dart:35`, and reads as snowfall next to `Icons.ac_unit` (real
  snow, line 37). Investigate a clearer glyph — e.g. `Icons.water_drop` with
  reduced emphasis, `Icons.rainy_light` (if available in the bundled
  Material set), or a custom drizzle icon. Freezing drizzle (56/57) may
  deserve a distinct icon from plain drizzle while at it.
