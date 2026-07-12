#!/bin/bash

	
# cities and towns
echo "Simplifying cities and towns..."
psql -d gis -c "CREATE OR REPLACE VIEW lowzoom_cities AS SELECT way,admin_level,get_localized_placename(name,\"name:de\",int_name,\"name:en\",true) as name,capital,place,population::integer FROM planet_osm_point WHERE place IN ('city','town') AND (population IS NULL OR population SIMILAR TO '[[:digit:]]+') AND (population IS NULL OR population::integer > 5000);"
psql -d lowzoom -c "CREATE TABLE cities (way geometry(Point,3857), admin_level text, name text, capital text, place text, population integer);"
psql -d lowzoom -c "INSERT INTO cities SELECT * FROM dblink('dbname=gis','SELECT * FROM lowzoom_cities') AS t(way geometry(Point,3857), admin_level text, name text, capital text, place text, population integer);"
psql -d lowzoom -c "CREATE INDEX cities_way_idx ON cities USING GIST (way);"

echo "Re-Setting permissions for tirex"
psql -d lowzoom -c 'GRANT SELECT ON ALL TABLES IN SCHEMA public TO tirex;'
