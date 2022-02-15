#!/bin/bash

cd "$(dirname $(readlink -f $0))"
ROOTDIR="$(pwd)"

function print_usage {
  echo "./run.sh [OPTIONS] [ACTION]
  Args marked REQUIRED/<TAG> denotes the arg tag name.
  Actions specifying a tag need all args with this tag to be provided.
  Options:
    -h          Print this help
    -u          Specify the SQL username        REQUIRED/SQL
    -p          Specify the SQL password        REQUIRED/SQL
    -d          Specify the SQL database name   REQUIRED/SQL
    -s          Specify the SPARQL endpoint     REQUIRED/SPARQL
    -m          Specify the MedCATservice endpoint
                  Default: http://127.0.0.1:5000/api/process_bulk
    -c          Clean. Wipes data associated with an action.
                Examples: 
                  ./run.sh -c sql       Drop sql n2c2 tables
                  ./run.sh -c medcat    Drop sql medcat annotation tables
                  ./run.sh -c umls      Drop the UMLS RDF graphs
                  ./run.sh -c rml       Drop the n2c2 RDF graphs

  Tags following action show arg group needed.
  Actions:
    sql         Loads the n2c2 data into a SQL database [SQL]
    medcat      Extracts medcat annotations and inserts into database [SQL]
    umls        Load UMLS subset into the RDF triple store [SPARQL]
    rml         Pulls annotated data from SQL into RDF, and applies any necessary patches [SQL,SPARQL]
    sparql      Runs the cohort [SPARQL]
    run, all    Runs full pipeline (all actions) [SQL,SPARQL]
" >&2
}

MEDCAT_ENDPOINT='http://127.0.0.1:5000/api/process_bulk'

function cleanup {
  if [[ -f PGPASS ]]; then
    rm PGPASS
  fi
}

function failsafe {
  echo "$1" >&2
  cleanup
  exit 1
}

function check_data_exists {
  if ! [[ -d ./data/train ]] || ! [[ -d ./data/n2c2-t1_gold_standard_test_data/n2c2-t1_gold_standard_test_data/test ]]; then
    failsafe 'Could not locate n2c2 data, exiting'
  fi
}

function setup_db_con_str {
  if [[ -z "$USER" ]] || [[ -z "$PASS" ]] || [[ -z "$DBNAME" ]]; then
    failsafe 'Must specify -u USER, -p PASS, and -d DBNAME to perform an action that requires SQL' >&2
  fi
  DBSTR="jdbc:postgresql://localhost/${DBNAME}?user=${USER}&password=${PASS}"
  touch PGPASS
  chmod 0600 PGPASS
  echo "localhost:5432:${DBNAME}:${USER}:${PASS}" > PGPASS
  export PGPASSFILE=PGPASS
}

function run_sql {
  check_data_exists
  setup_db_con_str
  if [[ -z "${CLEAN}" ]]; then
    echo 'Importing n2c2 from XML to SQL'
    pushd n2c22018t12sql
    if clj -M -m n2c22018t12sql.core -a true -d ../data/train/ -j ${DBSTR}; then
      echo 'Import complete'
    else
      failsafe 'Import failed, exiting'
    fi
    popd
  else
    echo 'Cleaning n2c2 tables'
    psql -h localhost -p 5432 -U ${USER} -d ${DBNAME} << "SQL"
      DROP TABLE IF EXISTS patients CASCADE;
      DROP TABLE IF EXISTS annotations CASCADE;
      DROP TABLE IF EXISTS documents CASCADE;
SQL
    echo 'Tables cleaned'
  fi
}

function run_medcat {
  check_data_exists
  setup_db_con_str
  if [[ -z "${CLEAN}" ]]; then
    pushd ann2sql
    if clj -M -m ann2sql.core -s ${DBSTR} -d ${DBSTR} \
       -S documents \
       -D medcat \
       -u ${MEDCAT_ENDPOINT} \
       -c pat_id -c doc_id -c date -t text \
       --create-tables;  then
      echo 'MedCAT annotation succeeded'
    else
      failsafe 'MedCAT annotation failed, exiting'
    fi
    popd
  else
    echo 'Cleaning medcat tables'
    psql -h localhost -p 5432 -U ${USER} -d ${DBNAME} << "SQL"
      DROP TABLE IF EXISTS medcat
SQL
    echo 'Tables cleaned'

  fi
}

while getopts ':hcu:p:d:m:s:' OPTION; do
  case ${OPTION} in
    h)
      print_usage
      exit 0
      ;;
    c)
      CLEAN=yes
      ;;
    u)
      USER=${OPTARG}
      ;;
    p)
      PASS=${OPTARG}
      ;;
    d)
      DBNAME=${OPTARG}
      ;;
    m)
      MEDCAT_ENDPOINT=${OPTARG}
      ;;
    s)
      SPARQL_ENDPOINT=${OPTARG}
      ;;
    ?)
      failsafe "Invalid option: -${OPTARG}"
      ;;
  esac
done

ACTION=${@:$OPTIND:1}

if [[ -z ${ACTION} ]]; then
  failsafe 'No action specified' >&2
elif [[ 'sql' == ${ACTION} ]]; then
  run_sql
elif [[ 'medcat' == ${ACTION} ]]; then
  run_medcat
else
  failsafe "Invalid action: ${ACTION}" >&2
fi

cleanup
