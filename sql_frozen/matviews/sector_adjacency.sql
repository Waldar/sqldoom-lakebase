CREATE MATERIALIZED VIEW doom.sector_adjacency AS
 SELECT ld.map_id,
    ld.id AS linedef_id,
    r.sector_id,
    l.sector_id AS other_id
   FROM ((linedefs ld
     JOIN sidedefs r ON (((r.map_id = ld.map_id) AND (r.id = ld.right_sd_id))))
     JOIN sidedefs l ON (((l.map_id = ld.map_id) AND (l.id = ld.left_sd_id))))
UNION ALL
 SELECT ld.map_id,
    ld.id AS linedef_id,
    l.sector_id,
    r.sector_id AS other_id
   FROM ((linedefs ld
     JOIN sidedefs r ON (((r.map_id = ld.map_id) AND (r.id = ld.right_sd_id))))
     JOIN sidedefs l ON (((l.map_id = ld.map_id) AND (l.id = ld.left_sd_id))))
WITH DATA;
GRANT SELECT ON TABLE doom.sector_adjacency TO databricks_gateway;
GRANT SELECT ON TABLE doom.sector_adjacency TO databricks_reader_16406;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE doom.sector_adjacency TO databricks_superuser;
