#!/bin/bash
# Convenience script for finishing off a migration for a given db.collection
# Mongorestore to target db is the first step
# Then the cdc payload gets replayed to sync up dest to src 
# This script requires the following parameters:
# dest, e.g. mongodb+srv://eugenekang:password@cmx-qa-9h29h.mongodb.net/test?retryWrites=true
# db, e.g. changestreamtest
# coll, e.g. randomcollection

if [ "$#" -ne 3 ]; then
    echo "Illegal number of parameters. Following parameters are required: destination uri, database name, collection name"
    exit
fi

read -p "Is the destination database uri correct? Y/N. $1: "  destprompt
if [ $destprompt = "Y" ];
then
   echo "     Great! Destination database uri is $1"
else
   echo "Please double check your script parameters..."
   exit
fi

read -p "Is the database and collection correct? Y/N. $2.$3: "  dbprompt
if [ $dbprompt = "Y" ];
then
   echo "     Great! Database and collection is $2.$3"
else
   echo "Please double check your script parameters..."
   exit
fi

# Finally start the actual work
echo "Kicking off mongorestore into the destination db"
mongorestore --uri $1 --gzip --nsInclude $2.$3 -d $2 --drop --numInsertionWorkersPerCollection 20 dump/$2/

# Turn on CDR Payload Replay 
python3 changestream_migration.py --action cdr --src $1 --dest $1 --db $2 --coll $3

