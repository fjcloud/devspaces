#!/bin/bash
#
# Copyright (c) 2018-2022 Red Hat, Inc.
# This program and the accompanying materials are made
# available under the terms of the Eclipse Public License 2.0
# which is available at https://www.eclipse.org/legal/epl-2.0/
#
# SPDX-License-Identifier: EPL-2.0
#

# script to query latest tags for a given list of imags in RHEC
# REQUIRES: 
#    * brew for OSBS queries, 
#    * skopeo >=1.1 (for authenticated registry queries, and to use --override-arch for s390x images)
#    * jq to do json queries
#    * yq to do yaml queries (install the python3 wrapper for jq using pip)
# 
# https://registry.redhat.io is v2 and requires authentication to query, so login in first like this:
# docker login registry.redhat.io -u=USERNAME -p=PASSWORD

# try to compute branches from currently checked out branch; else fall back to hard coded value
DWNSTM_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"

getVersion() {
	VERSION=""
	if [[ -f dependencies/job-config.json ]]; then
		jcjson=dependencies/job-config.json
	else
		jcjson=/tmp/job-config.json
		curl -sSLo $jcjson https://raw.githubusercontent.com/redhat-developer/devspaces/devspaces-3-rhel-8/dependencies/job-config.json
	fi
	VERSION=$(jq -r '.Version' $jcjson)
}
getVersion
# echo "VERSION=$VERSION"

getDsVersion ()
{
	if [[ $DWNSTM_BRANCH != "devspaces-3."*"-rhel-8" ]] && [[ $DWNSTM_BRANCH != "devspaces-3-rhel-8" ]]; then
		if [[ ${VERSION} != "" ]]; then
			DWNSTM_BRANCH="devspaces-${VERSION}-rhel-8"
		else 
			DWNSTM_BRANCH="devspaces-3-rhel-8"
			VERSION="3.x"
		fi
	else
		DS_VERSION=${DWNSTM_BRANCH/devspaces-/}; DS_VERSION=${DS_VERSION/-rhel-8/}
		if [[ $DS_VERSION == 2 ]] || [[ $DS_VERSION == 3 ]]; then # invalid version
			if [[ ${VERSION} ]]; then # use version from VERSION file
				DS_VERSION=${VERSION}
			else # set placeholder version 3.y
				DS_VERSION="3.y"
			fi
		fi
	fi
}
getDsVersion

command -v skopeo >/dev/null 2>&1 || which skopeo >/dev/null 2>&1 || { echo "skopeo is not installed. Aborting."; exit 1; }
command -v jq >/dev/null 2>&1     || which jq >/dev/null 2>&1     || { echo "jq is not installed. Aborting."; exit 1; }
command -v yq >/dev/null 2>&1     || which yq >/dev/null 2>&1     || { echo "yq is not installed. Aborting."; exit 1; }
checkVersion() {
  if [[  "$1" = "$(echo -e "$1\n$2" | sort -V | head -n1)" ]]; then
    # echo "[INFO] $3 version $2 >= $1, can proceed."
	true
  else 
    echo "[ERROR] Must install $3 version >= $1"
    exit 1
  fi
}
checkVersion 1.1 "$(skopeo --version | sed -e "s/skopeo version //")" skopeo

DS_CONTAINERS="\
devspaces/code-rhel8 \
devspaces/configbump-rhel8 \
devspaces/devspaces-rhel8-operator \
devspaces/devspaces-operator-bundle \
devspaces/dashboard-rhel8 \
devspaces/devfileregistry-rhel8 \
\
devspaces/idea-rhel8 \
devspaces/imagepuller-rhel8 \
devspaces/machineexec-rhel8 \
devspaces/pluginregistry-rhel8 \
devspaces/server-rhel8 \
\
devspaces/traefik-rhel8 \
devspaces/udi-rhel8 \
"

