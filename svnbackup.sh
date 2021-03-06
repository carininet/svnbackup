#!/bin/bash

#
# Subversion repository backup script
#
# 15/01/2015 V1.0 - Alessandro Carini
# 19/01/2015 V1.1 - svndumpfile info added in control file
# 31/01/2015 V1.2 - Improved handling of pathname with spaces
# 20/02/2016 V2.0 - Arguments parsed with getopts
# 05/03/2016 V2.1 - Verbose and Very Verbose switch added
# 03/05/2016 V2.2 - Pidfile check added
# 12/09/2016 V2.3 - Bugfix release
# 28/10/2017 V2.4 - Minor fix (pid file left upon error)
# 26/05/2020 V2.5 - Minor fix (error messages printed twice)
#



# -= Functions =-

# display usage message
usage()
{
	cat << __EOF__
Usage: ${MYSELF} <command> [<switches>...] repository

<Commands>
	-h	: Display this message
	-f	: Create full archive backup
	-d	: Create differential backup
	-C	: Build control file *DANGER!*
<Options>
	-b dir	: Override config Use different backupdir
	-v	: Set verbose or very verbose (-vv) mode

<Exit Codes>
	0	: success
	1-63	: internal command error
	64	: command line usage error
	65	: data format error
	70	: internal software error
	73	: can't create (user) output file
	74	: input/output error
	75	: temp failure; please retry
__EOF__

	errormsg=""
	return 0
}

# read control file content
readcontrolfile()
{
	local line=""
	local maxline=15

	cf_repouuid=""
	cf_lastsave=0

	if [[ ! -r "${controlfile}" ]]; then
		errormsg="error: ${controlfile} not found"
		return 65
	fi

	# we need to read the first lines only
	[[ $VERBOSITY -gt 0 ]] && { echo "info: reading control file"; }
	while read -r line
	do
		local cf_line=$(echo "${line}" | awk -F '\\[|\\:|\\]' "/^\[([0-9]|[a-f]|[A-F]|-)+:([0-9])+\]$/ { print \$2 \" \" \$3 }")
		if [[ ! -z "${cf_line}" ]]; then
			read cf_repouuid cf_lastsave <<< ${cf_line}
			[[ $VERBOSITY -gt 2 ]] && { echo "debug: cf_repouuid=${cf_repouuid}, cf_lastsave=${cf_lastsave}"; }
			errormsg=""
			return 0
		fi

		if [[ $(( maxline-=1 )) -le 0 ]]; then
			errormsg="error: ${controlfile} bad format"
			return 65
		fi

	done < "${controlfile}"

	errormsg="error: ${controlfile} read past EOF"
	return 65
}

# read repository status
readrepositorystat()
{
	local result=0

	if [[ ! -r "${REPOSITORY}/format" ]]; then
		errormsg="error: ${REPOSITORY} not a SVN repository"
		return 65
	fi

	svnverify="$(svnadmin verify -q "${REPOSITORY}" 2>&1)"
	if [[ $? -ne 0 ]]; then
		errormsg="error: ${REPOSITORY} invalid SVN repository ${svnverify}"
		return 65
	fi

	# get current timestamp and HEAD revision
	[[ $VERBOSITY -gt 0 ]] && { echo "info: reading repository statistics"; }
	repouuid=$(svnlook uuid "${REPOSITORY}") || { result=$?; errormsg="error: ${repouuid}"; return ${result}; }
	repodate=$(svnlook date "${REPOSITORY}") || { result=$?; errormsg="error: ${repodate}"; return ${result}; }
	repohead=$(svnlook youngest "${REPOSITORY}") || { result=$?; errormsg="error: ${repohead}"; return ${result}; }
	svndumpfile=""
	lastsave=-1

	# define process (.pid) file and control file
	# processfile="/var/lock/${MYSELF}/${repouuid}.pid"
	processfile="${BACKUPDIR}/${repouuid}.pid"
	controlfile="${BACKUPDIR}/${repouuid}.cf"

	[[ $VERBOSITY -gt 2 ]] && { echo "debug: repouuid=${repouuid}, repodate=${repodate}, repohead=${repohead}"; }
	[[ $VERBOSITY -gt 1 ]] && { echo "debug: controlfile is ${controlfile}"; }
	errormsg=""
	return 0
}

