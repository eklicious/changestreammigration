#!/bin/bash
# Convenience script for kicking off a migration for a given db.collection
# It's assumed and required that the app server needs to stop making writes to the src collection
# The user will be prompted for permission to insert and delete a dummy document from this src collection where _id=-1
# A mongodump will be executed against the src collection
# CDC will be kicked off after the dump to capture any changes
# The user will be prompted to start the app servers again if they like
# This script requires the following parameters:
# src, e.g. objectrocket uri
# dest, e.g. mongodb+srv://eugenekang:password@cmx-qa-9h29h.mongodb.net/test?retryWrites=true
# db, e.g. changestreamtest
# coll, e.g. randomcollection

if [ "$#" -ne 4 ]; then
    echo "Illegal number of parameters. Following parameters are required: source uri, destination uri, database name, collection name"
    exit
fi

read -p "Have you stopped your application servers from writing to the database collections? Y/N: "  stoppedapps
if [ $stoppedapps = "Y" ];
then
   echo "     Glad to hear the app servers are stopped!"
else
   echo "You need to stop your app servers from making writes before moving on..."
   exit
fi

read -p "Is the source database uri correct? Y/N. $1: "  srcprompt
if [ $srcprompt = "Y" ];
then
   echo "     Great! Source database uri is $1"
else
   echo "Please double check your script parameters..."
   exit
fi

read -p "Is the destination database uri correct? Y/N. $2: "  destprompt
if [ $destprompt = "Y" ];
then
   echo "     Great! Destination database uri is $2"
else
   echo "Please double check your script parameters..."
   exit
fi

read -p "Is the database and collection correct? Y/N. $3.$4: "  dbprompt
if [ $dbprompt = "Y" ];
then
   echo "     Great! Database and collection is $3.$4"
else
   echo "Please double check your script parameters..."
   exit
fi

read -p "Is it okay to insert and delete a dummy document into the source collection with _id=-1? Y/N: "  insertprompt
if [ $insertprompt = "Y" ];
then
   echo "     Great! We can finally start running mongodump and cdc..."
else
   echo "Why can't we insert a document with _id=-1?"
   exit
fi

# Finally start the actual work
echo "Kicking off the changestream process against the source database so we can capture the resume token from our dummy insert/delete"
python3 changestream_migration.py --action primetoken --src $1 --dest $2 --db $3 --coll $4 &

# Sleep for 3 seconds so we can capture the resume token after changestream initializes
sleep 3
python3 changestream_migration.py --action triggerprimetoken --src $1 --dest $2 --db $3 --coll $4

# Run mongodump
mongodump --uri $1 --gzip --collection $4

# Turn on CDC Payload 
echo "You can now turn on your app servers again if you'd like"
python3 changestream_migration.py --action cdc --src $1 --dest $2 --db $3 --coll $4

