#!/bin/bash

cd "$(dirname $(readlink -f $0))"

function print_usage {
  echo "./run.sh [OPTIONS] [ACTION]
  Options:
    -h          Print this help
    -u          Specify the SQL username
    -p          Specify the SQL password
    -s          Specify the SPARQL endpoint
    -c          Clean. Wipes data associated with an action.
                Examples: 
                  ./run.sh -c sql       Drop sql n2c2 tables
                  ./run.sh -c medcat    Drop sql medcat annotation tables
                  ./run.sh -c umls      Drop the UMLS RDF graphs
                  ./run.sh -c rml       Drop the n2c2 RDF graphs
  Actions:
    sql         Loads the n2c2 data into a SQL database
    medcat      Extracts medcat annotations and inserts into database
    umls        Load UMLS subset into the RDF triple store
    rml         Pulls annotated data from SQL into RDF, and applies any necessary patches
    sparql      Runs the cohort 
    run, all    Runs full pipeline (all actions)
" >&2
}

function check_data_exists {
  if ! [[ -d ./data/train ]] || ! [[ -d ./data/n2c2-t1_gold_standard_test_data/n2c2-t1_gold_standard_test_data/test ]]; then
    echo 'Could not locate n2c2 data, exiting' >&2
    exit 1
  fi
}

function setup_db_con_str {
  if [[ -z "$USER" ]] || [[ -z "$PASS" ]]; then
    echo 'Must specify both -u USER and -p PASS to perform an action that requires SQL' >&2
    exit 1
  fi
  DBSTR="jdbc:postgresql://localhost/n2c2?user=${USER}&password=${PASS}"
}

function run_sql {
  echo 'Importing n2c2 from XML to SQL'
  check_data_exists
  setup_db_con_str
  pushd n2c22018t12sql
  # TODO: Support -c via `psql`
  if ! clj -M -m n2c22018t12sql.core -t ${PATIENT_TABLE} -a true -d ../data/train/ -j ${DBSTR}; then
    echo 'Import failed, exiting'
    exit 1
  fi
  popd
  echo 'Import complete'
}

while getopts ':h:u:p:s:' OPTION; do
  case ${OPTION} in
    h)
      print_usage
      exit 0
      ;;
    u)
      USER=${OPTARG}
      ;;
    p)
      PASS=${OPTARG}
      ;;
    s)
      SPARQL_ENDPOINT=${OPTARG}
      ;;
    ?)
      echo "Invalid option: -${OPTARG}"
      exit 1
      ;;
  esac
done

ACTION=${@:$OPTIND:1}

if [[ -z ${ACTION} ]]; then
  echo 'No action specified' >&2
  exit 1
elif [[ 'sql' == ${ACTION} ]]; then
  echo 'Inserting to SQL'
  run_sql
else
  echo "Invalid action: ${ACTION}" >&2
  exit 1
fi
