# n2c2-2018-track1-sparql
Small pipeline to perform some basic cohort identification on n2c2 2018 track1 data using SPARQL

# Setup

## Overview
Overall process:
* Get n2c2 data
* Get UMLS ontology files
* Prepare a postgres database
* Prepare a SPARQL endpoint (RDF triple store)
* Prepare a MedCATservice endpoint

## n2c2 data
Clone the repo recursively with `git clone --recursive https://github.com/rob-a-bolton/n2c2-2018-track1-sparql.git` and change into that directory.  
Download the [n2c2 2018 Track 1: Cohort Selection for Clinical Trials](https://portal.dbmi.hms.harvard.edu/projects/n2c2-2018-t1/) data and unzip the files into the data directory.  
At this point, `data/` should contain both `train/` and `n2c2-t1_gold_standard_test_data/` directories. `train/` should contain numbered patient XML files and `n2c2-t1_gold_standard_test_data` should contain `n2c2-t1_gold_standard_test_data/test`, which contains its own patient XML files.  

## UMLS Metathesaurus

Download the [UMLS Metathesaurus](https://www.nlm.nih.gov/research/umls/index.html) software and export a subset containing at least the SNOMEDCT and semantic types components (SNOMEDCT and STY).  
Ensure they are in turtle (.ttl) format. Convert them (with [Protégé](https://protege.stanford.edu/) or [robot](https://github.com/ontodev/robot)) if necessary.

Place these (as SNOMEDCT.ttl and STY.ttl) into the ontologies directory.  

## Postgres

Setup a postgres database with a user for this script, and have the username/password to hand.  
It is advised to use a tool such as [pgAdmin](https://www.pgadmin.org/) or [DBeaver](https://dbeaver.io/) if you do not know your way around the psql client.  

Ensure the user you create has full privileges in the database you created, as it must be allowed to create/drop tables.

## SPARQL Endpoint

Setup an RDF store that provides a SPARQL endpoint.  
Either [Blazegraph](https://blazegraph.com/) or [Stardog](https://stardog.com/) are recommended.  
Performance of SPARQL implementations varies wildly so if the queries in this script fail to run in a reasonable time then try another database.

## MedCATservice

Setup [MedCATservice](https://github.com/CogStack/MedCATservice).  
Ideally you should use the SNOMED-CT or UMLS model. Instructions for getting these are available on the [official MedCAT repository](https://github.com/CogStack/MedCAT/#snomed-ct-and-umls).  

# Usage

`./run.sh [OPTION] ... ACTION`  

The tool provides 5 core actions that may be performed using the script with the action as an argument (e.g. `run.sh umls`):  
* sql: Load the loose n2c2 data files into Postgres
* medcat: Extract annotations from the n2c2 data and insert into a new table
* umls: Load the UMLS ontology files into the RDF triple store
* rml: Export the annotated n2c2 data from Postgres to RDF and import into the triple store
* sparql: Run the cohort selection SPARQL queries and present their f1 scores

You may specify the `all` action to run each of these in this order.  

Various options must be supplied depending upon the action being performed.  
General options:  
* `-h` Print the help info
* `-c` Perform the action's "clean" command: Drop database tables/wipe RDF graphs etc.

## SQL options
* `-u USER` Postgres username **REQUIRED**
* `-p PASS` Postgres password **REQUIRED**
* `-d DB` Postgres database name **REQUIRED**

## MedCATservice options
* `-m URL` MedCATservice URL: Default `http://127.0.0.1:5000/api/process_bulk`

## SPARQL options
* `-o DIR` Specify directory containing ontology files: Default `./ontologies`
* `-s URL` Specify SPARQL endpoint URL: **REQUIRED**
* `-a user:pass` Specify the HTTP Baisc auth username/password for the SPARQL endpoint
* `-l` Load RDF documents using a SPARQL `LOAD GRAPH` command rather than via HTTP POST

## RML options
* `-M MEM` Set the amount of memory given to the RML mapping tool

## Notes
The `-l` option for SPARQL is faster than the default of using HTTP POST but requires that the database has permissions to access the RDF document files.  
The `-o` option is thus primarily used to provide an alternative directory to load ontologies from to supply a custom directory in a location accessible by the RDF store.  
Please note that `-o` also impacts other forms of RDF document upload (e.g. the RML export) and should probably only be used when performing the `umls` command.  

The `-M` option is passed directly to the java command line used to start the RML tool.  
e.g. `./run.sh -M 8G rml` would run `java -Xmx8G -jar rmlmapper.jar`  
At the time of writing this documentation it was found that 6G was enough to perform the export.  
Running `all` the steps in one go will likely require a lot of memory as MedCATservice will and the RDF store will both consume a large amount of memory while they run.