# regex pattern of container tags to exclude, eg., latest and -source; also exclude images generated by PR or temporary builds used for publishing assets
# CRW-4615 exclude new sha256-[0-9a-f]+.sbom tags in OSBS
EXCLUDES="latest|\\-source|-pr-|-tmp-|-ci-|-gh-|sha256-.+.sbom" 
EXCLUDES_FRESHMAKER="[0-9]+\.[0-9]+-[0-9]*\.[0-9]{10}" # if set, exclude x.yy-zz.freshmakertimestamp tags; if 1; include them

QUIET=1 	# less output - omit container tag URLs
VERBOSE=0	# more output
ERRATA_NUM=""  # if set, update errata with latest NVRs
HIDE_MISSING=0 # if 0, show repo/org/image:??? for missing tags; if 1, don't show anything if tag missing
ARCHES=0	# show architectures
NUMTAGS=1 	# by default show only the latest tag for each container; or show n latest ones
TAGONLY=0 	# by default show the whole image or NVR; if true, show ONLY tags
SHOWHISTORY=0 # compute the base images defined in the Dockerfile's FROM statement(s): NOTE: requires that the image be pulled first 
SHOWNVR=0 	# show NVR format instead of repo/container:tag format
SHOWLOG=0 	# show URL of the console log
PUSHTOQUAY=0 # utility method to pull then push to quay
PUSHTOQUAYTAGS="" # utility method to pull then push to quay (extra tags to push)
PUSHTOQUAYFORCE=0 # normally, don't repush a tag if it's already in the registry (to avoid re-timestamping it and updating tag history)
SORTED=0 # if 0, use the order of containers in the DS*_CONTAINERS_* strings above; if 1, sort alphabetically
latestNext="latest"; if [[ $DS_VERSION == "3.y" ]] || [[ $DWNSTM_BRANCH == "devspaces-3-rhel-8" ]]; then latestNext="next  "; fi

# cleanup /tmp files
cleanup_temp () {
	rm -fr /tmp/job-config.json || true
}

