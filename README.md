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

The second parameter is set to `localhost` for now, but it's merely a tracking value. We don't currently make use of foreign tables. The idea here, is that the values in the `shard.shard_map` table can be used as a physical/logical map for application use.

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

Configuring Shard Manager has been simplified by the introduction of two functions designed to handle setting validation and other internals. To see all settings at once, execute this query to examine the contents of the `shard_config` table.

    SELECT config_name, setting FROM shard.shard_config;

Shard manager should produce several fields it sets by default:

     config_name |  setting   
    -------------+------------
     epoch       | 2014-02-11
     shard_count | 2048
     ids_per_ms  | 2048

In this case, Shard Manager was installed on 2014-02-11, and can handle up to 2048 shards, with 2048 IDs per shard, per millisecond. That's over two million IDs per second, *per shard*. All modifications to these settings must take place before calling `init_shard_tables`. This helps protect any existing ID values from collision due to changed ID generation assumptions.

To change settings, use the `set_shard_config` function as seen here:

    SELECT shard.set_shard_config('shard_count', '1000');

The output is actually important in this case:

    WARNING:  Assuming 2048 IDs per ms on 512 shards, Shard Manager 
    will produce unique values until 2571-08-04 06:00:00
     set_shard_config 
    ------------------
     512

Notice how Shard Manager automatically adjusted the number of shards to the next lowest valid power of two. Since it uses a 64-bit integer internally, it must ensure lossless conversion. The warning is mainly a notice to inform any user that changes watched settings of Shard Manager's current capabilities. Again, we strongly recommend experimenting with various settings *before* creating new shards. Changes can not be made to system settings following shard initialization!


Tables
======

Shard Manager has a few tables that provide information about its operation and configuration. These tables include:

Table Name | Description
--- | ---
shard_config | Contains all settings Shard Manager uses to control shard allocation.
shard_map | Maintains a physical/logical mapping for applications to find shards. Tracks whether shards have been initialized for use.
shard_table | Master resource where all registered shard tables are tracked. Every schema can have its own list of tables.


Security
========

Due to its low-level operation, Shard Manager works best when executed by a database superuser. However, we understand this is undesirable in many cases. Certain Shard Manager capabilities can be assigned to other users by calling `add_shard_admin`. For example:

    CREATE USER shard_user;
    SELECT shard.add_shard_admin('shard_user');

This user can now call any of the shard management functions. These functions should always work, provided the user who created the `shard_manager` extension was a superuser. To revoke access, call the analog function:

    SELECT shard.drop_shard_admin('shard_user');


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

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
