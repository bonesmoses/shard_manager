/*
 * Author: sthomas@optionshouse.com
 * Created at: Thu Jan 16 14:59:03 -0600 2014
 *
 */

\echo Use "CREATE EXTENSION shard_manager;" to load this file. \quit

SET client_min_messages = warning;
SET LOCAL search_path TO @extschema@;

--------------------------------------------------------------------------------
-- CREATE FUNCTIONS
--------------------------------------------------------------------------------

/**
 * Register a user who is allowed to use shard_manager.
 *
 * Because the shard management function uses several stored procedures,
 * granting usage is somewhat cumbersome. This function exists as a shortcut
 * for the user who created the shard_manager extension to hand management
 * to other users. Functions for this include:
 *
 * - create_next_shard
 * - init_shard_tables
 * - register_base_table
 * - unregister_base_table
 *
 * Table select permission includes:
 *
 * - shard_table
 * - shard_map
 *
 * We suggest using a role for "admin" class users to avoid micromanagement.
 *
 * @param user_name  String user or role to delegate as shard admin.
 */
CREATE OR REPLACE FUNCTION add_shard_admin(
  db_role  VARCHAR
)
RETURNS VOID AS
$$
BEGIN

  EXECUTE '
  GRANT EXECUTE
     ON FUNCTION @extschema@.create_next_shard(VARCHAR, VARCHAR)
     TO ' || quote_ident(db_role);

  EXECUTE '
  GRANT EXECUTE
     ON FUNCTION @extschema@.init_shard_tables(VARCHAR, INT)
     TO ' || quote_ident(db_role);

  EXECUTE '
  GRANT EXECUTE
     ON FUNCTION @extschema@.register_base_table(VARCHAR, VARCHAR, VARCHAR)
     TO ' || quote_ident(db_role);

  EXECUTE '
  GRANT EXECUTE
     ON FUNCTION @extschema@.unregister_base_table(VARCHAR, VARCHAR)
     TO ' || quote_ident(db_role);

  EXECUTE '
  GRANT SELECT
     ON TABLE @extschema@.shard_map
     TO ' || quote_ident(db_role);

  EXECUTE '
  GRANT SELECT
     ON TABLE @extschema@.shard_table
     TO ' || quote_ident(db_role);

END;
$$ LANGUAGE PLPGSQL SECURITY DEFINER;


/**
 * Create the Next Logical Shard for a Named Schema
 *
 * Given a schema name and server name, this function will create and
 * register a shard mapping in shard_map. In addition, a schema "container"
 * will be created named after the current highest shard number. This
 * container will only contain a single sequence, used as a global
 * increment counter used to generate non-colliding serial between shards.
 *
 * Schemas can have up to 2048 shards each. Every shard is named after
 * the source schema with a number appended. The number is always sequential
 * following the last existing shard, as to maximize the number of shards
 * created under a 2^11 mask.
 *
 * @param schema_name String name of the schema that is the root for this
 *   shard. For instance, to shard the 'foo' schema into foo1, foo2,
 *   ..., fooN per call.
 * @param server_name String name of the physical server where this shard
 *   resides. In the case of a dual-failover configuration, the cluster
 *   name associated with a VIP should be substituted.
 */
CREATE OR REPLACE FUNCTION create_next_shard(
  schema_name  VARCHAR,
  server_name  VARCHAR
)
RETURNS VOID AS
$$
DECLARE
  next_shard INT;
BEGIN

  -- Get the currently "top" shard. Due to bit packing, we never want to
  -- skip IDs. If a schema has no shards yet, this is the first shard.
  -- Also, no schema can have more than 2048 shards thanks to our bitmask.

  SELECT INTO next_shard shard_id + 1
    FROM @extschema@.shard_map
   WHERE source_schema = schema_name
   ORDER BY created_dt
   LIMIT 1;

  IF NOT FOUND THEN
    next_shard = 1;
  END IF;

  IF next_shard > 2048 THEN
    RAISE EXCEPTION 'Maximum shards reached for % schema', schema_name;
  END IF;

  -- Insert the shard mapping. This table should be globally available
  -- across the custer of DB servers so that the shard configuration is
  -- unique and reliable. For app purposes, this should be cached for
  -- connection pooling purposes.

  INSERT INTO @extschema@.shard_map(
           shard_id, source_schema, shard_schema, server_name
         )
  VALUES (
           next_shard, schema_name, schema_name || next_shard, server_name
         );

  EXECUTE 'CREATE SCHEMA ' || schema_name || next_shard;
  EXECUTE 'CREATE SEQUENCE ' || schema_name || next_shard || '.table_id_seq';