usage () {
	getVersion
	getDsVersion

	# compute default errata num for use with --errata flag
	DEFAULT_ERRATA_NUM=$(jq -r --arg VERSION "${VERSION}" '.Other.Errata[$VERSION]' $jcjson)
	if [[ $DEFAULT_ERRATA_NUM == "" ]] || [[ $DEFAULT_ERRATA_NUM == "null" ]] || [[ $DEFAULT_ERRATA_NUM == "n/a" ]]; then 
		if [[ $VERSION =~ ^([0-9]+)\.([0-9]+) ]]; then # reduce the z digit, remove the snapshot suffix
			XX=${BASH_REMATCH[1]}
			YY=${BASH_REMATCH[2]}
			let YY=YY-1 || YY=0; if [[ $YY -lt 0 ]]; then YY=0; fi # if result of a let == 0, bash returns 1
			VERSION_PREV="${XX}.${YY}"
			# echo "VERSION_PREV=$VERSION_PREV"
		fi
		DEFAULT_ERRATA_NUM=$(jq -r --arg VERSION_PREV "${VERSION_PREV}" '.Other.Errata[$VERSION_PREV]' $jcjson)
	fi
	if [[ $DEFAULT_ERRATA_NUM == "" ]] || [[ $DEFAULT_ERRATA_NUM == "null" ]] || [[ $DEFAULT_ERRATA_NUM == "n/a" ]]; then 
		DEFAULT_ERRATA_NUM="99999"
	fi

	echo "
Usage: 
  $0 -b ${DWNSTM_BRANCH} --nvr --log                       | check images in brew; output NVRs can be copied to Errata; show Brew builds/logs
  $0 -b ${DWNSTM_BRANCH} --errata $DEFAULT_ERRATA_NUM                   | check images in brew; output NVRs; push builds to Errata (implies --nvr --hide)

  $0 -b ${DWNSTM_BRANCH} --quay --tag \"${DS_VERSION}-\" --hide        | use default quay.io/devspaces images, for tag ${DS_VERSION}-; show nothing if unmatched tag
  $0 -b ${DWNSTM_BRANCH} --osbs                            | check images in OSBS ( registry-proxy.engineering.redhat.com/rh-osbs )
  $0 -b ${DWNSTM_BRANCH} --osbs --pushtoquay='${DS_VERSION} ${latestNext}'  | pull images from OSBS, push ${DS_VERSION}-z tag + 2 extras to quay
  $0 -b ${DWNSTM_BRANCH} --stage --sort                    | use default list of DS images in RHEC Stage, sorted alphabetically
  $0 -b ${DWNSTM_BRANCH} --arches                          | use default list of DS images in RHEC Prod; show arches

  $0 -c devspaces/iib --quay -o v4.12 --tag ${DS_VERSION}-v4.12          | search for latest Dev Spaces IIBs in quay for a given OCP version
  $0 -c devspaces/code-rhel8 --quay                            | check latest tag for specific Quay image(s), with branch = ${DWNSTM_BRANCH}
  $0 -c devspaces-operator --osbs                              | check an image from OSBS
  $0 -c devspaces-devspaces-rhel8-operator --nvr               | check an NVR from OSBS
  $0 -c ubi7-minimal -c ubi8-minimal --osbs -n 3 --tag .       | check OSBS registry; show all tags; show 3 tags per container
  $0 -c 'devtools/go-toolset-rhel7 ubi7/go-toolset' --tag 1.1* | check RHEC prod registry; show 1.1* tags (exclude latest and -sources)
  $0 -c pivotaldata/centos --docker --dockerfile               | check docker registry; show Dockerfile contents (requires dfimage)
"
}
if [[ $# -lt 1 ]]; then usage; cleanup_temp; exit 1; fi

REGISTRY="https://registry.redhat.io" # or https://brew-pulp-docker01.web.prod.ext.phx2.redhat.com:8888 or https://registry-1.docker.io or https://registry.access.redhat.com
CONTAINERS=""
while [[ "$#" -gt 0 ]]; do
  case $1 in
    '-j') DS_VERSION="$2"; DWNSTM_BRANCH="devspaces-${DS_VERSION}-rhel-8"; shift 1;;
    '-b') DWNSTM_BRANCH="$2"; shift 1;; 
    '-c') CONTAINERS="${CONTAINERS} $2"; shift 1;;
    '-x') EXCLUDES="$2"; shift 1;;
    '-q') QUIET=1;;
    '-v') QUIET=0; VERBOSE=1;;
    '--hide') HIDE_MISSING=1;;
    '--freshmaker') EXCLUDES_FRESHMAKER="";; # CRW-2499 by default, exclude freshmaker-built images
    '-a'|'--arches') ARCHES=1;;
    '-r') REGISTRY="$2"; shift 1;;
    '--rhec'|'--rhcc') REGISTRY="https://registry.redhat.io";;
    '--stage') REGISTRY="https://registry.stage.redhat.io";;
    '--pulp-old') REGISTRY="https://brew-pulp-docker01.web.prod.ext.phx2.redhat.com:8888"; EXCLUDES="latest|candidate|guest|containers|sha256-.+.sbom";;
    '-p'|'--osbs') REGISTRY="https://registry-proxy.engineering.redhat.com/rh-osbs"; EXCLUDES="latest|candidate|guest|containers|sha256-.+.sbom";;
    '-d'|'--docker') REGISTRY="https://docker.io";;
    '--quay') REGISTRY="https://quay.io";;
    '--pushtoquay') PUSHTOQUAY=1; PUSHTOQUAYTAGS="";;
    --pushtoquay=*) PUSHTOQUAY=1; PUSHTOQUAYTAGS="$(echo "${1#*=}")";;
    '--pushtoquayforce') PUSHTOQUAYFORCE=1;;
	'--latestNext') latestNext="$2"; shift 1;;
	# since we have no next or latest tags for IIB images, append an OCP version and arch and filter for those by default
	'-o')
		if [[ $DWNSTM_BRANCH != "devspaces-3-rhel-8" ]] || [[ $DS_VERSION != "3.y" ]]; then 
			latestNext="latest-$2-$(uname -m)"
		else
			latestNext="next-$2-$(uname -m)"
		fi
		BASETAG="$2"; shift 1;;
    '-n') NUMTAGS="$2"; shift 1;;
    '--dockerfile') SHOWHISTORY=1;;
    '--tag') BASETAG="$2"; shift 1;;
    '--candidatetag') candidateTag="$2"; shift 1;;
    '--nvr')    if [[ ! $CONTAINERS ]]; then CONTAINERS="${DS_CONTAINERS}"; fi; SHOWNVR=1;;
    '--errata') if [[ ! $CONTAINERS ]]; then CONTAINERS="${DS_CONTAINERS}"; fi; SHOWNVR=1; ERRATA_NUM="$2"; HIDE_MISSING=1; shift 1;;
    '--tagonly') TAGONLY=1;;
    '--log') SHOWLOG=1;;
    '--sort') SORTED=1;;
    '-h'|'--help') usage; cleanup_temp; exit 1;;
  esac
  shift 1
