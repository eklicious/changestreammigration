# Changestream Migration
An alternative for migrating data off of one database collection to another when Live Migration is not a viable option, e.g. Object Rocket restricted access to a given cluster. For sharded clusters, Live Migration requires access to oplogs, the ability to make changes to the config server, and access to the primary nodes of each shard. If you aren't able to do those things, then this tool may be suitable.

# Known Limitations
- The scripts can only be run in a single threaded fashion per collection. Running them in parallel will cause issues with the clusterTime sequence numbers (required for MDB v3.6) that are created. 
- There are a few collections that may have been upgraded from 3.4 to 3.6 that generate the following error "pymongo.errors.OperationFailure: Collection <db_name>.<coll> UUID differs from UUID on change stream operations". Which seems related to https://jira.mongodb.org/browse/SERVER-36154. Either the suggested fixes in the jira ticket need to be run or the problematic collections need to be manually dumped and restored without changestreams for syncing.
- The shard load balancer for the source sharded cluster needs to be turned off.
- Any bad Mongoose indexes created that have "safe":null in the index metadata needs to be dropped and recreated in order for mongorestore build index to work.
- The scripts will not shard target collections and is a manual process after restoration is complete.

## How do these scripts work?
At a high level, the scripts operate in 2 parts. 

The first part, init_migration.sh, initiates the migration process for a single collection. The initial migration script can be run across 1 to many collections in parallel and is up to you to explicitly run the collections that you care about. The application servers DO NOT need to be shut down. An example of how to execute the command is (notice the use of both srv and non-srv uri's):

./init_migration.sh mongodb://<username>:<password>@<host1>:<port1>,<host2>:<port2>,<host3>:<port3>/<db_name>?ssl=true mongodb+srv://<username>:<password>@<srv_src_host>/<db_name>?retryWrites=true <db_name> <coll_name>

The steps it performs are:
- Setting up a changestream process against the source collection waiting for an update event from the next step
- Update the first document in the source collection with {"$set":{"_tempfield_": 1}} dummy document and then immediately run {"$unset":{"_tempfield_": 1}} to remove this field to trigger a changestream event so we can capture the resume token. Make sure the client is aware of this update being done against the source database itself.
- Run a mongodump of the source collection
- Turn on another changestream process that captures all changes in the source collection since the captured resume token and pushes the changes to the target database in a collection called "_cdc". You need to make sure there is no collection called "_cdc" else this will create a conflict. The reason why we temporarily store all the changes in a remote collection is to allow us to restore the target collection first and to make sure we don't lose any operations during the restoration process due to resume tokens getting flushed out. During this changestream process, the resume token is stored in a local file called <db_name>.<coll_name>.token. So if the process for whatever reason dies, we could manually call the CDC process again to resume where it last left off.

The second part is run when you are ready to restore the database after the dump and then consume all the CDC payload data from the temporary _cdc collection and replay them against the restored database collection to keep the target collection in sync with the source collection. You will have to eventually flip your application servers over to the new target database after the sync process is caught up. An example of how to execute the command is:

./sync_migration.sh mongodb+srv://<username>:<password>@<target_srv_host>/<db_name>?retryWrites=true <db_name> <coll_name>

The steps it performs are:
- Run mongorestore for the specific collection
- Run change data replay (CDR) for the given collection. Every time a CDC payload is processed, the document is marked with a status of done to keep track so it will never get processed again. If the process dies, you can manually restart this CDR process and it should pick up from where it last left off. No resume tokens are required since the status is tracked directly in the _cdc collection.
- When the data is synced as closely as possible, you can turn the app server off, switch it to the target db, and restart the app server.

There is a single python script, changestream_migration.py, that does all the core functionality excluding mongodump/restore and is called from the shell scripts above.

## Requirements
- Python3
- Mongodb tools, e.g. mongodump/restore
- Appropriate user login credentials with necessary permissions, e.g. write to any database/collection
- IP whitelisting
- Turn off load balancer
- Atlas op log size needs to be higher than the default, e.g. 20gb
- Precreate the _cdc table with an index (TBD)