END;
$$ LANGUAGE PLPGSQL SECURITY DEFINER;


/**
 * Remove a user or role who was allowed to use shard_manager.
 *
 * This is the functional analog to add_shard_admin. Calling this function
 * will remove a user or role from the list of those allowed to invoke shard
 * management routines. Functions permissions removed:
 *
 * - create_next_shard
 * - init_shard_tables
 * - register_base_table
 * - unregister_base_table
 *
 * Table select permission removed:
 *
 * - shard_table
 * - shard_map
 *
 * @param db_role  String user or role to remove as shard admin.
 */
CREATE OR REPLACE FUNCTION drop_shard_admin(
  db_role  VARCHAR
)
RETURNS VOID AS
$$
BEGIN

  EXECUTE '
  REVOKE EXECUTE
      ON FUNCTION @extschema@.create_next_shard(VARCHAR, VARCHAR)
    FROM ' || quote_ident(db_role);

  EXECUTE '
  REVOKE EXECUTE
      ON FUNCTION @extschema@.init_shard_tables(VARCHAR, INT)
    FROM ' || quote_ident(db_role);

  EXECUTE '
  REVOKE EXECUTE
      ON FUNCTION @extschema@.register_base_table(VARCHAR, VARCHAR, VARCHAR)
    FROM ' || quote_ident(db_role);

  EXECUTE '
  REVOKE EXECUTE
      ON FUNCTION @extschema@.unregister_base_table(VARCHAR, VARCHAR)
    FROM ' || quote_ident(db_role);

  EXECUTE '
  REVOKE ALL
      ON TABLE @extschema@.shard_map
    FROM ' || quote_ident(db_role);

  EXECUTE '
  REVOKE ALL
      ON TABLE @extschema@.shard_table
    FROM ' || quote_ident(db_role);

END;
$$ LANGUAGE PLPGSQL SECURITY DEFINER;


/**
 * Initialize a Shard by Copying all Registered Tables Over
 *
 * Given a schema and shard number, this function will check shard_table
 * for all registered tables that should exist in the sharded version of
 * the schema. Every table created in this way will have its ID column 
 * set to invoke the next_unique_id function by default. Only tables in
 * shard_table will be created this way. To register a table here, use:
 *
 * SELECT register_base_table('my_schema', 'my_table', 'table_column_id');
 *
 * The 'table_column_id' segment is required, otherwise the unique IDs
 * have no associated column. All tables registered here will have their
 * table definition copied to the shard schema, including all primary keys
 * and indexes.
 *
 * @param schema_source String name of the schema that is the root for this
 *   shard. For instance, to initialize a 'foo' schema shard.
 * @param shard_number Integer value of the shard to initialize by filling
 *   with copied table structures.
 */
CREATE OR REPLACE FUNCTION init_shard_tables(
  schema_source  VARCHAR,
  shard_number   INT
)
RETURNS VOID AS
$$
DECLARE
  shard_name  VARCHAR;
  root_table  VARCHAR;
  col_name    VARCHAR;
  new_table   VARCHAR;
  src_table   VARCHAR;
