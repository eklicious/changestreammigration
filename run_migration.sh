#!/bin/bash
# Convenience script for kicking off migrations for all collections in a given database
# The user is required to run show collections and put together a list of collections to process
# The file name for this list of collections is in the following format db.<db_name>.collections.txt 
# This script requires the following parameters:
# src, e.g. objectrocket uri
# dest, e.g. atlas srv 
# db, e.g. db name 

if [ "$#" -ne 3 ]; then
    echo "Illegal number of parameters. Following parameters are required: source uri, destination uri, and database name"
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

read -p "Is the database correct? Y/N. $3: "  dbprompt
if [ $dbprompt = "Y" ];
then
   echo "     Great! Database is $3"
else
   echo "Please double check your script parameters..."
   exit
fi

read -p "Is it okay to temporarily update the first single document from the source collection with _tempfield_:1 and then unset it immediately after? Y/N: "  insertprompt
if [ $insertprompt = "Y" ];
then
   echo "     Great! We can finally start running the migration..."
else
   echo "Why can't we insert a document with _id=-1?"
   exit
fi

# Finally start the actual work
echo "Creating logs and tokens directory in case they don't exist"
mkdir -p logs tokens

collFile="db.$3.collections.txt"

echo "Checking to see if $collFile exists, output of 'show collections' saved."
if [ ! -f $collFile ]
then
  echo "$collFile not found. Make sure you run 'show collections' against the source db and save the collections you want to actually migrate."
  exit 1
fi

echo "Iterating through collections and kicking off CDC/CDR migration for each collection..."
while IFS= read line
do
  echo "Migrating $line"
  ./migration_cdc.sh $1 $2 $3 $line  >> logs/$line.cdc.log 2>&1 &
  sleep 5
  ./migration_cdr.sh $2 $3 $line >> logs/$line.cdr.log 2>&1 &
done <"$collFile"
