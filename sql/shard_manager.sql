/**
 * Author: sthomas@optionshouse.com
 * Created at: Thu Jan 16 14:59:03 -0600 2014
 *
 * Basic shard API:
 *  - Each shard gets its own ID generator.
 *  - Optimized shard 'nextval' function.
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
 *  - create_next_shard
 *  - create_id_function
 *  - init_shard_tables
 *  - register_base_table
 *  - set_shard_config
 *  - unregister_base_table
 *
 * Table select permission includes:
 *
 *  - shard_config
 *  - shard_table
 *  - shard_map
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
  GRANT USAGE
     ON SCHEMA @extschema@
     TO ' || quote_ident(db_role);

  EXECUTE '
  GRANT EXECUTE
     ON FUNCTION @extschema@.create_next_shard(VARCHAR, VARCHAR)
     TO ' || quote_ident(db_role);

  EXECUTE '
  GRANT EXECUTE
     ON FUNCTION @extschema@.create_id_function()
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
     ON FUNCTION @extschema@.set_shard_config(VARCHAR, VARCHAR)
     TO ' || quote_ident(db_role);

  EXECUTE '
  GRANT EXECUTE
     ON FUNCTION @extschema@.unregister_base_table(VARCHAR, VARCHAR)
     TO ' || quote_ident(db_role);

  EXECUTE '
  GRANT SELECT
     ON TABLE @extschema@.shard_config
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
 * Create the next_unique_id Function Based on shard_manager Settings
 *
 * After being created, the shard_manager extension needs a function to
 * generate unique IDs. There are three settings in shard_config that
 * control how this works:
 *
 *   - epoch : The date (and optional time) when IDs begin. This is 
 *       converted to the number of milliseconds since 1970 so we can safely
 *       subtract it from the current time as represented in milliseconds.
 *       This is how we know each ID is unique per ms.
 *   - shard_count : The number of shards shard_manager is currently
 *       configured to generate IDs for.
 *   - ids_per_ms : The number of IDs that may be generated per millisecond,
 *       per shard.
 *
 * This function should be called any time adjustments are made to any of
 * the above settings.
 */
CREATE OR REPLACE FUNCTION create_id_function()
RETURNS TEXT AS $$
DECLARE

  epoch       TIMESTAMP WITHOUT TIME ZONE;
  shards      INT;
  ids         INT;
  epoch_ms    BIGINT;
  shard_bits  INT;
  id_bits     INT;
  used_bits   INT;
  date_bits   INT;
  date_end    TIMESTAMP WITHOUT TIME ZONE;

BEGIN

  -- Fetch settings from the config table. We only use the three that
  -- actually control ID generation: epoch, shard_count, and ids_per_ms.
  
  epoch = @extschema@.get_shard_config('epoch');
  shards = @extschema@.get_shard_config('shard_count');
  ids = @extschema@.get_shard_config('ids_per_ms');

  -- Perform a few calculations, and make sure nobody tried to override 
  -- safeguards on shard count or the number of IDs per ms.

  epoch_ms = floor(extract(EPOCH FROM epoch) * 1000);
  shard_bits = floor(log(shards) / log(2));
  id_bits = floor(log(ids) / log(2));
  used_bits = shard_bits + id_bits;
  date_bits = 64 - used_bits;
  date_end = epoch + (floor(2^date_bits / 3600000) || ' h')::INTERVAL;

  -- Create the next_unique_id function. At this point, we have calculated
  -- all of our bit-shifts, so we can declare the function as SQL with no
  -- excess calculations or polls into the configuration table. This should
  -- make it extremely fast.

  EXECUTE $NEXTVAL$
    CREATE OR REPLACE FUNCTION @extschema@.next_unique_id(
      schema_name VARCHAR,
      shard_id INT
    )
    RETURNS BIGINT AS $UNIQUE$
      SELECT (
               (floor(extract(EPOCH FROM clock_timestamp()) * 1000)::BIGINT -
                $NEXTVAL$ || epoch_ms || $NEXTVAL$
               ) << $NEXTVAL$ || used_bits || $NEXTVAL$ |
               ($2 << $NEXTVAL$ || shard_bits || $NEXTVAL$) |
               (nextval($1 || $2 || '.table_id_seq') % 
               $NEXTVAL$ || id_bits || $NEXTVAL$)
             )::BIGINT;
    $UNIQUE$ LANGUAGE SQL SECURITY DEFINER;
  $NEXTVAL$;

  -- Tell the caller about our adjustments, and when the shard manager will
  -- cease returning unique shard IDs.

  RETURN 'Assuming ' || 2^id_bits || ' IDs per ms on ' ||
    2^shard_bits || E' shards, Shard Manager\nwill produce ' ||
    'unique values until ' || to_char(date_end, 'YYYY-MM-DD HH:MI:SS');

END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