# create backup directory
createbackupdir()
{
	local directory="${BACKUPDIR}"
	local result=0

	if [[ ! -z "${method}" ]]; then
		directory="${directory}/${method}"
	fi

	if [[ ! -d "${directory}" ]]; then
		[[ $VERBOSITY -gt 0 ]] && { echo "info: creating backup directory"; }
		errormsg=$(mkdir -p "${directory}") || { result=$?; exit ${result}; }
	fi

	[[ $VERBOSITY -gt 1 ]] && { echo "debug: backup directory is ${directory}"; }
	errormsg=""
	return 0
}

# write .pid file, and return 0 upon success
writepidfile()
{
	local otherpid=-1

	createbackupdir || return $?

	# Check if there is another istance running:
	if [[ -r "${processfile}" ]]; then
		read otherpid < "${processfile}"
		otherproc=$(ps --no-headers --format user,pid,ppid,cmd --pid ${otherpid}) && { errormsg="warning: backup locked by another session pid=${otherpid} otherproc=${otherproc}, please retry later"; return 75; }
		removepid=$(rm -f "${processfile}" 2>/dev/null) || { errormsg="error: can't remove ${processfile} file written by another session"; return 70; }
	fi

	# No other running process found: write pid file and check in lock is succesful
	(echo $$ >> "${processfile}") 2>/dev/null || { errormsg="error: can't write ${processfile}"; return 70; }
	read otherpid < "${processfile}"
	[[ $$ -ne ${otherpid} ]] && { errormsg="warning: can't get lock on ${processfile} owned by process pid=${otherpid}, please retry later"; return 75; }

	return 0
}

# remove .pid file and return 0 upon success
removepidfile()
{
	local otherpid=0

	# Safety check: Can't remove other pid
	read otherpid < "${processfile}"
	[[ $$ -ne ${otherpid} ]] && { errormsg="warning: can't remove ${processfile} owned by process pid=${otherpid}"; return 75; }

	# Remove pid file owned by this session
	removepid=$(rm -f "${processfile}") || { errormsg="error: can't remove ${processfile} file written by another session"; return 70; }

	return 0
}

# write control file
writecontrolfile()
{
	section="[${repouuid}:${repohead}]\nrepodir='${REPOSITORY}'\nsysdate='${sysdate}'\nrepodate='${repodate}'\n"
	if [[ ${lastsave} -ge 0  ]]; then
		section="${section}svndumpfile='${svndumpfile}'\nrevision=${lastsave}:${repohead}\n"
	fi

	createbackupdir || return $?

	[[ $VERBOSITY -gt 0 ]] && { echo "info: writing control file"; }
	errormsg=$(touch "${controlfile}" && echo -e "${section}" > "${controlfile}.tmp" && cat "${controlfile}" >> "${controlfile}.tmp" && mv "${controlfile}.tmp" "${controlfile}") || return $?

	[[ $VERBOSITY -gt 2 ]] && { echo "debug: section=${section}"; }
	errormsg=""
	return 0
}

# write a gzipped dump file
writerepositorydump()
{
	local parameters=""

	if [[ "${method}" = "full" ]]; then
		lastsave=0
		svndumpfile="${BACKUPDIR}/${method}/${repouuid}.${repohead}"
		parameters="-r${lastsave}:${repohead}"
	elif [[ "${method}" = "diff" ]] && [[ "${repouuid}" = "${cf_repouuid}" ]]; then
		lastsave=$(( cf_lastsave+1 ))
		svndumpfile="${BACKUPDIR}/${method}/${repouuid}.${lastsave}-${repohead}"
		parameters="-r${lastsave}:${repohead} --incremental --deltas"
	else
		errormsg="error: internal error"
		return 70
	fi

	# check if dumpfile is already present
	if [[ -r "${svndumpfile}.dump" ]] || [[ -r "${svndumpfile}.dump.gz" ]]; then
		errormsg="warning: file ${svndumpfile} already exist"
		return 73
	elif [[ ${lastsave} -gt ${repohead} ]]; then
		errormsg="warning: revision ${repohead} already saved"
		return 73
	fi

	# create backup directory
	createbackupdir || return $?

	# do actual backup - -err file will be removed at the end
	[[ $VERBOSITY -gt 0 ]] && { echo "info: writing repository dump"; }
	errormsg=$(touch "${svndumpfile}.err") || return $?
	(svnadmin dump -q ${parameters} "${REPOSITORY}" 2>"${svndumpfile}.err" && rm "${svndumpfile}.err") | gzip > "${svndumpfile}.dump.gz" || { errormsg="error compressing ${svndumpfile}.dump.gz"; exit $?; }

	if [[ -e "${svndumpfile}.err" ]]; then
		errormsg=$(cat "${svndumpfile}.err")
		rm "${svndumpfile}.err"
		return 74
	fi

	# check if gzip file is correct
	errormsg=$(gzip -t "${svndumpfile}.dump.gz") || return $?

	[[ $VERBOSITY -gt 1 ]] && { echo "debug: ${svndumpfile}.dump.gz created"; }
	errormsg=""
	return 0
}


