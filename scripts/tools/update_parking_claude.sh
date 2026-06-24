#!/bin/bash
#
# update_parking.sh: Try to find parking places useful for hiking. These places may
# be mapped with hiking=yes, but most are not. Such places are not located in "urban" areas
# (not near landuse=industrial, residential...) and are marked as hiking=_otm_yes in our
# database.
#
# PERFORMANCE-OPTIMIERTE VERSION
#
# Wesentliche Änderungen gegenüber dem Original:
#   1. ST_EXPAND(...) + ST_INTERSECTS  ->  ST_DWithin(...)
#      ST_DWithin kann den GiST-Index direkt für Abstandsabfragen nutzen,
#      während ST_EXPAND eine neue Bounding-Box-Geometrie erzeugt, auf die
#      der Index schlechter angewendet werden kann.
#   2. "Störflächen" (urbane Hindernisse) werden EINMAL in eine dauerhafte,
#      räumlich indexierte Tabelle materialisiert (urban_obstacles, per
#      TRUNCATE + INSERT bei jedem Lauf neu befüllt), statt bei jeder
#      Parkplatz-Zeile erneut über ganz planet_osm_polygon gefiltert zu
#      werden. Das korrelierte Subquery im Original muss pro Parkplatz die
#      komplette Filterbedingung (landuse IN (...) OR amenity IN (...) OR ...)
#      neu auswerten -> O(n*m). Mit der Vorab-Filterung + Index ist es
#      ~O(n log m).
#   3. Partielle B-Tree-Indizes auf amenity='parking' (osm_id), damit der
#      Planner die Update-Kandidaten schnell vorselektieren kann. GiST-
#      Indizes auf way wurden NICHT neu angelegt, da in dieser DB bereits
#      planet_osm_point_way_idx / planet_osm_polygon_way_idx existieren
#      (von osm2pgsql) - ein zweiter, redundanter GiST-Index hätte nur
#      Speicher- und Wartungskosten ohne Planungsvorteil gebracht.
#   4. ANALYZE nach dem Befüllen von urban_obstacles, damit der Planner
#      gute Schätzungen für die NOT EXISTS / ST_DWithin-Queries hat.
#   5. Die beiden parkingisolation.pl-Läufe sowie die beiden abschließenden
#      psql-Imports laufen parallel (Punkte vs. Polygone sind unabhängig).
#
# Wichtig: Wenn sich das Datenbankschema ändert (z.B. neue/umbenannte
# Indizes durch osm2pgsql-Updates), Block "ensure indexes" und die
# Kommentare hier entsprechend prüfen/anpassen.
#

#set -euo pipefail

DBname='gis'
cd tools

###### Prepare #########
#
# Check if hiking is a column of planet_osm_point and planet_osm_polygon, if not, create it
#

add_column_if_missing() {
  local table=$1
  local col=$2
  local type=$3
  local exists
  exists=$(psql -d "$DBname" -t -c "SELECT 1 FROM pg_attribute \
            WHERE attrelid = (SELECT oid FROM pg_class WHERE relname = '${table}') \
            AND attname = '${col}' AND NOT attisdropped;")
  if [ -z "$exists" ]; then
    psql -d "$DBname" -c "ALTER TABLE ${table} ADD COLUMN ${col} ${type};"
  fi
}

add_column_if_missing planet_osm_point   hiking text
add_column_if_missing planet_osm_polygon hiking text
add_column_if_missing planet_osm_point   otm_isolation text
add_column_if_missing planet_osm_polygon otm_isolation text

###### Indizes (idempotent) #########
#
# Diese Indizes beschleunigen sowohl die Vorfilterung der "urbanen Hindernisse"
# als auch die Auswahl der amenity='parking' Zeilen selbst.
# IF NOT EXISTS verhindert Fehler bei wiederholten Läufen.
#

echo -n "update_parking: ensure indexes "
date

psql -d "$DBname" -v ON_ERROR_STOP=1 <<'SQL'
-- Hinweis: GiST-Indizes auf way existieren in dieser DB bereits als
-- planet_osm_point_way_idx / planet_osm_polygon_way_idx (von osm2pgsql
-- angelegt) - daher hier NICHT erneut erstellen, das wäre nur redundanter
-- Speicher- und Wartungsaufwand ohne Planungsvorteil.

-- Partielle Indizes auf amenity='parking', um die Update-Kandidaten sofort
-- einzugrenzen, statt die ganze Tabelle zu scannen.
CREATE INDEX IF NOT EXISTS idx_planet_osm_polygon_parking
    ON planet_osm_polygon (osm_id) WHERE amenity = 'parking';
CREATE INDEX IF NOT EXISTS idx_planet_osm_point_parking
    ON planet_osm_point (osm_id) WHERE amenity = 'parking';
SQL

########## Update ###########
#
# Mark amenity=parking with hiking=_otm_yes if these parking places are not in urban areas
# already as hiking=yes marked places are not touched
#
# Strategie:
#  1. Alle "urbanen Hindernisflächen" einmal in eine dauerhafte, räumlich
#     indexierte Tabelle materialisieren (TRUNCATE + INSERT bei jedem Lauf,
#     Tabelle/Index bleiben über psql-Sessions hinweg erhalten).
#  2. Parkplätze (Polygon + Point) per ST_DWithin gegen diese kleine,
#     indexierte Tabelle prüfen statt gegen ganz planet_osm_polygon.
#

