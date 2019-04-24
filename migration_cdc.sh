#!/bin/bash
# Convenience script for kicking off a migration for a given db.collection
# It's assumed and required that the app server needs to stop making writes to the src collection
# The user will be prompted for permission to update the first document in the src collection with an _tempfield_ and then immediately remove it
# A mongodump will be executed against the src collection
# CDC will be kicked off after the dump to capture any changes
# The user will be prompted to start the app servers again if they like
# This script requires the following parameters:
# src, e.g. objectrocket uri
# dest, e.g. atlas srv 
# db, e.g. db name 
# coll, e.g. collection name

if [ "$#" -ne 4 ]; then
    echo "Illegal number of parameters. Following parameters are required: source uri, destination uri, database name, collection name"
    exit
fi

#read -p "Is the source database uri correct? Y/N. $1: "  srcprompt
#if [ $srcprompt = "Y" ];
#then
#   echo "     Great! Source database uri is $1"
#else
#   echo "Please double check your script parameters..."
#   exit
#fi

#read -p "Is the destination database uri correct? Y/N. $2: "  destprompt
#if [ $destprompt = "Y" ];
#then
#   echo "     Great! Destination database uri is $2"
#else
#   echo "Please double check your script parameters..."
#   exit
#fi

#read -p "Is the database and collection correct? Y/N. $3.$4: "  dbprompt
#if [ $dbprompt = "Y" ];
#then
#   echo "     Great! Database and collection is $3.$4"
#else
#   echo "Please double check your script parameters..."
#   exit
#fi

#read -p "Is it okay to temporarily update the first single document from the source collection with _tempfield_:1 and then unset it immediately after? Y/N: "  insertprompt
#if [ $insertprompt = "Y" ];
#then
#   echo "     Great! We can finally start running mongodump and cdc..."
#else
#   echo "Why can't we insert a document with _id=-1?"
#   exit
#fi

# Finally start the actual work
mongodumpDone="dump/$3/$4.done"
echo "Remove the mongodump completion file so CDR doesn't start"
rm $mongodumpDone

echo "Checking to see if collection actually has documents. If no docs found, then the script will halt."
python3 changestream_migration.py --action checkForDocs --src $1 --dest $2 --db $3 --coll $4
if [ $? -ne 0 ]
then
  echo "No documents found. Halting migration."
  exit 1
fi

echo "Kicking off the time delayed token trigger process. This will run after the next command but needs to be here due to error handling reasons"
python3 changestream_migration.py --action triggerprimetoken --src $1 --dest $2 --db $3 --coll $4 &

echo "Kicking off the changestream process against the source database so we can capture the resume token from our dummy insert/delete"
python3 changestream_migration.py --action primetoken --src $1 --dest $2 --db $3 --coll $4

# Sleep for 3 seconds so we can capture the resume token after changestream initializes
# sleep 3
# python3 changestream_migration.py --action triggerprimetoken --src $1 --dest $2 --db $3 --coll $4 & 

# Sometimes change streams doesn't work due to errors where the UUID doesn't match, e.g. members collection
if [ $? -ne 0 ]
then
  echo "If you killed the process, then disregard. If you are seeing UUID exception, then manually dump (mongodump --uri $1 --gzip --collection $4)/restore (mongorestore --uri $2 --gzip --nsInclude $3.$4 -d $3 -c $4 --drop --numInsertionWorkersPerCollection 20 dump/$3/$4.bson.gz) since you can't follow the instructions here https://jira.mongodb.org/browse/SERVER-36154." >&2
  exit 1
fi

# Run mongodump
mongodump --uri $1 --gzip --collection $4
if [ $? -ne 0 ]
then
  echo "Mongodump has failed. Please look into the error." >&2
  exit 1
fi

echo "Creating a mongodump done file so CDR can start"
touch $mongodumpDone

# Turn on CDC Payload 
echo "Turning on CDC to capture all changes since we started mongodump"
python3 changestream_migration.py --action cdc --src $1 --dest $2 --db $3 --coll $4
if [ $? -ne 0 ]
then
  echo "CDC has failed. Assuming the resume token is set, you can manually resume the CDC process by running python3 changestream_migration.py --action cdc --src $1 --dest $2 --db $3 --coll $4" >&2
  exit 1
fi
