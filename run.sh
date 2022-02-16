#!/bin/bash

# TODO: Do not CD until after args processed so relative dirs can be set correctly
ROOTDIR="$(dirname $(readlink -f $0))"

function print_usage {
  echo "./run.sh [OPTIONS] [ACTION]
  Args marked REQUIRED/<TAG> denotes the arg tag name.
  Actions specifying a tag need all args with this tag to be provided.
  Options:
    -h            Print this help
    -u USER       Specify the SQL username        REQUIRED/SQL
    -p PASS       Specify the SQL password        REQUIRED/SQL
    -d DB         Specify the SQL database name   REQUIRED/SQL
    -m URL        Specify the MedCATservice endpoint
                    Default: http://127.0.0.1:5000/api/process_bulk

    -o DIR        Specify the directory containing the ontology files
                    Default: ./ontologies

    -s URL        Specify the SPARQL endpoint     REQUIRED/SPARQL
                    Provide the root database endpoint e.g.
                        http://127.0.0.1:5820/mydb
                    rather than
                        http://127.0.0.1:5820/mydb/query

    -a USER:PASS  Specify the username:password for SPARQL http basic auth

    -l            Load ontologies from a local file using SPARQL update
                  rather than the HTTP graph store protocol. Endpoint must
                  support `file://` scheme in a LOAD to use this feature.

    -c            Clean. Wipes data associated with an action.
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
SPARQL_QUERY_HEADER='Content-Type: application/sparql-query'
SPARQL_UPDATE_HEADER='Content-Type: application/sparql-update'
ONTOLOGY_DIR="${ROOTDIR}/ontologies"
DATA_DIR="${ROOTDIR}/data"

function cleanup {
  if [[ -f PGPASS ]]; then
    rm PGPASS
  fi
}

function failsafe {
  echo -e "$1" >&2
  cleanup
  exit 1
}

function get_rmlmapper {
  LATEST_VERSION="$(curl -so /dev/null -w '%{redirect_url}' 'https://github.com/RMLio/rmlmapper-java/releases/latest' | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+')"
  RML_JAR=( ${ROOTDIR}/rmlmapper-${LATEST_VERSION}*.jar )
  if [[ ! -f ${RML_JAR} ]]; then
    JAR_LINK="$(curl -L 'https://github.com/RMLio/rmlmapper-java/releases/latest' | grep -o "href=\".*${LATEST_VERSION}.*.jar" | sed 's/href="/https:\/\/github.com/')"
    pushd ${ROOTDIR}
    if ! curl -OL "${JAR_LINK}"; then
      failsafe "Could not download rmlmapper v${LATEST_VERSION}"
    fi
    popd
    RML_JAR=( ${ROOTDIR}/rmlmapper-${LATEST_VERSION}*.jar )
  fi
}

