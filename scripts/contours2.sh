#!/bin/bash

cd /mnt/
# Je nach Umfang der Höhendaten wird viel Speicher benötigt, ggfs swap size erhöhen. 
# Für Europa reichen 16Gb RAM und etwa 20Gb Swap
# import contours data into db
createdb contours2 -O tirex
psql -d contours2 -c 'CREATE EXTENSION postgis;'
psql -d contours2 -c 'GRANT SELECT ON ALL TABLES IN SCHEMA public TO tirex;'
osm2pgsql --slim --drop --flat-nodes=/mnt/1tb/tablespace/con-nodes.dat -d contours2 --cache 5000 --style /home/otm/db/contours.style *.pbf
psql -d contours2 -c 'GRANT SELECT ON ALL TABLES IN SCHEMA public TO tirex;'
