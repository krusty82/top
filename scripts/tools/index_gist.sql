-- Index on islands to render them at low zoom levels
CREATE INDEX planet_osm_polygon_islands_way_idx
ON planet_osm_polygon
USING GIST (way)
WHERE place IN ('island', 'islet');

CREATE INDEX planet_osm_point_islands_way_idx
ON planet_osm_point
USING GIST (way)
WHERE place IN ('island', 'islet');

CREATE INDEX planet_osm_point_place_sea_idx
ON planet_osm_point (place)
WHERE place = 'sea';

CREATE INDEX planet_osm_point_peak_volcano_idx
ON planet_osm_point ("natural")
WHERE "natural" IN ('peak','volcano');
