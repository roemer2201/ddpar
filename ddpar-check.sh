#!/bin/bash



# Set the input and output file names
#OUTPUT_PATH=/dev
#OUTPUT_FILE_BASENAME=sdi
#OUTPUT_FILE="${OUTPUT_PATH}/${OUTPUT_FILE_BASENAME}"
#OUTPUT_FILE_TYPE="$(file -b $OUTPUT_FILE)"
BASE_PATH=""
BASE_FILE_NAME=""
NUM_JOBS=4
BLOCKSIZEBYTES=1048576

function show_help {
  SCRIPT_NAME=$(basename "$0")
  echo "$SCRIPT_NAME - Verify consistency of source, backup or destination."
  echo "Verwendung: $SCRIPT_NAME [Optionen]"
  echo ""
  echo "Optionen:"
  echo "-b PATH         Der Basisname (opt. mit Pfad) des geteilten Abbildes"
  echo "-s PATH         Source to compare against"
  echo "-d PATH         Destination to compare against"
  echo "-j NUM          Anzahl der Jobs für den Clone-Check (Default: 4, nur ohne -b)"
  echo "-B NUM          Blockgröße in Bytes für den Clone-Check (Default: 1048576, nur ohne -b)"
  echo "-h, --help      Zeigt diese Hilfemeldung an"
}

function check_restored_image {
  for ((i=0; i<$NUM_JOBS; i++)); do
    START=$((i * SPLIT_SIZE))
    echo "dd if=$OUTPUT_FILE bs=$BLOCKSIZEBYTES count=$((SPLIT_SIZE / $BLOCKSIZEBYTES)) skip=$((START / BLOCKSIZEBYTES)) status=none | sha256sum -c $BASE_FILES$i.sha256 | sed s#-#$BASE_FILES$i# &"
    dd if=$OUTPUT_FILE bs=$BLOCKSIZEBYTES count=$((SPLIT_SIZE / $BLOCKSIZEBYTES)) skip=$((START / BLOCKSIZEBYTES)) status=none | sha256sum -c $BASE_FILES$i.sha256 | sed s#-#$BASE_FILES$i# &
  done
}

function check_backuped_image {
  for ((i=0; i<$NUM_JOBS; i++)); do
    START=$((i * SPLIT_SIZE))
    echo "dd if=$INPUT_FILE bs=$BLOCKSIZEBYTES count=$((SPLIT_SIZE / $BLOCKSIZEBYTES)) skip=$((START / BLOCKSIZEBYTES)) status=none | sha256sum -c $BASE_FILES$i.sha256 | sed s#-#$BASE_FILES$i# &"
    dd if=$INPUT_FILE bs=$BLOCKSIZEBYTES count=$((SPLIT_SIZE / $BLOCKSIZEBYTES)) skip=$((START / BLOCKSIZEBYTES)) status=none | sha256sum -c $BASE_FILES$i.sha256 | sed s#-#$BASE_FILES$i# &
  done
}

function check_cloned_image {
  # Vergleicht Quelle und Ziel eines Clones segmentweise und parallel.
  # Es existieren keine .sha256-Dateien, daher werden die Hashes beider
  # Seiten direkt berechnet und verglichen.
  for ((i=0; i<NUM_JOBS; i++)); do
    START=$((i * SPLIT_SIZE))
    COUNT=$((SPLIT_SIZE / BLOCKSIZEBYTES))
    SKIP=$((START / BLOCKSIZEBYTES))
    (
      HASH_SRC=$(dd if="$SOURCE" bs="$BLOCKSIZEBYTES" count="$COUNT" skip="$SKIP" status=none | sha256sum | cut -d' ' -f1)
      HASH_DST=$(dd if="$DESTINATION" bs="$BLOCKSIZEBYTES" count="$COUNT" skip="$SKIP" status=none | sha256sum | cut -d' ' -f1)
      if [ "$HASH_SRC" = "$HASH_DST" ]; then
        echo "Segment $i: OK ($HASH_SRC)"
      else
        echo "Segment $i: MISMATCH (src=$HASH_SRC, dst=$HASH_DST)"
      fi
    ) &
  done
  wait
}

# Verwendung von getopts zur Verarbeitung der Optionen
while getopts ":b:s:d:j:B:h" opt; do
  case $opt in
    b)
      BASE_PATH=$(dirname $(realpath "$OPTARG")); echo "Set BASE_PATH=${BASE_PATH}"
      BASE_FILE_NAME=$(basename $(realpath "$OPTARG")); echo "Set BASE_FILE_NAME=${BASE_FILE_NAME}"
      ;;
#    n) echo "Set BASE_FILE_NAME=$OPTARG"; BASE_FILE_NAME="$OPTARG";; # Not needed anymore due to combined b ( = p + n )
    s) echo "Set SOURCE=$OPTARG"; SOURCE="$OPTARG" ;;
    d) echo "Set DESTINATION=$OPTARG"; DESTINATION="$OPTARG" ;;
    j) echo "Set NUM_JOBS=$OPTARG"; NUM_JOBS="$OPTARG" ;;
    B) echo "Set BLOCKSIZEBYTES=$OPTARG"; BLOCKSIZEBYTES="$OPTARG" ;;
    h|-help) show_help; exit 0;;
    \?) echo "Ungültige Option: -$OPTARG";;
  esac
done

# Überprüfung der erforderlichen Parameter
# Extend the check to be able to compare one of source <-> backup, backup <-> destination, source <-> destination,
# by making sure, that only 2 out of those 3 parameters are set.
# Currently only backup <-> destination works.

