DROP AGGREGATE IF EXISTS doom.min(bytea);
CREATE AGGREGATE doom.min(bytea) (
    SFUNC = bytea_smaller,
    STYPE = bytea,
    COMBINEFUNC = bytea_smaller
);
