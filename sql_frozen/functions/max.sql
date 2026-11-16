DROP AGGREGATE IF EXISTS doom.max(bytea);
CREATE AGGREGATE doom.max(bytea) (
    SFUNC = bytea_larger,
    STYPE = bytea,
    COMBINEFUNC = bytea_larger
);