# -= Main =-

# Get script name
SCRIPT=$(readlink -nf "${0}")
HOMEDIR=$(dirname "${SCRIPT}")
MYSELF=$(basename "${SCRIPT}" ".${SCRIPT##*.}")

# Get configuration
ARCHIVE="./backup"
if [[ -r "${HOMEDIR}/${MYSELF}.conf" ]]; then
	. "${HOMEDIR}/${MYSELF}.conf"
elif [[ -r "/etc/${MYSELF}.conf" ]]; then
	. "/etc/${MYSELF}.conf"
fi

COMMAND=""
REPOSITORY=""
VERBOSITY=0

# Parse command line
[[ $# -eq 0 ]] && { echo "Type '${MYSELF} -h' for usage."; exit 64; }
while getopts ':hfdCb:v' opt; do
	case "${opt}" in
		'h'|'f'|'d'|'C')
			COMMAND="${opt}${COMMAND}" 
			;;
		'b')
			ARCHIVE="${OPTARG}"
			;;
		'v')
			(( VERBOSITY+=1 ))
			;;
		*)
			echo "Invalid command arguments (${MYSELF} -h for help)"
			exit 64
			;;
	esac
done

# Get pathnames
REPOSITORY=$(dirname "${!OPTIND}/.")
BACKUPDIR="${ARCHIVE}"/$(basename "${REPOSITORY}")

# get sysdate, same format usaed by svn utilities
sysdate=$(date '+%F %T %z (%a, %d %b %Y)')

result=0
pidsts=0
case "${COMMAND}" in
	'h')
		usage; exit 0
		;;
	'f')
		method="full"
		readrepositorystat				|| { result=$?; echo "${errormsg}" >&2; exit ${result}; }
		writepidfile					|| { pidsts=$?; echo "${errormsg}" >&2; exit ${pidsts}; }
		writerepositorydump				|| { result=$?; echo "${errormsg}" >&2; }
		[[ ${result} -eq 0 ]] && { writecontrolfile	|| { result=$?; echo "${errormsg}" >&2; } }
		[[ ${pidsts} -eq 0 ]] && { removepidfile	|| { pidsts=$?; echo "${errormsg}" >&2; } }
		[[ ${result} -eq 0 ]] && { echo "full backup completed"; }
		;;
	'd')
		method="diff"
		readrepositorystat				|| { result=$?; echo "${errormsg}" >&2; exit ${result}; }
		writepidfile					|| { pidsts=$?; echo "${errormsg}" >&2; exit ${pidsts}; }
		readcontrolfile					|| { result=$?; echo "${errormsg}" >&2; }
		[[ ${result} -eq 0 ]] && { writerepositorydump	|| { result=$?; echo "${errormsg}" >&2; } }
		[[ ${result} -eq 0 ]] && { writecontrolfile	|| { result=$?; echo "${errormsg}" >&2; } }
		[[ ${pidsts} -eq 0 ]] && { removepidfile	|| { pidsts=$?; echo "${errormsg}" >&2; } }
		[[ ${result} -eq 0 ]] && { echo "diff backup completed"; }
		;;
	'C')
		readrepositorystat				|| { result=$?; echo "${errormsg}" >&2; exit ${result}; }
		writepidfile					|| { pidsts=$?; echo "${errormsg}" >&2; exit ${pidsts}; }
		[[ ${result} -eq 0 ]] && { writecontrolfile	|| { result=$?; echo "${errormsg}" >&2; } }
		[[ ${pidsts} -eq 0 ]] && { removepidfile	|| { pidsts=$?; echo "${errormsg}" >&2; } }
		[[ ${result} -eq 0 ]] && { echo "control file built"; }
		;;
	*)
		echo "error: command is mandatory (${MYSELF} -h for help)" >&2
		result=64
		pidsts=0
		;;
esac

# If repository read/write is succesful report pid file manipulation error (if any)
[[ ${result} -eq 0 ]] && { exit ${pidsts}; }
exit ${result}

