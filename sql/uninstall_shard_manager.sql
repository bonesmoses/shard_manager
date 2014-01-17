/*
 * Author: sthomas@optionshouse.com
 * Created at: Thu Jan 16 14:59:03 -0600 2014
 *
 */

\echo Use "DROP EXTENSION shard_manager;" to load this file. \quit

SET client_min_messages = warning;
SET LOCAL search_path TO @extschema@;

DROP TABLE shard_map CASCADE;
DROP TABLE shard_table CASCADE;

DROP FUNCTION add_shard_admin(VARCHAR) CASCADE;
DROP FUNCTION create_next_shard(VARCHAR, VARCHAR) CASCADE;
DROP FUNCTION drop_shard_admin(VARCHAR) CASCADE;
DROP FUNCTION init_shard_tables(VARCHAR, INT) CASCADE;
DROP FUNCTION next_unique_id(VARCHAR, INT) CASCADE;
DROP FUNCTION register_base_table(VARCHAR, VARCHAR, VARCHAR) CASCADE;
DROP FUNCTION unregister_base_table(VARCHAR, VARCHAR) CASCADE;
DROP FUNCTION update_audit_stamps() CASCADE;