echo -n "update_parking: build urban_obstacles "
date

psql -d "$DBname" -v ON_ERROR_STOP=1 <<'SQL'
-- Dauerhafte Tabelle (kein TEMP), damit sie über mehrere psql-Aufrufe/
-- -Sessions hinweg sichtbar bleibt (TEMP TABLEs sind nur innerhalb der
-- erzeugenden Session sichtbar - jeder "psql -c ..."-Aufruf ist eine eigene
-- Session). Struktur + Index werden nur beim allerersten Lauf angelegt,
-- danach per TRUNCATE + INSERT neu befüllt, damit der GiST-Index nicht bei
-- jedem Lauf komplett neu aufgebaut werden muss.

CREATE TABLE IF NOT EXISTS urban_obstacles (
  osm_id bigint,
  way    geometry
);

CREATE INDEX IF NOT EXISTS idx_urban_obstacles_way_gist
    ON urban_obstacles USING GIST (way);

TRUNCATE urban_obstacles;

INSERT INTO urban_obstacles (osm_id, way)
SELECT osm_id, way
FROM planet_osm_polygon
WHERE landuse IN ('industrial','commercial','retail','residential','military','cemetery','allotments','farmyard')
   OR amenity IN ('hospital','school','university','parking')
   OR leisure IN ('sports_centre','pitch')
   OR aeroway IN ('aerodrome');

ANALYZE urban_obstacles;
SQL

echo -n "update_parking: update planet_osm_polygon "
date

# Hinweis: ein Parkplatz-Polygon, das selbst z.B. landuse=industrial trägt,
# zählt sich über urban_obstacles SELBST als Hindernis (kein osm_id-Ausschluss).
# Das ist gewolltes Verhalten: Parkplätze in Industriegebieten sollen
# ausgeschlossen bleiben, genau wie im Original-Skript mit ST_EXPAND.
psql -d "$DBname" -v ON_ERROR_STOP=1 -c "
  UPDATE planet_osm_polygon AS t1
  SET hiking = '_otm_yes'
  WHERE amenity = 'parking'
    AND (access IS NULL OR access IN ('yes','public'))
    AND (hiking IS NULL OR (hiking != 'no' AND hiking != 'yes'))
    AND NOT EXISTS (
      SELECT 1 FROM urban_obstacles AS t2
      WHERE ST_DWithin(t2.way, t1.way, 50)
    );
"

echo -n "update_parking: update planet_osm_point "
date

psql -d "$DBname" -v ON_ERROR_STOP=1 -c "
  UPDATE planet_osm_point AS t1
  SET hiking = '_otm_yes'
  WHERE amenity = 'parking'
    AND (hiking IS NULL OR (hiking != 'no' AND hiking != 'yes'))
    AND (access IS NULL OR access IN ('yes','public'))
    AND NOT EXISTS (
      SELECT 1 FROM urban_obstacles AS t2
      WHERE ST_DWithin(t2.way, t1.way, 50)
    );
"

# Export these parking places to a csv and calculate their isolation in an external script
#

echo -n "update_parking: exporting polygon "
date

rm -f /tmp/parking_polygon.csv /tmp/parking_point.csv

psql -A -t -F ";" "$DBname" -c "
  SELECT osm_id, ST_X(ST_CENTROID(way)), ST_Y(ST_CENTROID(way)), way_area::INTEGER
  FROM planet_osm_polygon
  WHERE amenity = 'parking' AND hiking IN ('yes','_otm_yes');
" > /tmp/parking_polygon.csv

echo -n "update_parking: exporting point "
date

psql -A -t -F ";" "$DBname" -c "
  SELECT osm_id, ST_X(way), ST_Y(way), osm_id
  FROM planet_osm_point
  WHERE amenity = 'parking' AND hiking IN ('yes','_otm_yes');
" > /tmp/parking_point.csv

rm -f tmp/parking_point.sql tmp/parking_polygon.sql

# Import the calculated isolations
#
# Die beiden Perl-Aufrufe sind voneinander unabhängig (Punkte vs. Polygone)
# und können daher parallel laufen, statt sequentiell.
#

echo -n "update_parking: isolations of points & polygons (parallel) "
date

./parkingisolation.pl planet_osm_point   /tmp/parking_point.csv   5000 > /tmp/parking_point.sql &
PID_POINT=$!
./parkingisolation.pl planet_osm_polygon /tmp/parking_polygon.csv 5000 > /tmp/parking_polygon.sql &
PID_POLY=$!

wait "$PID_POINT"
wait "$PID_POLY"

echo -n "update_parking: updating DB "
date

# Beide Updates betreffen unterschiedliche Tabellen und können daher ebenfalls
# parallel gegen die DB gefahren werden.
psql "$DBname" < /tmp/parking_point.sql   >/dev/null 2>>/dev/null &
PID_DB_POINT=$!
psql "$DBname" < /tmp/parking_polygon.sql >/dev/null 2>>/dev/null &
PID_DB_POLY=$!

wait "$PID_DB_POINT"
wait "$PID_DB_POLY"

# cleaning
#

rm -f /tmp/parking_point.sql /tmp/parking_polygon.sql
rm -f /tmp/hiking_polygon.csv /tmp/hiking_point.csv

# finish
#

echo -n "update_parking: finish "
date
