#!/bin/bash
# Convenience script for finishing off a migration for a given db.collection
# Mongorestore to target db is the first step
# Then the cdc payload gets replayed to sync up dest to src 
# This script requires the following parameters:
# dest, e.g. atlas srv
# db, e.g. db name
# coll, e.g. collection name

if [ "$#" -ne 3 ]; then
    echo "Illegal number of parameters. Following parameters are required: destination uri, database name, collection name"
    exit
fi

#read -p "Is the destination database uri correct? Y/N. $1: "  destprompt
#if [ $destprompt = "Y" ];
#then
#   echo "     Great! Destination database uri is $1"
#else
#   echo "Please double check your script parameters..."
#   exit
#fi

#read -p "Is the database and collection correct? Y/N. $2.$3: "  dbprompt
#if [ $dbprompt = "Y" ];
#then
#   echo "     Great! Database and collection is $2.$3"
#else
#   echo "Please double check your script parameters..."
#   exit
#fi

# Finally start the actual work
echo "Checking to see if the cdc script generated a changestream resume token or not as this is required."
python3 changestream_migration.py --action checkTokenFile --src $1 --dest $1 --db $2 --coll $3
if [ $? -ne 0 ]
then
  echo "Changestream resume token file not found. Need to make sure there are no errors related to changestreams and your source collection."
  exit 1
fi

mongodumpNotDone=true
while $mongodumpNotDone
do
  sleep 5 
  echo "Check to see if dump/$2/$3.done file is created so we can start CDR"
  if [ -f dump/$2/$3.done ]
  then
    echo "Mongodump is complete. Begin CDR"
    mongodumpNotDone=false
  fi
done

echo "Kicking off mongorestore into the destination db"
mongorestore --uri $1 --gzip --nsInclude $2.$3 -d $2 -c $3 --drop --numInsertionWorkersPerCollection 20 dump/$2/$3.bson.gz
if [ $? -ne 0 ]
then
  echo "Mongorestore failed. Please try rerunning it (mongorestore --uri $1 --gzip --nsInclude $2.$3 -d $2 -c $3 --drop --numInsertionWorkersPerCollection 20 dump/$2/$3.bson.gz) and look into the error." >&2
  exit 1
fi

# Turn on CDR Payload Replay 
python3 changestream_migration.py --action cdr --src $1 --dest $1 --db $2 --coll $3
if [ $? -ne 0 ]
then
  echo "Change data replay failed. You can manually rerun using python3 changestream_migration.py --action cdr --src $1 --dest $1 --db $2 --coll $3" >&2
  exit 1
fi
