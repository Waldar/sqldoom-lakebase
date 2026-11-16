CREATE MATERIALIZED VIEW doom.node_path_steps AS
 WITH RECURSIVE walk AS (
         SELECT nc.map_id,
            nc.child_kind,
            nc.child_node_id,
            nc.child_ssector_id,
            1 AS depth,
            ARRAY[nc.node_id] AS nodes,
            ARRAY[(nc.side)::text] AS sides
           FROM (node_children nc
             JOIN ( SELECT nodes.map_id,
                    max(nodes.id) AS root
                   FROM nodes
                  GROUP BY nodes.map_id) r ON (((r.map_id = nc.map_id) AND (r.root = nc.node_id))))
        UNION ALL
         SELECT nc.map_id,
            nc.child_kind,
            nc.child_node_id,
            nc.child_ssector_id,
            (w_1.depth + 1),
            (w_1.nodes || nc.node_id),
            (w_1.sides || (nc.side)::text)
           FROM (walk w_1
             JOIN node_children nc ON (((nc.map_id = w_1.map_id) AND (nc.node_id = w_1.child_node_id))))
          WHERE (w_1.child_kind = 'NODE'::bsp_child)
        )
 SELECT w.map_id,
    w.child_ssector_id AS ssector_id,
    g.d AS depth,
    w.nodes[g.d] AS node_id,
    (w.sides[g.d])::character(1) AS side
   FROM (walk w
     CROSS JOIN LATERAL generate_series(1, w.depth) g(d))
  WHERE (w.child_kind = 'SSECTOR'::bsp_child)
WITH DATA;
GRANT SELECT ON TABLE doom.node_path_steps TO databricks_gateway;
GRANT SELECT ON TABLE doom.node_path_steps TO databricks_reader_16406;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE doom.node_path_steps TO databricks_superuser;
