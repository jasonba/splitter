This script will split a file into a number of chunks, based on a specified size
given as an argument.
It will then generate an md5 fingerprint of the original file, plus all chunks
and then attempt to upload this to either the AMER or EMEA ftp server, which
you can also specify as an optional argument.

Switches explained:

  -h           : Show this help menu
  -A           : Use the AMER ftp server
  -E           : Use the EMEA ftp server
  -m <missing> : Upload just the missing parts (comma seperated list)
  -n           : Do NOT attempt to upload
  -s <size>    : Size to split the parts into, eg:
                   512m == 512 megabytes
                  1024m == 1024 megabytes or 1 gigabyte
  -u <uuid>    : The UUID of the Nexenta Appliance

Mandatory switches:

  -c <case_sr> : The Nexenta Case Reference / Service Request number

Special case:

If one or more files went missing, got corrupt or truncated during transfer
then you can upload just those parts, using:

  -m missing_part1,missing_part2

Example:

This will attempt to split the file into 512MB chunks, to the EMEA server
using the UUID of 5F7J2FABC and a case (SR) number of 00555010

splitter.v105.sh -E -s 512m -u 5F7J2FABC -c 00555010 vmdump.0
