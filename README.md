# Changestream Migration
An alternative for migrating data off of one database collection to another when Live Migration is not a viable option, e.g. Object Rocket restricted access to a given cluster. For sharded clusters, Live Migration requires access to oplogs, the ability to make changes to the config server, and access to the primary nodes of each shard. If you aren't able to do those things, then this tool may be suitable.

# Known Limitations
- The scripts can only be run in a single threaded fashion per collection. Running them in parallel will cause issues with the clusterTime sequence numbers (required for MDB v3.6) that are created. 
- There are a few collections that may have been upgraded from 3.4 to 3.6 or from mmap to wiredtiger that generate the following error "pymongo.errors.OperationFailure: Collection <db_name>.<coll> UUID differs from UUID on change stream operations". Which seems related to https://jira.mongodb.org/browse/SERVER-36154. Either the suggested fixes in the jira ticket need to be run or the problematic collections need to be manually dumped and restored without changestreams for syncing.
- The shard load balancer for the source sharded cluster needs to be turned off.
- Any bad Mongoose indexes created that have "safe":null in the index metadata needs to be dropped and recreated in order for mongorestore build index to work.
- The scripts will not shard target collections and is a manual process after restoration is complete.

## How do these scripts work?
There is a single script called run_migration.sh that handles the execution of the other scripts in the background along with logging. run_migration.sh requires a db.<db_name>.collections.txt file to list out all the collections you'd like to migrate over. You can curate which collections to process. The script will first run the CDC portion (generating a resume token for each collection, mongodump, capture all changestream events and storing in destination database). After CDC is done, a .done for the given collection will be created in the mongodump dump directory next to the actual dump files. This file flags the CDR process to execute. CDR consists of mongorestore and replaying all changestream events to get the target database in sync. An example of how to execute run_migration.sh is:

./run_migration.sh mongodb://<username>:<password>@<host1>:<port1>,<host2>:<port2>,<host3>:<port3>/<db_name>?ssl=true mongodb+srv://<username>:<password>@<srv_src_host>/<db_name>?retryWrites=true <db_name>
  
Keep in mind that this script runs everything as a background process. So you should always be wary of rerunning the script and should kill all relevant background processes before trying to rerun it.

The script does it's best to catch known exceptions, e.g. empty collections and the UUID exception in limitations above.

## Requirements
- Python3
- Mongodb tools, e.g. mongodump/restore
- Appropriate user login credentials with necessary permissions, e.g. write to any database/collection
- IP whitelisting
- Turn off load balancer
- Atlas op log size needs to be higher than the default, e.g. 20gb
- Precreate the _cdc table with an index (TBD)