# Check if only one of the three variables is set
if { [ -n "$SOURCE" ] && [ -z "$BASE_PATH" ] && [ -z "$DESTINATION" ]; } \
|| { [ -z "$SOURCE" ] && [ -n "$BASE_PATH" ] && [ -z "$DESTINATION" ]; } \
|| { [ -z "$SOURCE" ] && [ -z "$BASE_PATH" ] && [ -n "$DESTINATION" ]; }; then
  echo "Only one of the three variables is set."
  exit 1
fi

# Check if none of the three variables is set
if [ -z "$SOURCE" ] && [ -z "$BASE_PATH" ] && [ -z "$DESTINATION" ]; then
  echo "None of the three variables is set."
  exit 1
fi

# Check if all three variables are set
if [ -n "$SOURCE" ] && [ -n "$BASE_PATH" ] && [ -n "$DESTINATION" ]; then
  echo "All three variables are set. The loop will not be executed."
fi

# Create spinoff variables
if [ ! -z "${BASE_PATH}" ]; then 
  BASE_FILES="${BASE_PATH}/${BASE_FILE_NAME}-"
  METADATA_FILE="${BASE_FILES}metadata.txt"
  
  # Get parameters from metadata file
  NUM_JOBS=$(grep "NUM_JOBS" $METADATA_FILE | cut -d "=" -f 2)
  SPLIT_SIZE=$(grep "SPLIT_SIZE" $METADATA_FILE | cut -d "=" -f 2)
  BASE_FILE_TYPE=$(grep "FILE_TYPE" $METADATA_FILE | cut -d "=" -f 2)
  BLOCKSIZEBYTES=$(grep "BLOCKSIZEBYTES" $METADATA_FILE | cut -d "=" -f 2)
  
  # Debug Info:
  echo ${BASE_PATH}
  echo ${BASE_FILE_NAME}
  echo ${BASE_FILES}\*
fi
if [ ! -z "$SOURCE" ]; then
  INPUT_FILE=$SOURCE
  INPUT_FILE_TYPE="$(file -b $SOURCE)"
fi
if [ ! -z "$DESTINATION" ]; then
OUTPUT_FILE=$DESTINATION
OUTPUT_FILE_TYPE="$(file -b $DESTINATION)"
fi


# Old Debug Info, can be removed
#echo "BASE_FILE_TYPE: ${BASE_FILE_TYPE}"
#echo "DESTINATION: $DESTINATION"
#echo "OUTPUT_FILE: ${OUTPUT_FILE}"
#echo "OUTPUT_FILE_TYPE: ${OUTPUT_FILE_TYPE}"

if [ ! -z "$SOURCE" ] && [ ! -z "$BASE_PATH" ] && [ -z "$DESTINATION" ]; then
  echo "Comparing Source $SOURCE with $BASE_PATH ..."
fi

# Check if only $SOURCE and $BASE_PATH are set
if [ -n "$SOURCE" ] && [ -n "$BASE_PATH" ] && [ -z "$DESTINATION" ]; then
  echo "In the loop: Comparing Source $SOURCE with Base Path $BASE_PATH ..."

  if [[ "${BASE_FILE_TYPE}" == "block special"* ]] && [[ "${INPUT_FILE_TYPE}" == "block special"* ]]; then
    echo "Beginning to check ..."
    check_backuped_image
  fi
  if [[ "${BASE_FILE_TYPE}" != "block special"* ]] && [[ "${INPUT_FILE_TYPE}" != "block special"* ]]; then
    echo "Beginning to check ..."
    check_backuped_image
  fi
fi

# Check if only $BASE_PATH and $DESTINATION are set
if [ -z "$SOURCE" ] && [ -n "$BASE_PATH" ] && [ -n "$DESTINATION" ]; then
  echo "In the loop: Comparing Base Path $BASE_PATH with Destination $DESTINATION ..."

  if [[ "${BASE_FILE_TYPE}" == "block special"* ]] && [[ "${OUTPUT_FILE_TYPE}" == "block special"* ]]; then
    echo "Beginning to check ..."
    check_restored_image
  fi
  if [[ "${BASE_FILE_TYPE}" != "block special"* ]] && [[ "${OUTPUT_FILE_TYPE}" != "block special"* ]]; then
    echo "Beginning to check ..."
    check_restored_image
  fi

fi

# Check if only $SOURCE and $DESTINATION are set (Clone-Check)
if [ -n "$SOURCE" ] && [ -z "$BASE_PATH" ] && [ -n "$DESTINATION" ]; then
  echo "In the loop: Comparing Source $SOURCE with Destination $DESTINATION ..."

  # Größe der Quelle bestimmen (kein Metadatenfile vorhanden)
  if [[ "${INPUT_FILE_TYPE}" == "block special"* ]]; then
    INPUT_SIZE=$(blockdev --getsize64 "$SOURCE")
  else
    INPUT_SIZE=$(stat -c %s "$SOURCE")
  fi
  SPLIT_SIZE=$((INPUT_SIZE / NUM_JOBS))

  # Teilbarkeit prüfen, damit kein Bereich übersprungen oder doppelt gelesen wird
  if [ $((INPUT_SIZE % NUM_JOBS)) -ne 0 ] || [ $((SPLIT_SIZE % BLOCKSIZEBYTES)) -ne 0 ]; then
    echo "Fehler: Quellgröße ($INPUT_SIZE) ist nicht glatt durch NUM_JOBS ($NUM_JOBS) und BLOCKSIZEBYTES ($BLOCKSIZEBYTES) teilbar."
    echo "Bitte -j und/oder -B passend zum ursprünglichen Clone-Aufruf wählen."
    exit 1
  fi

  echo "Beginning to check ..."
  check_cloned_image
fi


wait
