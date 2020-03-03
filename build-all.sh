#!/bin/sh
############################################################ IDENT(1)
#
# $Title: Script to build bpftrace on CentOS 7.7+ $
# $Copyright: 2020 Devin Teske. All rights reserved. $
# $FrauBSD: el8-bpf-specs/build-all.sh 2020-03-02 23:06:20 -0800 freebsdfrau $
#
############################################################ ENVIRONMENT

: "${REDHAT:=$( cat /etc/redhat-release )}"
: "${UNAME_p:=$( uname -p )}"
: "${UNAME_r:=$( uname -r )}"

############################################################ GLOBALS

pgm="${0##*/}" # Program basename

#
# Global exit status
#
SUCCESS=0
FAILURE=1

############################################################ FUNCTIONS

exec 3<&1
eval2(){ printf "\033[32;1m==>\033[m %s\n" "$*" >&3; eval "$@"; }
have(){ type "$@" > /dev/null 2>&1; }
quietly(){ "$@" > /dev/null 2>&1; }
usage(){ die "Usage: %s\n" "$pgm"; }

die()
{
	local fmt="$1"
	if [ "$fmt" ]; then
		shift 1 # fmt
		printf "$fmt\n" "$@" >&2
	fi
	exit $FAILURE
}

rpmfilenames()
{
	local OPTIND=1 OPTARG flag
	local exclude=
	local spec
	local sp="[[:space:]]*"
	local dist=

	while getopts x: flag; do
		case "$flag" in
		x) exclude="$OPTARG" ;;
		esac
	done
	shift $(( $OPTIND - 1 ))

	spec="$1"

	case "$REDHAT" in
	*" 7."*) dist=.el7 ;;
	*" 8."*) dist=.el8 ;;
	esac

	awk -v name_regex="^$sp[Nn][Aa][Mm][Ee]:$sp" \
	    -v vers_regex="^$sp[Vv][Ee][Rr][Ss][Ii][Oo][Nn]:$sp" \
	    -v vrel_regex="^$sp[Rr][Ee][Ll][Ee][Aa][Ss][Ee]:$sp" \
	    -v arch_regex="^$sp[Bb][Uu][Ii][Ll][Dd][Aa][Rr][Cc][Hh]:$sp" \
	    -v dist="$dist" \
	    -v default_arch="$( uname -p )" \
	    -v exclude="$exclude" '
	################################################## BEGIN

	BEGIN {
		pkg = 0
		delete g # globals array
	}

	################################################## FUNCTIONS

	function show(name,        var, val, left, right)
	{
		gsub(/%\{\?dist\}/, dist, name)
		right = name
		while (1) {
			if (!match(right, /%{[^}]+}/)) break
			var = substr(right, RSTART + 2, RLENGTH - 3)
			val = var ~ /with_static/ ? "" : g[var]
			left = left substr(right, 1, RSTART - 1) val
			right = substr(right, RSTART + RLENGTH)
		}
		left = left right
		if (exclude != "" && left ~ exclude) return
		print left ".rpm"
		shown++
	}

	function dump()
	{
		if (pkgname == "") return
		show(sprintf("%s-%s-%s.%s", pkgname, vers, vrel,
			pkgarch == "" ? default_arch : pkgarch))
		pkgname = pkgarch = ""
	}

	################################################## MAIN

	$1 == "%global" { g[$2] = $3 }

	$1 == "%package" {
		dump()
		pkg = 1
		pkgname = $2 == "-n" ? $3 : name "-" $2
	}

	sub(name_regex, "") { name = g["name"] = $0 }
	sub(vers_regex, "") { vers = g["vers"] = $0 }
	sub(vrel_regex, "") { vrel = g["rel"] = $0 }

	sub(arch_regex, "") {
		if (pkg) pkgarch = $0; else arch = g["arch"] = $0
	}

	################################################## END

	END {
		dump()
		varch = arch == "" ? default_arch : arch
		if (name vers vrel != "")
			show(sprintf("%s-%s-%s.%s", name, vers, vrel, varch))
		if (shown == 0) exit 1
		show(sprintf("%s-debuginfo-%s-%s.%s", name, vers, vrel, varch))
	}
	' "$spec"
}

deps()
{
	local spec="$1"
	awk '/^BuildRequires:/{print $2}' "$spec"
}

build()
{
	local OPTIND=1 OPTARG flag
	local exclude=
	local spec
	local tool

	while getopts x: flag; do
		case "$flag" in
		x) exclude="$OPTARG" ;;
		esac
	done
	shift $(( $OPTIND - 1 ))

	tool="$1"

	spec=spec
	case "$REDHAT" in
	*" 7."*) spec=spec7 ;;
	esac

	if have figlet; then
		printf "\033[36m%s\033[m\n" "$( figlet "$tool" )"
	else
		printf "\033[36m#\n# Building %s\n#\033[39m\n" "$tool"
	fi

	local file name
	local exists=1
	for file in $( rpmfiles ${exclude:+-x"$exclude"} $tool/$tool.$spec )
	do
		name="${file##*/}"
		if [ -e "$file" ]; then
			printf "\033[32m%s exists\033[39m\n" "$file"
			continue
		fi
		printf "\033[33m%s does not exist\033[39m\n" "$file"
		exists=
	done
	if [ "$exists" ]; then
		echo "All RPMS exist (skipping $tool)"
		return
	fi

	eval2 cd $tool || die

	eval2 mkdir -p ~/rpmbuild/SOURCES || die
	for p in *.patch; do
		[ -e "$p" ] || continue
		eval2 cp $p ~/rpmbuild/SOURCES/ || die
	done

	eval2 spectool -g -R $tool.$spec || die
	local needed dep to_install=
	needed=$( deps $tool.$spec ) || die
	for dep in $needed; do
		if eval2 quietly rpm -q $dep; then
			printf "\033[32m%s installed\033[39m\n" "$dep"
		else
			printf "\033[33m%s not installed\033[39m\n" "$dep"
			to_install="$to_install $dep"
		fi
	done
	[ ! "$to_install" ] || eval2 sudo yum install -y $to_install || die
	( eval2 rpmbuild -bb $tool.$spec $*; echo EXIT:$? ) 2>&1 | awk '
		BEGIN { err = "error: failed to stat .*: "
			err = err "No such file or directory" }
		sub(/^EXIT:/, "") { exit_status = $0; next }
		{ NR_1 = NR_0; print NR_0 = $0 }
		END { exit NR_1 ~ /^\+ exit 0$/ &&
			NR_0 ~ "^" err "$" ? 0 : exit_status }
	' || die

	eval2 cd -
}