function check_data_exists {
  if ! [[ -d ${DATA_DIR}/train ]] || ! [[ -d ${DATA_DIR}/n2c2-t1_gold_standard_test_data/n2c2-t1_gold_standard_test_data/test ]]; then
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

function test_sparql_endpoints {
  if [[ -z "${SPARQL_ENDPOINT}" ]]; then
    failsafe 'No SPARQL endpoint provided'
  fi

  STATUS=$(curl "${SPARQL_ENDPOINT}/query" \
    ${SPARQL_AUTH:+ -u "${SPARQL_AUTH}"} \
    -H "${SPARQL_QUERY_HEADER}" \
    -so /dev/null \
    -w '%{http_code}' \
    -d 'SELECT * FROM <http://127.0.0.254/> WHERE { ?a ?b ?c } LIMIT 0')

  if [[ ${STATUS} -eq 415 ]]; then
    failsafe "SPARQL query endpoint does not recognise ${SPARQL_QUERY_HEADER} content-type"
  elif [[ ${STATUS} -eq 401 ]]; then
    failsafe 'SPARQL query endpoint requires authorization, none provided'
  elif [[ ${STATUS} -ne 200 ]]; then
    failsafe "Unknown SPARQL error on query: ${STATUS}"
  fi

  STATUS=$(curl "${SPARQL_ENDPOINT}/update" \
    ${SPARQL_AUTH:+ -u "${SPARQL_AUTH}"} \
    -H "${SPARQL_UPDATE_HEADER}" \
    -so /dev/null \
    -w '%{http_code}' \
    -d 'DROP SILENT GRAPH <http://127.0.0.254/>')

  if [[ ${STATUS} -eq 415 ]]; then
    failsafe "SPARQL update endpoint does not recognise ${SPARQL_UPDATE_HEADER} content-type"
  elif [[ ${STATUS} -eq 401 ]]; then
    failsafe 'SPARQL update endpoint requires authorization, none provided'
  elif [[ ${STATUS} -ne 200 ]]; then
    failsafe "Unknown SPARQL error on update: ${STATUS}"
  fi

}

function run_sql {
  check_data_exists
  setup_db_con_str
  if [[ -z "${CLEAN}" ]]; then
    echo 'Importing n2c2 from XML to SQL'
    pushd "${ROOTDIR}/n2c22018t12sql"
    if clj -M -m n2c22018t12sql.core -a true -d "${DATA_DIR}/train/" -j ${DBSTR}; then
      echo 'Import complete'
      popd
    else
      failsafe 'Import failed, exiting'
    fi
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
    pushd "${ROOTDIR}/ann2sql"
    if clj -M -m ann2sql.core -s ${DBSTR} -d ${DBSTR} \
       -S documents \
       -D medcat \
       -u ${MEDCAT_ENDPOINT} \
       -c pat_id -c doc_id -c date -t text \
       --create-tables;  then
      echo 'MedCAT annotation succeeded'
      popd
    else
      failsafe 'MedCAT annotation failed, exiting'
    fi
  else
    echo 'Cleaning medcat tables'
    psql -h localhost -p 5432 -U ${USER} -d ${DBNAME} << "SQL"
      DROP TABLE IF EXISTS medcat
SQL
    echo 'Tables cleaned'

  fi
}

function upload_ontology {
  if [[ -f "$2" ]]; then
    if [[ -z "${SPARQL_LOAD_LOCAL}" ]]; then
      STATUS=$(curl "${SPARQL_ENDPOINT}?graph=$1" \
          ${SPARQL_AUTH:+ -u "${SPARQL_AUTH}"} \
          -so /dev/null \
          -w '%{http_code}' \
          -H 'Content-Type: text/turtle' \
          -T ${2})
      if [[ ${STATUS} -ne 200 ]]; then
        failsafe "❌\nError uploading file $2 to graph <$1> on endpoint ${SPARQL_ENDPOINT}: ${STATUS}"
      fi
    else
      FILE="$(readlink -f $2)"
      STATUS=$(curl "${SPARQL_ENDPOINT}/update?graph=$1" \
          ${SPARQL_AUTH:+ -u "${SPARQL_AUTH}"} \
          -so /dev/null \
          -w '%{http_code}' \
          -H "${SPARQL_UPDATE_HEADER}" \
          -d "LOAD <file://${FILE}> INTO GRAPH <${1}>")
      if [[ ${STATUS} -eq 500 ]]; then
        failsafe "❌\nError uploading file $2 to graph <$1> on endpoint ${SPARQL_ENDPOINT}: ${STATUS}\nCheck RDF store has access to ${ONTOLOGY_DIR}, as this is needed with LOAD <file://>"
      elif [[ ${STATUS} -ne 200 ]]; then
        failsafe "❌\nError uploading file $2 to graph <$1> on endpoint ${SPARQL_ENDPOINT}: ${STATUS}"
      fi
    fi
  else
    failsafe "❌\nError uploading file $2 to graph <$1> on endpoint ${SPARQL_ENDPOINT}: file does not exist"
  fi
}

function run_umls {
  test_sparql_endpoints
  if [[ -z "${CLEAN}" ]]; then
    echo 'Uploading ontology documents'
    echo -n 'STY... ' \
      && upload_ontology 'http://purl.bioontology.org/ontology/STY/' \
                         "${ONTOLOGY_DIR}/STY.ttl" \
      && echo '✓'
    echo -n 'SNOMEDCT... ' \
      && upload_ontology 'http://purl.bioontology.org/ontology/SNOMEDCT/' \
                         "${ONTOLOGY_DIR}/SNOMEDCT.ttl" \
      && echo '✓'
  else
    echo 'Cleaning UMLS graphs'
    STATUS=$(curl "${SPARQL_ENDPOINT}/update" \
      ${SPARQL_AUTH:+ -u "${SPARQL_AUTH}"} \
      -H "${SPARQL_UPDATE_HEADER}" \
      -so /dev/null \
      -w '%{http_code}' \
      -d @- << SPARQL
      DROP SILENT GRAPH <http://purl.bioontology.org/ontology/STY/>;
      DROP SILENT GRAPH <http://purl.bioontology.org/ontology/SNOMEDCT/>
SPARQL
    )
    if [[ ${STATUS} -ne 200 ]]; then
      failsafe "Encountered error dropping UMLS graphs: $STATUS"
    fi
  fi
}

function run_rml {
  get_rmlmapper
  setup_db_con_str
  java -jar ${RML_JAR} \
       -m ${ROOTDIR}/rml/n2c2-train.ttl \
       -o ${ROOTDIR}/rml-output/n2c2-train.ttl \
       -s turtle \
       -dsn "jdbc:postgres://localhost/${DBNAME}" \
       -u ${USER} \
       -p ${PASS}
}

while getopts ':hlcu:p:d:m:o:s:a:' OPTION; do
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
    o)
      ONTOLOGY_DIR=${OPTARG}
      ;;
    s)
      SPARQL_ENDPOINT=${OPTARG}
      ;;
    l)
      SPARQL_LOAD_LOCAL=yes
      ;;
    a)
      SPARQL_AUTH=${OPTARG}
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
elif [[ 'umls' == ${ACTION} ]]; then
  run_umls
elif [[ 'rml' == ${ACTION} ]]; then
  run_rml
else
  failsafe "Invalid action: ${ACTION}" >&2
fi

cleanup