BEGIN

  -- Get the name of the shard_schema (foo2, foo2, etc) from the shard map.
  -- This ensures no accidental namespace escapes during initialization.

  SELECT INTO shard_name shard_schema
    FROM @extschema@.shard_map
   WHERE source_schema = schema_source
     AND shard_id = shard_number;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Shard % does not exist for schema %!', 
          shard_number, schema_source;
  END IF;

  -- For each table in this schema, we're filling up the named shard. We can
  -- create the table based entirely on the source table definition. After,
  -- make sure to set the DEFAULT to our special-purpose ID generator.

  FOR root_table, col_name IN
      SELECT table_name, id_column
        FROM @extschema@.shard_table
       WHERE schema_name = schema_source
  LOOP
    new_table = shard_name || '.' || quote_ident(root_table);
    src_table = schema_source || '.' || quote_ident(root_table);

    EXECUTE
      'CREATE TABLE ' || new_table ||
      ' (LIKE ' || src_table || ' INCLUDING ALL)';

    EXECUTE
      'ALTER TABLE ' || new_table || ' ' ||
      'ALTER COLUMN ' || col_name || '  SET ' ||
      'DEFAULT @extschema@.next_unique_id(' ||
      quote_literal(schema_source) || ',' || shard_number || ')';
  END LOOP;

END;
$$ LANGUAGE PLPGSQL SECURITY DEFINER;


/**
 * Register a table to the shard_manager system.
 *
 * This function simplifies adding tables to the shard management system.
 * Tables registered here will be tied to their base schema, so that when
 * new shards are created, this table structure is replicated there. This
 * function should only be used for "shardable" tables. That is, any table
 * with a column intended for serial ID use.
 *
 * @param table_schema  String name of the schema for this table.
 * @param table_name  Name of the table to register with shard_manager.
 * @param id_column  Primary key column that should use our globally unique
 *   ID generator. This function will change the default next value for this
 *   column to use the next_unique_id function.
 */
CREATE OR REPLACE FUNCTION register_base_table(
  table_schema  VARCHAR,
  table_name    VARCHAR,
  id_column     VARCHAR
)
RETURNS VOID AS
$$
BEGIN

  INSERT INTO @extschema@.shard_table (schema_name, table_name, id_column)
  VALUES (table_schema, table_name, id_column);

END;
$$ LANGUAGE PLPGSQL SECURITY DEFINER;


/**
 * Returns a Universally Unique 64-bit Integer
 *
 * To ensure IDs generated by this function remain unique across all shards,
 * we apply the following techniques:
 *
 *   - Epoch is defined as the number of milliseconds at 2013-01-01.
 *   - clock_timestamp gets the currently defined epoch in milliseconds.
 *   - The difference between these two is the first 42 bits of our ID.
 *   - The shard ID (max 2048) is bit-shifted by 11 places (2048).
 *   - The schema-specific sequence provides the final 2048 counter.
 *   - All three numbers are ORd together to obtain a shard dependent value.
 *
 * This can generate up to 2048 sequential values per shard, per millisecond,
 * for 138 years.
 *
 * @param schema_name String name of the schema that is the root for this
 *   shard. I.e. for foo1...fooN, use foo.
 * @param shard_number Integer value of the shard. Used both in the bit
 *   mask, and to correctly identify the shard schema sequence.
 */
CREATE OR REPLACE FUNCTION next_unique_id(
  schema_name VARCHAR,
  shard_id INT
)
RETURNS BIGINT AS $$
  SELECT (
           (FLOOR(EXTRACT(EPOCH FROM clock_timestamp()) * 1000)::BIGINT -
            1357020000000::BIGINT -- Epoch (January 1, 2013)
           ) << 22 |
           ($2 << 11) | -- Mod by 2048 shards
           (nextval($1 || $2 || '.table_id_seq') % 2048)
         )::BIGINT;
$$ LANGUAGE SQL SECURITY DEFINER;


/**
 * Remove a table/schema pair from the shard_manager system.
 *
 * This function simplifies removing tables from the shard management system.
 * Tables removed here will no longer have their structure copied to new
 * shards based on this schema.
 *
 * @param table_schema  String name of the schema for this table.
 * @param target_table  String name of the table to remove from shard_manager.
 */
CREATE OR REPLACE FUNCTION unregister_base_table(
  table_schema  VARCHAR,
  target_table  VARCHAR
)
RETURNS VOID AS
$$
BEGIN

  DELETE FROM @extschema@.shard_table
   WHERE schema_name = table_schema
     AND table_name = target_table;