rpmfiles()
{
	rpmfilenames "$@" | awk -v p="$HOME/rpmbuild/RPMS/" '
		BEGIN { sub("/$", "", p) }
		/-debuginfo-/ { next }
		{
			arch = $0
			sub(/\.rpm$/, "", arch)
			sub(/.*\./, "", arch)
			printf "%s/%s/%s\n", p, arch, $0
		}
	' # END-QUOTE
}

yum_install()
{
	local need to_install=
	for need in $*; do
		if quietly rpm -q $need; then
			printf "\033[32m%s installed\033[39m\n" "$need"
		else
			printf "\033[33m%s not installed\033[39m\n" "$need"
			to_install="$to_install $need"
		fi
	done
	[ "$to_install" ] || return $SUCCESS
	eval2 sudo yum install -y $to_install || die
}

rpm_install()
{
	local file to_install=
	for file in $*; do
		name=${file##*/}
		name=${name%%-[0-9]*}
		rpm -q $name && continue
		to_install="$to_install $file"
	done
	[ "$to_install" ] || return $SUCCESS
	eval2 sudo rpm -ivh $to_install || die
}

rpm_uninstall()
{
	local path file name installed to_uninstall=
	for path in $*; do
		file="${path##*/}"
		name="${file%%-[0-9]*}"
		installed=$( rpm -q $name 2> /dev/null ) || continue
		[ "$installed" != "${file%.rpm}" ] || continue
		to_uninstall="$to_uninstall $conflict"
	done
	if [ "$to_uninstall" ]; then
		eval2 sudo rpm -e $to_uninstall \|\| : errors ignored
		local exists=
		for path in $*; do
			file="${path##*/}"
			name="${file%%-[0-9]*}"
			quietly rpm -q $name || continue
			exists=1
			printf "\033[31m%s still installed\033[39m\n" "$path"
		done
		[ ! "$exists" ] || die "Uninstall failed"
	fi
	return $SUCCESS
}

############################################################ MAIN

#
# Process command-line options
#
while getopts h flag; do
	case "$flag" in
	*) usage # NOTREACHED
	esac
done
shift $(( $OPTIND - 1 ))

#
# Check system dependencies
#
needed="gcc rpmdevtools"
case "$REDHAT" in
*" 7."*)
	# Tested on 7.7.1908
	needed="$needed devtoolset-8-runtime"
	;;
*" 8."*)
	# Tested on 8.1.1911
	needed="$needed gcc-c++"
	needed="$needed llvm-toolset llvm-devel llvm-static"
	needed="$needed clang-devel"
	needed="$needed python3-netaddr"
	;;
*)
	die "Unknown RedHat release ($REDHAT)"
esac
needed="$needed kernel-devel-${UNAME_r%.$UNAME_p}"
eval2 yum_install $needed

#
# Install bcc build-dependencies
#
spec=spec
case "$REDHAT" in
*" 7."*)
	spec=spec7
	build bpftool
	eval2 rpm_install $( rpmfiles bpftool/bpftool.$spec )
	if ! quietly rpm -q ebpftoolsbuilder-llvm-clang; then
		build llvm-clang
		eval2 rpm_uninstall clang clang-devel llvm llvm-devel
		eval2 rpm_install $( rpmfiles llvm-clang/llvm-clang.$spec )
	fi
	;;
*" 8.0"*)
	build bpftool
	eval2 rpm_install $( rpmfiles bpftool/bpftool.$spec )
	;;
*" 8."*)
	eval2 yum_install bpftool # from BaseOS
	;;
esac

#
# Build and install bcc
# NB: bpftrace dependency
#
build -x lua bcc
files=$( rpmfiles -x lua bcc/bcc.$spec ) # with lua = false
eval2 rpm_uninstall $files # Only uninstalls if version is wrong
eval2 rpm_install $files

#
# Install bpftrace build-dependencies
#
case "$REDHAT" in
*" 7."*) needed="ncurses-static binutils-devel" ;;
*" 8."*) needed="binutils-devel" ;;
esac
eval2 yum_install $needed

#
# Build and install bpftrace
#
build bpftrace
#build bpftrace --with static
#build bpftrace --with git
#build bpftrace --with git --with static
eval2 rpm_install $( rpmfiles bpftrace/bpftrace.$spec )

#
# All software built
#
eval2 : SUCCESS

################################################################################
# END
################################################################################
