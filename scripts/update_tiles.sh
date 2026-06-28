#!/bin/bash
osm2pgsql-replication \
    update -d gis \
    --max-diff-size 500  --  \
    -G \
    -C 3000 --number-processes 4 \
    --flat-nodes /mnt/1tb/tablespace/flat-nodes/gis-flat-nodes.bin  \
    --style /home/otm/db/opentopomap.style \
    --expire-tiles=11-17 \
    --expire-output=/mnt/dirty_tiles.txt
