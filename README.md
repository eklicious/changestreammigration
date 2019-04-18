# Changestream Migration
an alternative for migrating data off of one database to another when Live Migration is not a viable option, e.g. Object Rocket restricted access to a given cluster. For sharded clusters, Live Migration requires access to oplogs, the ability to make changes to the config server, and access to the primary nodes of each shard. If you aren't able to do those things, then this tool may be suitable as an alternative.

## How do these scripts work?
At a high level, the scripts operate in 2 parts. 

The first part, init_migration.sh, initiates the migration process for a single collection. It's expected that all writes to the source database collection are turned off. The initial migration script can be run across 1 to many collections in parallel and is up to you to explicitly run the collections that you care about. An example of how to execute the command is:

./init_migration.sh mongodb+srv://<username>:<password>@<srv_src_host>/<db_name>?retryWrites=true mongodb+srv://<username>:<password>@<srv_target_host>/<db_name>?retryWrites=true <db_name> <coll_name>

The steps it performs are:
- Setting up a changestream process against the source collection waiting for a delete event from the next step
- Insert a dummy document with _id=-1 into the source collection and delete it to capture the resume token from the first step above (make sure the client is aware of this insert/delete since it goes against the source database itself)
- Run a mongodump of the source collection
- Turn on another changestream process that captures all changes in the source collection and pushes the changes to the target database in a collection called "cdc". You need to make sure there is no collection called "cdc" else this will create a conflict. The reason why we temporarily store all the changes in a remote collection is to allow us to restore the target collection first and to make sure we don't lose any operations during the restoration process due to resume tokens getting flushed out. During this changestream process, the resume token is stored in a local file called <db_name>.<coll_name>.token. So if the process for whatever reason dies, we could manually call the cdc process again to resume where it last left off.
- At this point, you can choose to restart your app servers.

The second part is run when you are ready to restore the database after the dump and then consume all the cdc payload data from the temporary cdc collection and replay them against the restored database collection to keep the target collection in sync with the source collection. You will have to eventually flip your application servers over to the new target database after the sync process is caught up. An example of how to execute the command is:

./sync_migration.sh mongodb+srv://<username>:<password>@<srv_target_host>/<db_name>?retryWrites=true <db_name> <coll_name>

The steps it performs are:
- Run mongorestore for the specific collection
- Run change data replay (cdr) for the given collection. Every time a cdc payload is processed, the document is marked with a status of done to keep track so it will never get processed again. If the process dies, you can manually restart this cdr process and it should pick up from where it last left off. No resume tokens are required since the status is tracked directly in the cdc collection.
- When the data is synced as closely as possible, once again, you can turn the app server off, switch it to the target db, and restart the app server.

There is a single python script that does all the core functionality and is called from the shell scripts above.

## Requirements
- Python3
- Mongodb tools, e.g. mongodump/restore
- Appropriate user login credentials with necessary permissions, e.g. write to any database/collection
