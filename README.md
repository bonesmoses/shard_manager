shard_manager Extension
=======================

Shard Manager is an extension designed to bring database sharding to PostgreSQL.

Inspired by Instagram's numerous posts on their sharding algorithm, Shard Manager can potentially generate unique IDs across numerous tables for hundreds of years. In addition, we have included management and deployment functions to simplify shard management.

Installation
============

To use Shard Manager, it must first be installed. Simply execute these commands in the database that needs sharding functionality:

    CREATE SCHEMA shard;
    CREATE EXTENSION shard_manager WITH SCHEMA shard;

The `shard` schema isn't strictly necessary, but we recommend keeping namespaces isolated.

Usage
=====

Shard manager works by injecting itself into an existing schema template when shards are created. Let's make a very basic schema now:

    CREATE SCHEMA comm;

    CREATE TABLE comm.yell (
      id       SERIAL PRIMARY KEY NOT NULL,
      message  TEXT NOT NULL
    );

That was easy! Now, to use Shard Manager, there are three basic steps:

* Registration
* Creation
* Initialization

The registration step records all tables that should be included in a specific template. The schema itself is the template, but Shard Manager won't copy all tables by default. We can register tables like this:

    SELECT shard.register_base_table('comm', 'yell', 'id');

Any table registered in this manner will be copied to new shards.

Next, we have to create a new physical shard. Shard Manager uses schemas as shard containers. It names them by copying the root template schema name, and appends the current shard number, up to the amount of bits reserved for our shard IDs. For us, this means we need to create a shard for the `comm` schema:

    SELECT shard.create_next_shard('comm', 'localhost');

The second parameter is set to `localhost` for now, but it's merely a tracking value. We don't currently make use of foreign tables. The idea here, is that the values in the shard.shard_map table can be used as a physical/logical map for application use.

The next step is to fill our new shard schema. Again, we have a helper function for this:

    SELECT shard.init_shard_tables('comm', 1);

Now if we examine the `comm1` schema, we will find our `yell` table in sharded form. Let's see what happens if we insert into the table:

    INSERT INTO comm1.yell (message) VALUES ('I like cows!');

If we SELECT from the table, we should see something like this:

    -[ RECORD 1 ]------------
    id      | 245816446945281
    message | I like cows!

That ID is huge! But in this case, that's expected. We use all of a 64-bit integer to store the ID, so the value should be extremely high. But did you also notice that the shard system automatically overwrote the DEFAULT imposed by our use of a SERIAL type? It also makes sure the column is a BIGINT type so it can store the whole shard ID without numeric overflow.

This is all handled automatically to encourage shard use.

Configuration
=============


Tables
======


Build Instructions
==================

To build it, just do this:

    cd shard_manager
    make
    sudo make install

If you encounter an error such as:

    make: pg_config: Command not found

Be sure that you have `pg_config` installed and in your path. If you used a
package management system such as RPM to install PostgreSQL, be sure that the
`-devel` package is also installed. If necessary tell the build process where
to find it:

    export PG_CONFIG=/path/to/pg_config
    make
    sudo make install

And finally, if all that fails (and if you're on PostgreSQL 8.1 or lower, it
likely will), copy the entire distribution directory to the `contrib/`
subdirectory of the PostgreSQL source tree and try it there without
`pg_config`:

    export NO_PGXS=1
    make
    make install


Dependencies
============

The `shard_manager` extension has no dependencies other than PostgreSQL.


Copyright and License
=====================

Copyright (c) 2014 Peak6

