#!/bin/bash



# natural area labels
echo "Create lines for labels of natural areas..."
psql -d gis -c "DROP VIEW IF EXISTS lowzoom_natural_areas;"
psql -d gis -c "CREATE OR REPLACE VIEW lowzoom_natural_areas AS SELECT natural_arealabel(osm_id,way) as way,name,areatype,way_area,(hierarchicregions).nextregionsize AS nextregionsize,(hierarchicregions).subregionsize AS subregionsize FROM (SELECT osm_id,way,get_localized_placename(name,\"name:de\",int_name,\"name:en\",true) as name,(CASE WHEN \"natural\" IS NOT NULL THEN \"natural\" ELSE \"region:type\" END) AS areatype, way_area, OTM_Next_Natural_Area_Size(osm_id,way_area,way) AS hierarchicregions FROM planet_osm_polygon WHERE (\"region:type\" IN ('natural_area','mountain_area','mountain_range','basin') OR \"natural\" IN ('massif', 'mountain_range','basin','valley','couloir','ridge','arete','gorge','gully','canyon')) AND name IS NOT NULL) AS natural_areas;"
psql -d lowzoom -c "INSERT INTO naturalarealabels SELECT * FROM dblink('dbname=gis','SELECT * FROM lowzoom_natural_areas') AS t(way geometry(LineString,3857), name text, areatype text, way_area real,nextregionsize real,subregionsize real);"
psql -d lowzoom -c "CREATE INDEX IF NOT EXISTS naturalarealabels_way_idx ON naturalarealabels USING GIST (way);"

echo "Re-Setting permissions for tirex"
psql -d lowzoom -c 'GRANT SELECT ON ALL TABLES IN SCHEMA public TO tirex;'
