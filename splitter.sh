#!/bin/bash
#
# Program: splitter.sh
# Author : Jason Banham
# Date   : 2019-05-17 | 2019-08-29 | 2020-04-29
# Version: 1.05
# Reason : Splits a file into chunks for uploading to Nexenta
# Support:
# Notes  : Expects to be run on a Solaris / Illumos / NexentaOS based system
# History: 1.00 - Initial version
#          1.01 - Now attempts to automatically work out the UUID of the appliance
#          1.02 - Defaults file size to 512m if no argument is supplied
#          1.03 - Added a safety check on free space in dataset 
#          1.04 - Added a new -m <missing_list> switch so we can easily upload just
#                 the missing parts from the split files
#          1.05 - Added a 'no upload' switch for systems not connected to the Internet
#

CURL=/usr/bin/curl
ECHO=/usr/bin/echo
MD5=md5sum
SPLIT=/usr/bin/split

AMER_UPLOAD_URL="ftp://logcollector.nexenta.com"
EMEA_UPLOAD_URL="ftp://logcollector04.nexenta.com"
UPLOAD_URL="$AMER_UPLOAD_URL"
SAVECORE_DIR=$(dumpadm | grep 'Savecore directory' | awk -F':' '{print $2}')

CASE_NUM="unknown"
UUID="unknown"
SIZE="512m"
MISSING="FALSE"
MISSING_FILES=""
MULTIPLY_FACTOR=3	# The multiplication factor based on the filesize for how
                        # much free space we need in the current filesystem
UPLOAD="TRUE"


#
# Usage function, displayed when the wrong number/combination of arguments are
# supplied by the user
#
function usage
{
    $ECHO "Usage: `basename $0` [-h] [-A | -E] [ -n ] [ -u <uuid> ] [ -s <size> ] -c <case_sr> <filename>"
    $ECHO "Usage: `basename $0` [-A | -E] -c <case_sr> -m missing_part1,missing_part2\n"
}

#
# Display the help menu
#
function help
{
    usage
    $ECHO "This script will split a file into a number of chunks, based on a specified size"
    $ECHO "given as an argument." 
    $ECHO "It will then generate an md5 fingerprint of the original file, plus all chunks"
    $ECHO "and then attempt to upload this to either the AMER or EMEA ftp server, which"
    $ECHO "you can also specify as an optional argument.\n"
    $ECHO "Switches explained:\n"
    $ECHO "  -h           : Show this help menu"
    $ECHO "  -A           : Use the AMER ftp server"
    $ECHO "  -E           : Use the EMEA ftp server"
    $ECHO "  -m <missing> : Upload just the missing parts (comma seperated list)"
    $ECHO "  -n           : Do NOT attempt to upload"
    $ECHO "  -s <size>    : Size to split the parts into, eg:"
    $ECHO "                   512m == 512 megabytes"
    $ECHO "                  1024m == 1024 megabytes or 1 gigabyte"
    $ECHO "  -u <uuid>    : The UUID of the Nexenta Appliance"
    $ECHO ""
    $ECHO "Mandatory switches:\n"
    $ECHO "  -c <case_sr> : The Nexenta Case Reference / Service Request number"
    $ECHO ""
    $ECHO "Special case:\n"
    $ECHO "If one or more files went missing, got corrupt or truncated during transfer"
    $ECHO "then you can upload just those parts, using:\n"
    $ECHO "  -m missing_part1,missing_part2"
    $ECHO ""
    $ECHO "Example:\n"
    $ECHO "This will attempt to split the file into 512MB chunks, to the EMEA server"
    $ECHO "using the UUID of 5F7J2FABC and a case (SR) number of 00555010\n"
    $ECHO "`basename $0` -E -s 512m -u 5F7J2FABC -c 00555010 vmdump.0"
    $ECHO "" 
}

#
# Work out the GUID
#
function get_uuid
{
    #
    # This is only on 5.x not 4.x at the time of writing
    #
    if [ -x /usr/nef/cli/sbin/config ]; then
        UUID=$(/usr/nef/cli/sbin/config get -O basic value system.guid | awk '{print $3}')
    fi

    #
    # This should only exist on 3.x and 4.x
    #
    if [ -r /var/lib/nza/nlm.key ]; then
        UUID=$(awk -F'-' '{print $3}' /var/lib/nza/nlm.key)
    fi

    if [ "$UUID" != "unknown" ]; then
        $ECHO "Automatically determind UUID = $UUID"
    fi
}

#
# Do we have enough space available to split this dump in the syspool/rpool ?
# Returns TRUE if there is enough space
# If there is insuffucient space, it returns FALSE
#
function free_space
{
    FILE_SIZE=$(ls -l $1 | awk '{print $5}')
    SPACE_NEEDED=$(echo $FILE_SIZE $MULTIPLY_FACTOR | gawk '{printf("%d", ($1 * $2))}')

    THIS_FS=$(df $PWD | awk -F'(' '{print $2}' | awk -F')' '{print $1}')
    POOL_SPACE=$(zfs get -Hp available $THIS_FS | awk '{print $3}')

    if [ $POOL_SPACE -lt $SPACE_NEEDED ]; then
        echo FALSE
    else
       echo TRUE
    fi
}