/**
 * Create the Next Logical Shard for a Named Schema
 *
 * Given a schema name and server name, this function will create and
 * register a shard mapping in shard_map. In addition, a schema "container"
 * will be created named after the current highest shard number. This
 * container will only contain a single sequence, used as a global
 * increment counter used to generate non-colliding serial between shards.
 *
 * Schemas can have up to shard_config.shard_count shards each. Every shard
 * is named after the source schema with a number appended. The number is
 * always sequential following the last existing shard, as to maximize the
 * number of shards created under a bitmask.
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
  next_shard   INT;
  shard_count  INT;
BEGIN

  -- Obtain the value for shard count so we can impose a shard maximum.

  SELECT INTO shard_count setting::INT
    FROM @extschema@.shard_config
   WHERE config_name = 'shard_count';

  -- Get the currently "top" shard. Due to bit packing, we never want to
  -- skip IDs. If a schema has no shards yet, this is the first shard.
  -- Also, no schema can have more than shard_count shards thanks to our
  -- bitmask.

  SELECT INTO next_shard shard_id + 1
    FROM @extschema@.shard_map
   WHERE source_schema = schema_name
   ORDER BY created_dt
   LIMIT 1;

  IF NOT FOUND THEN
    next_shard = 1;
  END IF;

  IF next_shard > shard_count - 1 THEN
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
 *  - create_next_shard
 *  - create_id_function
 *  - init_shard_tables
 *  - register_base_table
 *  - set_shard_config
 *  - unregister_base_table
 *
 * Table select permission removed:
 *
 *  - shard_config
 *  - shard_table
 *  - shard_map
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
      ON FUNCTION @extschema@.create_id_function()
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
      ON FUNCTION @extschema@.set_shard_config(VARCHAR, VARCHAR)
    FROM ' || quote_ident(db_role);

  EXECUTE '
  REVOKE EXECUTE
      ON FUNCTION @extschema@.unregister_base_table(VARCHAR, VARCHAR)
    FROM ' || quote_ident(db_role);

  EXECUTE '
  REVOKE ALL
      ON TABLE @extschema@.shard_config
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
 * Retrieve a Configuration Setting from shard_config.
 *
 * @param config_key  Name of the configuration setting to retrieve.
 *
 * @return TEXT  Value for the requested configuration setting.
 */
CREATE OR REPLACE FUNCTION get_shard_config(
  config_key  VARCHAR
)
RETURNS TEXT AS
$$
BEGIN
  RETURN (SELECT setting
    FROM @extschema@.shard_config
   WHERE config_name = config_key);
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
     AND shard_id = shard_number
     FOR UPDATE;

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
      'ALTER ' || col_name || ' TYPE BIGINT, ' ||
      'ALTER ' || col_name || ' SET DEFAULT @extschema@.next_unique_id(' ||
      quote_literal(schema_source) || ',' || shard_number || ')';

  END LOOP;

  -- At the end, update shard_map to denote that this shard has been
  -- initialized. If shards are initialized, we have to block certain
  -- actions.
  
  UPDATE @extschema@.shard_map
     SET initialized = True
   WHERE source_schema = schema_source
     AND shard_id = shard_number;

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
 *   - Epoch is defined as milliseconds from UNIX epoch in shard_config.
 *   - clock_timestamp gets the current epoch in milliseconds.
 *   - The difference between these two become the first bits of our ID.
 *   - Shard ID is bit-shifted by log2(ids_per_ms) from shard_config.
 *   - A shard-specific sequence ID is retrieved.
 *   - All three numbers are ORd together to obtain a shard dependent value.
 *
 * Depending on the bit distribution between epoch, shard_count, and
 * ids_per_ms, we can potentially generate unique IDs for hundreds of years.
 *
 * NOTE: This is a stub function, to keep permissions organized. The function
 *       itself is defined by create_id_function.
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
  SELECT NULL::BIGINT;
$$ LANGUAGE SQL SECURITY DEFINER;


/**
 * Set a Configuration Setting from shard_config.
 *
 * This function doesn't just set values. It also acts as an API for
 * checking setting validity. These settings are specifically adjusted:
 *
 *  - epoch : Must be a valid date + optional time.
 *  - ids_per_ms : Will be rounded to the next lowest power of two.
 *      If an even power of two is set, nothing is changed.
 *  - shard_count : Will be rounded to the next lowest power of two.
 *      If an even power of two is set, nothing is changed.
 *
 * All settings will be folded to lower case for consistency.
 *
 * @param config_key  Name of the configuration setting to retrieve.
 * @param config_val  full value to use for the specified setting.
 *
 * @return TEXT  Value for the created/modified configuration setting.
 */
CREATE OR REPLACE FUNCTION set_shard_config(
  config_key  VARCHAR,
  config_val  VARCHAR
)
RETURNS TEXT AS
$$
DECLARE
  bit_adj   INT;
  new_val   VARCHAR := config_val;
  low_key   VARCHAR := lower(config_key);

  info_msg  VARCHAR;
