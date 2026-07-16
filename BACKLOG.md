# Backlog

- [ ] **NWS alert banner.** `api.weather.gov/alerts/active?point=lat,lon` —
  free, keyless, US-only (matches radar scope). Official alerts: Air
  Quality Alert, tornado/severe-thunderstorm/flood warnings, winter
  storms. Needs banner UI with severity coloring + expiry handling.
  Higher value than the AQI card long-term; larger UI surface.

- [x] **Drizzle icon looks like snow.** (fixed 2026-07-16) `Icons.grain`
  replaced: drizzle (51/53/55) → `Icons.umbrella`; freezing drizzle/rain
  (56/57/66/67) → `Icons.severe_cold` as a distinct ice-hazard glyph.