#
# Function to upload files
#
function upload_file
{
    part=$1
    uuid=$2
    case=$3
    $ECHO "Uploading $part"
    $CURL -T "$part" "${UPLOAD_URL}/nstor/${uuid}/${case}/${part}" --ftp-create-dirs
}

#
# Sometimes we have files that are missing, corrupt, truncated or have a failed checksum
# on the FTP server.  Those parts need to be re-uploaded from the source system, so 
# this function makes it slightly easier to do this.
#
function process_missing
{
    uuid=$2
    case="$3/missing"
    IFS=", 	"
    for missing_file in $1
    do
        if [ ! -r $missing_file ]; then
            $ECHO "Could not find $missing_file to upload"
            $ECHO "If this is for a kernel dump, have you changed directory to where the parts"
            $ECHO "have been split, for example $SAVECORE_DIR ?"
            $ECHO "Exiting now ..."
            exit 1
        else
            upload_file $missing_file $uuid $case
        fi
    done
}

#
# Generate metadata file
#
function generate_metadata
{
    METAFILE="${1}.meta"
    $ECHO "NUMBER_OF_PARTS: \c" > $METAFILE
    ls ${1}.part* | grep -v md5 | wc -l >> $METAFILE
    $ECHO "### FILESIZE BEGIN ###" >> $METAFILE
    ls -l $1 ${1}.part* | grep -v md5 >> $METAFILE
    $ECHO "### FILESIZE END ###" >> $METAFILE
    $ECHO "### MD5 FINGERPRINT BEGIN ###" >> $METAFILE
    cat *.md5 >> $METAFILE
    $ECHO "### MD5 FINGERPRINT END ###" >> $METAFILE
}


#
# Attempt to automatically work out the system UUID
# If this fails we can still override it using the -u switch
#
get_uuid

#
# Process any arguments here
#
while getopts c:hm:ns:vAEu: argopt
do
        case $argopt in
        A)      UPLOAD_URL="${AMER_UPLOAD_URL}"
                ;;
        c)      CASE_NUM="$OPTARG"
                ;;
        E)      UPLOAD_URL="${EMEA_UPLOAD_URL}"
                ;;
        h)      help
                exit 0
                ;;
        m)      MISSING="TRUE"
                MISSING_FILES="$OPTARG"
                ;;
        n)      UPLOAD="FALSE"
                ;;
        s)      SIZE="$OPTARG"
                ;;
        u)      UUID="$OPTARG"
                ;;
        v)      VERBOSE="TRUE"
                ;;
        esac
done

shift $((OPTIND-1))

if [ "$UUID" == "unknown" -o "$CASE_NUM" == "unknown" ]; then
    $ECHO "Unrecognised UUID or Case Reference number, must exit"
    exit 1
fi

if [ $MISSING == "TRUE" ]; then
    $ECHO "Re-uploading missing files: $MISSING_FILES"
    process_missing "$MISSING_FILES" $UUID $CASE_NUM
    exit 0
fi

INPUT_FILE=$1
if [ "x${INPUT_FILE}" == "x" ]; then
    usage
    exit 1
fi

if [ ! -r $INPUT_FILE ]; then
    $ECHO "Could not find $INPUT_FILE to upload"
    $ECHO "If this is for a kernel dump, have you changed directory to $SAVECORE_DIR ?"
    $ECHO "Exiting now ..."
    exit 1
fi

#
# Check that we have sufficient free space in the given dataset, otherwise
# we could potentially fill up the syspool/rpool leading to an outage
#
$ECHO "Checking for enough free space to split $INPUT_FILE : \c"
if [ $(free_space $INPUT_FILE) == "FALSE" ]; then
    $ECHO "Failed\n"
    $ECHO "Insufficient free space in $THIS_FS to allow splitting $1"
    $ECHO "File size is      : $FILE_SIZE bytes"
    $ECHO "Required space is : $SPACE_NEEDED bytes"
    $ECHO ""
    exit 0
else
    $ECHO "Pass"
fi


$ECHO "\nGenerating md5 fingerprint for ${INPUT_FILE}, this may take a while on large files ..."
$MD5 $INPUT_FILE > ${INPUT_FILE}.md5

$ECHO "Splitting ${INPUT_FILE} into parts ..."
$SPLIT -b $SIZE ${INPUT_FILE} ${INPUT_FILE}.part

$ECHO "Generating md5 fingerprint for all parts: \c"
for part in ${INPUT_FILE}.part[a-z][a-z]
do
    $ECHO "$part \c"
    $MD5 $part > ${part}.md5
done
$ECHO ""

#
# Generate a metadata file containing information about the original file and split parts
#
generate_metadata $INPUT_FILE

if [ $UPLOAD == "TRUE" ]; then
    $ECHO "Uploading all parts and md5 fingerprint files"
    for part in ${INPUT_FILE}.meta ${INPUT_FILE}.md5 ${INPUT_FILE}.part*
    do
        upload_file $part $UUID $CASE_NUM
    done
    $ECHO "\nParts have been uploaded, please consider deleting the following:\n${INPUT_FILE}.md5 ${INPUT_FILE}.part*"
else
    $ECHO "\nParts have been split but not uploaded.\n"
    $ECHO "Please manually upload these to the support portal:\n${INPUT_FILE}.md5 ${INPUT_FILE}.part* ${INPUT_FILE}.meta"
fi

$ECHO "Finished"