BEGIN
  -- If this is a new setting we don't control, just set it and ignore it.
  -- The admin may be storing personal notes. Any settings required by the
  -- extension should already exist by this point.

  PERFORM 1 FROM @extschema@.shard_config WHERE config_name = low_key;
  
  IF NOT FOUND THEN
    INSERT INTO @extschema@.shard_config (config_name, setting)
    VALUES (low_key, new_val);

    RETURN new_val;
  END IF;

  -- This check is critical to shard_manager. Never, ever allow any changes
  -- to shard-related settings if any shards have been initialized.

  IF low_key IN ('epoch', 'ids_per_ms', 'shard_count') THEN
    PERFORM 1
       FROM @extschema@.shard_map
      WHERE initialized;

    IF FOUND THEN
      RAISE EXCEPTION 'Can not change % setting with active shards.', low_key;
    END IF;
  END IF;

  -- Apply our filter to any setting that we recognize.

  IF low_key = 'epoch' THEN
    BEGIN
      SELECT config_val::TIMESTAMP WITHOUT TIME ZONE;
    EXCEPTION
      WHEN OTHERS THEN
        RAISE EXCEPTION '% is not a valid date!', config_val;
        RETURN NULL;
    END;
  ELSIF low_key IN ('ids_per_ms', 'shard_count') THEN
    BEGIN
      bit_adj = floor(log(config_val::INT) / log(2));
      new_val = 2^bit_adj;
    EXCEPTION
      WHEN OTHERS THEN
        RAISE EXCEPTION '% must be a number!', config_val;
        RETURN NULL;
    END;
  END IF;

  -- With the data filtered, it's now safe to modify the config table.

  UPDATE @extschema@.shard_config
     SET setting = new_val,
         is_default = False
   WHERE config_name = low_key;

  -- If the setting is recognized at all, execute create_id_function so 
  -- IDs fit the new bit shift-values and epoch.

  IF low_key IN ('epoch', 'ids_per_ms', 'shard_count') THEN
    SELECT INTO info_msg @extschema@.create_id_function();
    RAISE WARNING '%', info_msg;
  END IF;

  -- Finally, return the value of the setting, indicating it was accepted.

  RETURN new_val;

END;
$$ LANGUAGE PLPGSQL SECURITY DEFINER;


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
    NEW.created_dt = now();
  ELSE
    NEW.created_dt = OLD.created_dt;
  END IF;

  NEW.modified_dt = now();

  RETURN NEW;

END;
$$ LANGUAGE plpgsql;

--------------------------------------------------------------------------------
-- CREATE TABLES
--------------------------------------------------------------------------------

CREATE TABLE shard_config
(
  config_id      SERIAL     NOT NULL PRIMARY KEY,
  config_name    VARCHAR    UNIQUE NOT NULL,
  setting        VARCHAR    NOT NULL,
  is_default     BOOLEAN    NOT NULL DEFAULT False,
  created_dt     TIMESTAMP  NOT NULL DEFAULT now(),
  modified_dt    TIMESTAMP  NOT NULL DEFAULT now()
);

SELECT pg_catalog.pg_extension_config_dump('shard_config',
  'WHERE NOT is_default');

CREATE TRIGGER t_shard_config_timestamp_b_iu
BEFORE INSERT OR UPDATE ON shard_config
   FOR EACH ROW EXECUTE PROCEDURE update_audit_stamps();

CREATE TABLE shard_map
(
  map_id        SERIAL     NOT NULL PRIMARY KEY,
  shard_id      INT        NOT NULL,
  source_schema VARCHAR    NOT NULL,
  shard_schema  VARCHAR    NOT NULL,
  server_name   VARCHAR    NOT NULL,
  initialized   BOOLEAN    NOT NULL DEFAULT False,
  created_dt    TIMESTAMP  NOT NULL DEFAULT now(),
  modified_dt   TIMESTAMP  NOT NULL DEFAULT now(),
  UNIQUE (shard_id, source_schema)
);

SELECT pg_catalog.pg_extension_config_dump('shard_map',
  'WHERE NOT is_default');

CREATE TRIGGER t_shard_map_timestamp_b_iu
BEFORE INSERT OR UPDATE ON shard_map
   FOR EACH ROW EXECUTE PROCEDURE update_audit_stamps();

CREATE TABLE shard_table
(
  table_id       SERIAL     NOT NULL PRIMARY KEY,
  schema_name    VARCHAR    NOT NULL,
  table_name     VARCHAR    NOT NULL,
  id_column      VARCHAR    NOT NULL,
  created_dt     TIMESTAMP  NOT NULL DEFAULT now(),
  modified_dt    TIMESTAMP  NOT NULL DEFAULT now()
);

SELECT pg_catalog.pg_extension_config_dump('shard_table',
  'WHERE NOT is_default');

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
    ON FUNCTION create_id_function()
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
    ON FUNCTION set_shard_config(VARCHAR, VARCHAR)
  FROM PUBLIC;

REVOKE EXECUTE
    ON FUNCTION unregister_base_table(VARCHAR, VARCHAR)
  FROM PUBLIC;

REVOKE EXECUTE
    ON FUNCTION update_audit_stamps()
  FROM PUBLIC;

--------------------------------------------------------------------------------
-- CONFIGURE EXTENSION
--------------------------------------------------------------------------------

INSERT INTO shard_config (config_name, setting, is_default) VALUES
  ('epoch', CURRENT_DATE, True),
  ('shard_count', 2048, True),
  ('ids_per_ms', 2048, True);

SELECT create_id_function();