done

if [[ $CONTAINERS == *"devspaces/iib"* ]]; then
	if [[ $latestNext == "latest" ]] || [[ $latestNext == "next  " ]]; then
		echo "[ERROR] For Quay IIB searches, must specify OCP version. For example: '-o v4.12'"; usage; cleanup_temp; exit 2
	fi
fi

# null for osbs and others; only need this for quay repo when we might not have a :latest tag (but do have a :next one)
searchTag=""

# echo "DWNSTM_BRANCH = $DWNSTM_BRANCH"
# tag to search for in quay
if [[ -z ${BASETAG} ]] && [[ ${DWNSTM_BRANCH} ]]; then
	BASETAG=${DWNSTM_BRANCH#*-}
	BASETAG=${BASETAG%%-*}
	# since now using extended grep, add \ before the . so it only matches ., not anything
	BASETAG=${BASETAG//\./\\.}
elif [[ "${BASETAG}" ]]; then # if --tag flag used, don't use derived value or fail
	true
else
	usage; cleanup_temp; exit 3
fi
if [[ -z ${candidateTag} ]] && [[ ${DWNSTM_BRANCH} ]]; then
	candidateTag="${DWNSTM_BRANCH}-container-candidate"
else
	usage; cleanup_temp; exit 4
fi

if [[ $VERBOSE -eq 1 ]]; then 
	echo "[DEBUG] DS_VERSION=${DS_VERSION}"
	echo "[DEBUG] DWNSTM_BRANCH = ${DWNSTM_BRANCH}"
	echo "[DEBUG] BASETAG = $BASETAG"
	echo "[DEBUG] candidateTag = $candidateTag"
	echo "[DEBUG] containers = $CONTAINERS"
	echo "[DEBUG] latestNext = $latestNext"
fi

if [[ ${REGISTRY} != "" ]]; then 
	REGISTRYSTRING="--registry ${REGISTRY}"
	REGISTRYPRE="${REGISTRY##*://}/"
	if [[ ${REGISTRY} == *"registry-proxy.engineering.redhat.com"* ]]; then
		if [[ ${CONTAINERS} == "" ]] || [[ ${CONTAINERS} == "${DS_CONTAINERS}" ]]; then 
			CONTAINERS="${DS_CONTAINERS}"; CONTAINERS=${CONTAINERS//devspaces-3-rhel8-/}; CONTAINERS="${CONTAINERS//devspaces\//devspaces-}"
			CONTAINERS="${CONTAINERS//devspaces-devspaces/devspaces}"
			CONTAINERS="${CONTAINERS/devspaces-rhel8-operator/devspaces-operator}"
		fi
	elif [[ ${REGISTRY} == *"quay.io"* ]]; then
		searchTag=":${latestNext}"
		if [[ ${CONTAINERS} == "${DS_CONTAINERS}" ]] || [[ ${CONTAINERS} == "" ]]; then
			CONTAINERS="${DS_CONTAINERS}"; 
		fi
	elif [[ ! ${CONTAINERS} ]]; then
		CONTAINERS="${DS_CONTAINERS}"
	fi
else
	REGISTRYSTRING=""
	REGISTRYPRE=""
fi
if [[ $VERBOSE -eq 1 ]]; then 
	echo "[DEBUG] REGISTRYSTRING = $REGISTRYSTRING"
	echo "[DEBUG] REGISTRYPRE = $REGISTRYPRE"
fi

# see https://hub.docker.com/r/laniksj/dfimage
if [[ $SHOWHISTORY -eq 1 ]]; then
	if [[ ! $(docker images | grep  laniksj/dfimage) ]]; then 
		echo "Installing dfimage ..."
		docker pull laniksj/dfimage 2>&1
	fi
fi

if [[ ${CONTAINERS} == "" ]]; then usage; cleanup_temp; exit 5; fi

# sort the container list
if [[ $SORTED -eq 1 ]]; then CONTAINERS=$(tr ' ' '\n' <<< "${CONTAINERS}" | sort | uniq); fi

# special case!
if [[ ${SHOWNVR} -eq 1 ]]; then 
	# install errata-tool python lib
	if [[ $ERRATA_NUM ]]; then
		pip install errata-tool -q || true
	fi
	if [[ ! -x /usr/bin/brew ]]; then 
		echo "Brew is required. Please install brewkoji rpm from one of these repos:";
		echo " * https://download.devel.redhat.com/rel-eng/RCMTOOLS/latest-RCMTOOLS-2-F-27/compose/Everything/x86_64/os/"
		echo " * https://download.devel.redhat.com/rel-eng/RCMTOOLS/latest-RCMTOOLS-2-RHEL-8/compose/BaseOS/\$basearch/os/"
		exit 1
	fi

	c=0 # containers total
	n=0 # containers found
	for containername in ${CONTAINERS}; do
		(( c = c + 1 ))
		# NEW: devspaces/devspaces-operator-bundle -> devspaces-operator-bundle
		# NEW: devspaces/devspaces-rhel8-operator  -> devspaces-rhel8-operator
		containername="${containername/devspaces-/}"
		if [[ ${VERBOSE} -eq 1 ]]; then
			# shellcheck disable=SC2028
			if [[ $EXCLUDES_FRESHMAKER ]]; then
				echo "brew list-tagged ${candidateTag} | grep \"${containername/\//-}-container\" | grep -E -v \"${EXCLUDES_FRESHMAKER}\" | sort -V | tail -${NUMTAGS} | sed -e \"s#[\ \t]\+${candidateTag}.\+##\""
			else
				echo "brew list-tagged ${candidateTag} | grep \"${containername/\//-}-container\" | sort -V | tail -${NUMTAGS} | sed -e \"s#[\ \t]\+${candidateTag}.\+##\""
			fi
		fi
		result="$(brew list-tagged ${candidateTag} | grep "${containername/\//-}-container" | sort -V)"
		if [[ $EXCLUDES_FRESHMAKER ]]; then
			result="$(echo "$result" | grep -E -v "${EXCLUDES_FRESHMAKER}")"
		fi
		if [[ ${SHOWLOG} -eq 1 ]]; then
			result=$(echo "$result" | tail -${NUMTAGS} | sed -E -e "s#[\ \t]+${candidateTag}.+##" | \
				sed -E -e "s#(.+)-container-([0-9.]+)-([0-9]+)#\0 - https://download.eng.bos.redhat.com/brewroot/packages/\1-container/\2/\3/data/logs/x86_64.log#")
		elif [[ ${TAGONLY} -eq 1 ]]; then
			result=$(echo "$result" | tail -${NUMTAGS} | sed -E -e "s#[\ \t]+${candidateTag}.+##" -e "s@.+-container-@@g")
		else
			result=$(echo "$result" | tail -${NUMTAGS} | sed -E -e "s#[\ \t]+${candidateTag}.+##")
		fi
		if [[ $result ]]; then
			echo $result
			(( n = n + 1 ))
			if [[ $ERRATA_NUM ]]; then
				prodver="RHOSDS-3-RHEL-8"
				if [[ $DS_VERSION == "2"* ]]; then prodver="CRW-2.0-RHEL-8"; fi
				# see API info in https://github.com/red-hat-storage/errata-tool/tree/master/errata_tool
				cat <<EOT >> /tmp/errata-container-update-$result
from errata_tool import Erratum
e = Erratum(errata_id=$ERRATA_NUM)
e.setState('NEW_FILES')
e.commit()
e.addBuilds('$result', release='$prodver', file_types={'$result': ['tar']})
# print (e.errata_builds)
EOT
				python /tmp/errata-container-update-$result
				rm -f /tmp/errata-container-update-$result
			fi
		elif [[ $HIDE_MISSING -eq 0 ]]; then
			echo "${containername/\//-}-container-???"
		fi
	done
	if [[ $c -gt 4 ]] && [[ $c -gt $n ]] && [[ $HIDE_MISSING -eq 0 ]]; then echo; echo "Found $n of $c containers"; fi
	exit
fi

c=0 # containers total
n=0 # containers found
for URLfrag in $CONTAINERS; do
	(( c = c + 1 ))
	(( n = n + 1 ))
	URLfragtag=${URLfrag##*:}
	if [[ ${URLfragtag} == "${URLfrag}" ]]; then # tag appended on url
		URL="https://access.redhat.com/containers/?tab=tags#/registry.access.redhat.com/${URLfrag}"
		URLfragtag="^-"
	else
		URL="https://access.redhat.com/containers/?tab=tags#/registry.access.redhat.com/${URLfrag%%:*}"
		URLfragtag="^- ${URLfragtag}"
	fi

	ARCH_OVERRIDE="--override-arch amd64" 
	# optional override so that an image without amd64 won't return a failure when searching on amd64 arch machines
	if [[ ${URLfrag} == *"-openj9"* ]]; then
		ARCH_OVERRIDE="--override-arch s390x"
	fi

	# shellcheck disable=SC2001
	QUERY="$(echo "$URL" | sed -e "s#.\+\(registry.redhat.io\|registry.access.redhat.com\)/#skopeo inspect ${ARCH_OVERRIDE} docker://${REGISTRYPRE}#g")${searchTag}"
	if [[ $VERBOSE -eq 1 ]]; then 
		echo ""; echo -n "LATESTTAGs=\"\$($QUERY | jq -r .RepoTags[] | grep -E -v '${EXCLUDES}' | grep -E -w '${BASETAG}' | sort -V)\"; "
	fi
	LATESTTAGs="$(${QUERY} 2>/dev/null | jq -r .RepoTags[] | grep -E -v "${EXCLUDES}" | grep -E -w "${BASETAG}" | sort -V)"
	if [[ ! ${LATESTTAGs} ]]; then # try again with -container suffix
		QUERY="$(echo "${URL}-container" | sed -e "s#.\+\(registry.redhat.io\|registry.access.redhat.com\)/#skopeo inspect ${ARCH_OVERRIDE} docker://${REGISTRYPRE}#g")"
		if [[ $VERBOSE -eq 1 ]]; then 
		    echo ""; echo -n "LATESTTAGs=\"\$($QUERY | jq -r .RepoTags[] | grep -E -v '${EXCLUDES}' | grep -E -w '${BASETAG}' | sort -V)\"; " 
		fi
		LATESTTAGs="$(${QUERY} 2>/dev/null | jq -r .RepoTags[] | grep -E -v "${EXCLUDES}" | grep -E -w "${BASETAG}" | sort -V)"
	fi

	# exclude freshmaker containers and/or sort and grab only the last n tags
	if [[ $EXCLUDES_FRESHMAKER ]]; then
		if [[ $VERBOSE -eq 1 ]]; then 
		    echo "echo \"\$LATESTTAGs\" | grep -E -v \"${EXCLUDES_FRESHMAKER}\" | tail -5" 
		fi
		LATESTTAGs="$(echo "$LATESTTAGs" | grep -E -v "${EXCLUDES_FRESHMAKER}" | tail -${NUMTAGS})"
	else 
		if [[ $VERBOSE -eq 1 ]]; then 
		    echo "echo \"\$LATESTTAGs\" | tail -5" 
		fi
		LATESTTAGs="$(echo "$LATESTTAGs" | tail -${NUMTAGS})"
	fi

	if [[ ! ${LATESTTAGs} ]]; then
		nocontainer=${QUERY##*docker://}; nocontainer=${nocontainer%%-container}
		(( n = n - 1 ))
		if [[ $QUIET -eq 0 ]] || [[ $VERBOSE -eq 1 ]]; then 
			echo "[ERROR] No tags matching ${BASETAG} found for $nocontainer or ${nocontainer}-container. Is the container public and populated?"
		elif [[ $HIDE_MISSING -eq 0 ]]; then
			echo "${nocontainer}:???"
		fi
	fi
	for LATESTTAG in ${LATESTTAGs}; do
		if [[ "$REGISTRY" = *"registry.access.redhat.com"* ]]; then
			if [[ $QUIET -eq 1 ]]; then
				echo "${URLfrag%%:*}:${LATESTTAG}"
			elif [[ ${TAGONLY} -eq 1 ]]; then
				echo "${LATESTTAG}"
			else
				echo "* ${URLfrag%%:*}:${LATESTTAG} :: https://access.redhat.com/containers/#/registry.access.redhat.com/${URLfrag}/images/${LATESTTAG}"
			fi
		elif [[ "${REGISTRY}" != "" ]]; then
			if [[ $ARCHES -eq 1 ]]; then
				arches=""
				arch_string=""
				raw_inspect=$(skopeo inspect --raw docker://${REGISTRYPRE}${URLfrag%%:*}:${LATESTTAG})
				if [[ $(echo "${raw_inspect}" | grep "architecture") ]]; then 
					arches=$(echo $raw_inspect | yq -r .manifests[].platform.architecture)
				else
					arches="unknown (amd64 only?)"
				fi
				for arch in $arches; do arch_string="${arch_string} ${arch}"; done
				echo "${REGISTRYPRE}${URLfrag%%:*}:${LATESTTAG} ::${arch_string}"
			elif [[ ${SHOWNVR} -eq 1 ]]; then
				ufrag=${URLfrag%%:*}; ufrag=${ufrag/\//-}
				if [[ ${SHOWLOG} -eq 1 ]]; then
					echo "${ufrag}-container-${LATESTTAG} - https://download.eng.bos.redhat.com/brewroot/packages/${ufrag}-container-${LATESTTAG//-//}/data/logs/x86_64.log"
				elif [[ ${TAGONLY} -eq 1 ]]; then
					echo "${LATESTTAG}"
				else
					echo "${ufrag}-container-${LATESTTAG}"
				fi
			elif [[ ${TAGONLY} -eq 1 ]]; then
				echo "${LATESTTAG}"
			elif [[ $QUIET -eq 1 ]]; then
				echo "${REGISTRYPRE}${URLfrag%%:*}:${LATESTTAG}"
			else
				echo "${URLfrag%%:*}:${LATESTTAG} :: ${REGISTRY}/${URLfrag%%:*}:${LATESTTAG}"
			fi
		elif [[ ${TAGONLY} -eq 1 ]]; then
			echo "${LATESTTAG}"
		else
			echo "${URLfrag}:${LATESTTAG}"
		fi

		if [[ ${PUSHTOQUAY} -eq 1 ]] && [[ ${REGISTRY} != *"quay.io"* ]]; then
			QUAYDEST="${REGISTRYPRE}${URLfrag}"; QUAYDEST=${QUAYDEST##*devspaces-} # udi or operator
			# special case for the operator and bundle images, which don't follow the same pattern in osbs as quay
			if [[ ${QUAYDEST} == "operator-bundle" ]]; then QUAYDEST="devspaces-operator-bundle"; fi
			if [[ ${QUAYDEST} == "operator" ]];        then QUAYDEST="devspaces-rhel8-operator"; fi
			QUAYDEST="quay.io/devspaces/${QUAYDEST}"

			if [[ $(skopeo --insecure-policy inspect docker://${QUAYDEST}:${LATESTTAG} 2>&1) == *"Error"* ]] || [[ ${PUSHTOQUAYFORCE} -eq 1 ]]; then 
				# CRW-1914 copy latest tag ONLY if it doesn't already exist on the registry, to prevent re-timestamping it and making it look new
				if [[ $VERBOSE -eq 1 ]]; then echo "Copy ${REGISTRYPRE}${URLfrag}:${LATESTTAG} to ${QUAYDEST}:${LATESTTAG}"; fi
				CMD="skopeo --insecure-policy copy --all docker://${REGISTRYPRE}${URLfrag}:${LATESTTAG} docker://${QUAYDEST}:${LATESTTAG}"; echo $CMD; $CMD
				# and update additional PUSHTOQUAYTAGS tags 
				for qtag in ${PUSHTOQUAYTAGS}; do
					if [[ $VERBOSE -eq 1 ]]; then echo "Copy ${REGISTRYPRE}${URLfrag}:${LATESTTAG} to ${QUAYDEST}:${qtag}"; fi
					CMD="skopeo --insecure-policy copy --all docker://${REGISTRYPRE}${URLfrag}:${LATESTTAG} docker://${QUAYDEST}:${qtag}"; echo $CMD; $CMD
				done
			else
				if [[ $VERBOSE -eq 1 ]]; then echo "Copy ${QUAYDEST}:${LATESTTAG} - already exists, nothing to do"; fi
			fi
		fi

		if [[ ${SHOWHISTORY} -eq 1 ]]; then
			if [[ $VERBOSE -eq 1 ]]; then echo "Pull ${REGISTRYPRE}${URLfrag}:${LATESTTAG} ..."; fi
			if [[ ! $(docker images | grep ${URLfrag} | grep ${LATESTTAG}) ]]; then 
				if [[ $VERBOSE -eq 1 ]]; then 
					docker pull ${REGISTRYPRE}${URLfrag}:${LATESTTAG}
				else
					docker pull ${REGISTRYPRE}${URLfrag}:${LATESTTAG} >/dev/null
				fi
			fi
			cnt=0
			IMAGE_INFO="$(docker images | grep ${URLfrag} | grep ${LATESTTAG})"
			if [[ $VERBOSE -eq 1 ]]; then echo $IMAGE_INFO; fi
			for bits in $IMAGE_INFO; do 
				let cnt=cnt+1
				if [[ ${cnt} -eq 3 ]]; then 
					# echo "Image ID = ${bits}"
					docker run -v /var/run/docker.sock:/var/run/docker.sock --rm laniksj/dfimage ${bits} # | grep FROM
					break
				fi
			done
			if [[ $VERBOSE -eq 1 ]]; then echo "Purge ${REGISTRYPRE}${URLfrag}:${LATESTTAG} ..."; fi
			docker image rm -f ${REGISTRYPRE}${URLfrag}:${LATESTTAG} >/dev/null
		fi
	done
	if [[ $NUMTAGS -gt 1 ]] || [[ ${SHOWHISTORY} -eq 1 ]]; then echo ""; fi
done
if [[ $c -gt 4 ]] && [[ $c -gt $n ]] && [[ $HIDE_MISSING -eq 0 ]]; then echo; echo "Found $n of $c containers"; fi