END;
$$ LANGUAGE PLPGSQL SECURITY DEFINER;


/**
* Update created/modified timestamp automatically
*
* This function maintains two metadata columns on any table that uses
* it in a trigger. These columns include:
*
*  - created_dt  : Set to when the row first enters the table.
*  - modified_at : Set to when the row is ever changed in the table.
*
* @return object  NEW 
*/
CREATE OR REPLACE FUNCTION update_audit_stamps()
RETURNS TRIGGER AS
$$
BEGIN

  -- All inserts get a new timestamp to mark their creation. Any updates should
  -- inherit the timestamp of the old version. In either case, a modified
  -- timestamp is applied to track the last time the row was changed.

  IF TG_OP = 'INSERT' THEN
    NEW.created_dt = NOW();
  ELSE
    NEW.created_dt = OLD.created_dt;
  END IF;

  NEW.modified_dt = NOW();

  RETURN NEW;

END;
$$ LANGUAGE plpgsql;

--------------------------------------------------------------------------------
-- CREATE TABLES
--------------------------------------------------------------------------------

-- Basic shard API:
--   * Each shard gets its own ID generator.
--   * Optimized shard 'nextval' function.

CREATE TABLE shard_map
(
  map_id        SERIAL     NOT NULL PRIMARY KEY,
  shard_id      INT        NOT NULL,
  source_schema VARCHAR    NOT NULL,
  shard_schema  VARCHAR    NOT NULL,
  server_name   VARCHAR    NOT NULL,
  created_dt    TIMESTAMP  NOT NULL DEFAULT CURRENT_DATE,
  modified_dt   TIMESTAMP  NOT NULL DEFAULT CURRENT_DATE,
  UNIQUE (shard_id, source_schema)
);

SELECT pg_catalog.pg_extension_config_dump('shard_map', '');

CREATE TRIGGER t_shard_map_timestamp_b_iu
BEFORE INSERT OR UPDATE ON shard_map
   FOR EACH ROW EXECUTE PROCEDURE update_audit_stamps();

CREATE TABLE shard_table
(
  table_id       SERIAL     NOT NULL PRIMARY KEY,
  schema_name    VARCHAR    NOT NULL,
  table_name     VARCHAR    NOT NULL,
  id_column      VARCHAR    NOT NULL,
  created_dt     TIMESTAMP  NOT NULL DEFAULT CURRENT_DATE,
  modified_dt    TIMESTAMP  NOT NULL DEFAULT CURRENT_DATE
);

SELECT pg_catalog.pg_extension_config_dump('shard_table', '');

CREATE TRIGGER t_shard_table_timestamp_b_iu
BEFORE INSERT OR UPDATE ON shard_table
   FOR EACH ROW EXECUTE PROCEDURE update_audit_stamps();

--------------------------------------------------------------------------------
-- ALTER PERMISSIONS
--------------------------------------------------------------------------------

REVOKE EXECUTE
    ON FUNCTION add_shard_admin(VARCHAR)
  FROM PUBLIC;

REVOKE EXECUTE
    ON FUNCTION create_next_shard(VARCHAR, VARCHAR)
  FROM PUBLIC;

REVOKE EXECUTE
    ON FUNCTION drop_shard_admin(VARCHAR)
  FROM PUBLIC;

REVOKE EXECUTE
    ON FUNCTION init_shard_tables(VARCHAR, INT)
  FROM PUBLIC;

REVOKE EXECUTE
    ON FUNCTION next_unique_id(VARCHAR, INT)
  FROM PUBLIC;

REVOKE EXECUTE
    ON FUNCTION register_base_table(VARCHAR, VARCHAR, VARCHAR)
  FROM PUBLIC;

REVOKE EXECUTE
    ON FUNCTION unregister_base_table(VARCHAR, VARCHAR)
  FROM PUBLIC;

REVOKE EXECUTE
    ON FUNCTION update_audit_stamps()
  FROM PUBLIC;
