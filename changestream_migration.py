#!/usr/bin/python
"""
Generic changestream script for any collection to serve as CDC tool for the MIGRATION
For my testing, I used the following parameters:
python3 changestream_migration.py --action ? --src mongodb+srv://<username>:<password>@<srv_host>/test?retryWrites=true --dest mongodb+srv://<username>:<password>@<srv_host>/test?retryWrites=true --db <db_name> --coll <coll_name>

This script is meant to do 1 of 4 things:
1) creating a fresh resume token before we start running a mongodump. This is also meant to sniff test for any collection issues where the UUID may be out of sync due to an upgrade from 3.4 to 3.6 
2) updating the first document the src collection with a dummy field and then unsetting it to trigger the creation of the resume token
3) cdc all changes in the src database and pushing out the changestream payload to the dest db
4) cdr all changes by consuming the payload in dest db and replay it after mongorestore is done

Usage:
    changestream_migration.py [--action ACTION] [--src SRC] [--dest DEST] [--db DB] [--coll COLL]

Options:
    --action ACTION        Either primetoken, triggerprimetoken, cdc, cdr (change data replay)
    --src SRC                 MongoDB URI
    --dest DEST       destination URI
    --db DB         Database where your data resides.
    --coll COLL    Collection where the data resides.
"""
import pymongo
import json
import pickle
import time
import datetime
from docopt import docopt
from bson.json_util import dumps
from bson.timestamp import Timestamp

def get_pipeline():
    """
    What sort of pipeline do we need for the changestream
    """
    # Below is an example of an explicit pipeline for certain operations
    # pipeline = [{"$match":{"operationType": "update"}},{"$project":{"reported.rated":"$fullDocument.reported.rated","reported.user":"$fullDocument.reported.user","subject":"$fullDocument.subject"}}]
    # Below is an example of unrestricted pipeline that will capture all change events, https://docs.mongodb.com/manual/reference/change-events/
    pipeline = []
    return pipeline

def check_coll_has_docs(srccoll):
    """
    some collections don't have docs. throw an exception gracefully to terminate migration.
    """
    print("Check if collection has documents or not")
    doc = srccoll.find_one()
    if doc is None:
        raise Exception("Collection is empty... There's nothing to do here. Terminate this process and move on.")

def check_token_file(token_file):
    """
    Make sure the token file exists else changestreams may not be working, e.g. UUID error
    """
    print("Check if token file exists")
    try:
        fh = open(token_file, 'r')
    except FileNotFoundError:
        raise Exception("Changestream resume token not found. This needs to exist to prove that changestreams is working against your source collection.")

def trigger_prime_token(srccoll):
    """
    update the first document to have a dummy field then unset it
    """
    print("Update the first document in the src collection to have a temporary field then unset it...")
    time.sleep(2)
    doc = srccoll.find_one()
    if doc is None:
        raise Exception("Collection is empty... There's nothing to do here. Terminate this process and move on.")        
    else:
        print(doc["_id"])
        srccoll.update_one({"_id": doc["_id"]}, {"$set":{"_tempfield_": 1}})
        srccoll.update_one({"_id": doc["_id"]}, {"$unset":{"_tempfield_": 1}})
        # We can't insert a doc with _id all the time. Some collections have hash indexes on different fields so this ends up erroring out
        # print("Insert then delete a dummy document into the given src collection...")
        # srccoll.insert_one({"_id":-1})
        # srccoll.delete_one({"_id":-1})
    quit()

def prime_token(token_file, srccoll, pipeline):
    """
    wait for the deletion of the dummy doc, get the resume token and store it for future reference
    """
    print("Waiting for a fresh resume token:")
    for msg in srccoll.watch(pipeline):
        print(dumps(msg, indent=2))
        if msg["operationType"]=="update":
            with open(token_file, 'wb') as h:
                pickle.dump(msg['_id'], h)
            quit()

