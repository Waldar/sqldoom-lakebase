CREATE MATERIALIZED VIEW doom.linedef_geom AS
 SELECT ld.map_id,
    ld.id AS linedef_id,
    v1.x AS x1,
    v1.y AS y1,
    v2.x AS x2,
    v2.y AS y2,
    ld.flags,
    ld.special,
    ld.right_sd_id,
    ld.left_sd_id,
    rs.sector_id AS fsec,
    ls.sector_id AS bsec
   FROM ((((linedefs ld
     JOIN vertexes v1 ON (((v1.map_id = ld.map_id) AND (v1.id = ld.v1_id))))
     JOIN vertexes v2 ON (((v2.map_id = ld.map_id) AND (v2.id = ld.v2_id))))
     LEFT JOIN sidedefs rs ON (((rs.map_id = ld.map_id) AND (rs.id = ld.right_sd_id))))
     LEFT JOIN sidedefs ls ON (((ls.map_id = ld.map_id) AND (ls.id = ld.left_sd_id))))
WITH DATA;
GRANT SELECT ON TABLE doom.linedef_geom TO databricks_gateway;
GRANT SELECT ON TABLE doom.linedef_geom TO databricks_reader_16406;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE doom.linedef_geom TO databricks_superuser;