def cdr(cdccoll, destdb, db_name, coll_name):
    """
    After the restore of the target db is done and cdc payload is running, we can now replay all the cdc events for just 1 collection in case if we are running this script in parallel   
    """
    # resume token is no longer needed. I'm storing a status in the cdc table and querying off of that
    # just like cdc, we will have a resume token based on clustertime though
    # this resume token will be a query filter against the cdc collection
    # if resume_token is None:
    #    resume_token=Timestamp(0,1);
    # print("Resume token: {}".format(resume_token))

    # CDR will run in an infinite loop
    print("CDR process is running in infinite loop looking for any CDC changes...")
    while True:
        # print("Looping CDR for {}.{} - {}...".format(db_name, coll_name, datetime.datetime.fromtimestamp(time.time()).strftime('%Y-%m-%d %H:%M:%S')))
        # changes = cdccoll.find({"clusterTime": {"$gt": resume_token}}).sort("clusterTime")
        changes = cdccoll.find({"status":{"$exists":0},"clusterTime":{"$exists":1}, "ns": {"db":db_name, "coll":coll_name}}).sort("clusterTime")

        # iterate through all the changes
        for doc in changes:
            print(doc)
            if doc["operationType"]=="insert":
                try:
                    destdb[doc["ns"]["coll"]].insert_one(doc["fullDocument"])
                except pymongo.errors.DuplicateKeyError as dx:
                    print("Duplicate key insert error: {}".format(doc["documentKey"]))
                    print("Doc id: {}".format(doc["_id"]))
                    cdccoll.update_one({"_id":doc["_id"]},{ "$set": {"exception":"Duplicate key insert error"}})
            elif doc["operationType"]=="replace":
                destdb[doc["ns"]["coll"]].replace_one(doc["documentKey"], doc["fullDocument"])
            elif doc["operationType"]=="update":
                destdb[doc["ns"]["coll"]].replace_one(doc["documentKey"], doc["fullDocument"])
            elif doc["operationType"]=="delete":
                destdb[doc["ns"]["coll"]].delete_one(doc["documentKey"])
            else:
                print("Unknown cdr operation... {}".format(msg))        

            cdccoll.update_one({"_id":doc["_id"]},{ "$set": {"status":"Done"}})

            # resume_token = doc['clusterTime']
            # with open(token_file, 'wb') as h:
            #    pickle.dump(doc['clusterTime'], h)

def cdc_payload(token_file, resume_token, srccoll, pipeline, cdccoll):
    """
    Performs change data capture for a given db.collection and sends it to a destination uri
    We are not going to replay the operations against the target db since the target db may not be ready due to restore still running
    Rather, we are going to store the changes in a hardcoded collection in the target db
    """
    # return the most current majority-committed version of the updated document
    change_stream_options = { 'resume_after': resume_token, 'full_document':'updateLookup' }

    print("Ready for change data capture. Now you can begin the restoration syncing process...:")
    # We need to create a fake cluster time because 3.6 doesn't have it in the changestream payload
    # since this is single threaded, it's okay...
    clusterTime = time.time()
    for msg in srccoll.watch(pipeline, **change_stream_options):
        msg["clusterTime"] = clusterTime

        print(dumps(msg, indent=2))
        if msg["operationType"]=="insert":
            cdccoll.insert_one(msg)
        elif msg["operationType"]=="replace":
            cdccoll.insert_one(msg)
        elif msg["operationType"]=="update":
            cdccoll.insert_one(msg)
        elif msg["operationType"]=="delete":
            cdccoll.insert_one(msg)
        else:
            print("Unknown cdc operation... {}".format(msg))

        # increment our sequence number
        clusterTime = clusterTime + 1

        with open(token_file, 'wb') as h:
            pickle.dump(msg['_id'], h)

def cdc(token_file, resume_token, srccoll, pipeline, destcoll):
    """
    Performs change data capture for a given db.collection and sends it to a destination uri 
    This is older logic where we applied changes directly against the target collection
    This won't work if the restore hasn't been done yet
    """
    # return the most current majority-committed version of the updated document
    change_stream_options = { 'resume_after': resume_token, 'full_document':'updateLookup' }

    print("Ready for change data capture:")
    for msg in srccoll.watch(pipeline, **change_stream_options):
        print(dumps(msg, indent=2))
        if msg["operationType"]=="insert":
            destcoll.insert_one(msg["fullDocument"])
        elif msg["operationType"]=="replace":
            destcoll.replace_one({"_id": msg["documentKey"]["_id"]}, msg["fullDocument"])
        elif msg["operationType"]=="update":
            destcoll.replace_one({"_id": msg["documentKey"]["_id"]}, msg["fullDocument"])
        elif msg["operationType"]=="delete":
            destcoll.delete_one({"_id": msg["documentKey"]["_id"]})
        else:
            print("Unknown cdc operation... {}".format(msg))

        with open(token_file, 'wb') as h:
            pickle.dump(msg['_id'], h)

def connect(uri):
    """
    Establishes a connection to the mdb.
    """
    print("Checking db connection: {}".format(uri)) 
    try:
        mc = pymongo.MongoClient(uri, connect=True, socketTimeoutMS=5000,
        serverSelectionTimeoutMS=5000)
        mc.server_info()
    except Exception as err:
        print("Could not connect to {}!".format(uri))
        print("Make sure your db is correctly configured.")
        raise Exception("Make sure your db is correctly configured.")
    return mc

def check_database(conn, db):
    print("Checking database: {}".format(db))
    print("Connection: {}".format(conn))
    print("Object Rocket doesn't permit running show dbs so we have to assume the database exists and not check to see if it doesn't exist")
    #if db in conn.database_names():
    return conn[db]
    #print("Cannot find {} database on server {}".format(db, conn.primary ))
    #quit()

def check_collection(coll):
    """
    Read majority is required to support Change Streams.
    """
    print("Checking collection: {}".format(coll))
    try:
        rc = pymongo.read_concern.ReadConcern(level='majority')
        coll.with_options(read_concern=rc).find({'_id': {'$exists': 1}})
    except Exception as ex:
        print("error: {}".format(ex))
        print("enableMajorityReadConcern is required to support Change Streams")
        raise Exception("enableMajorityReadConcern is required to support Change Streams")
    return coll

def main(action, srcuri, desturi, dbname, collname):
    """
    Script `main` method that establishes a connection to the database given a
    `srcuri`, `dbname` and `collname`.
    Initiates the CDC to dest
    """

    # Set up the token file name and resume token var
    resume_token = None
    token_file = './tokens/' + dbname + '.' + collname + '.token'
    
    # Set up the pipeline
    pipeline = get_pipeline()

    # Verify the src connection
    srcconn = connect(srcuri)
    srcdb = check_database(srcconn, dbname)
    srccoll = check_collection(srcdb[collname])

    if action=="checkForDocs":
        check_coll_has_docs(srccoll)
        quit()
    elif action=="checkTokenFile":
        check_token_file(token_file)
        quit()
    elif action=="primetoken":
        print("Priming change stream token...")
        prime_token(token_file, srccoll, pipeline)
    elif action=="triggerprimetoken":
        print("Triggering the priming of the resume token")
        trigger_prime_token(srccoll)
    elif action=="cdc":
        print("Running in CDC mode...")
        # Figure out the resume token logic
        print("Reading token file: {}".format(token_file))
        try:
            with open(token_file, 'rb') as h:
                resume_token = pickle.loads(h.read())
            print("Resume token found... {}".format(resume_token))
        except FileNotFoundError as fx:
            # do nothing
            print("Token file not found. Starting from the beginning. {}".format(token_file))
        except EOFError as ex:
            # do nothing blank file
            print("Token file empty. Assume file doesn't exist. {}".format(token_file))

    elif action=="cdr":
        print("Running in CDR (Change Data Replay) mode...")
    else:
        print("Unknown action... {}".format(action))
        quit()

    # Following logic applies to both cdc and cdr...

    # Verify the dest db connection and db.coll
    destconn = connect(desturi)
    destdb = check_database(destconn, dbname)
    # destcoll is irrelevant now since we aren't doing direct writes to the target coll    
    # destcoll = check_collection(destdb[collname])

    # We need to verify the dest db has a collection called cdc
    cdccoll = check_collection(destdb["_cdc"])

    if action=="cdc":
        cdc_payload(token_file, resume_token, srccoll, pipeline, cdccoll)
    elif action=="cdr":
        cdr(cdccoll, destdb, dbname, collname)

if __name__ == '__main__':
    print("Starting...")
    opts = docopt(__doc__, version='1.0.0rc2') 
    print("Getting options")
    print(opts)
    main(opts['--action'], opts['--src'], opts['--dest'], opts['--db'], opts['--coll'] )

