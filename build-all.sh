#!/bin/sh
############################################################ IDENT(1)
#
# $Title: Script to build bpftrace on CentOS 7.7+ $
# $Copyright: 2020 Devin Teske. All rights reserved. $
# $FrauBSD: el8-bpf-specs/build-all.sh 2020-06-01 03:28:13 +0000 freebsdfrau $
#
############################################################ ENVIRONMENT

if [ -e /etc/redhat-release ]; then
	: "${OS:=RedHat}"
	: "${REDHAT:=$( cat /etc/redhat-release )}"
elif [ -e /etc/os-release ]; then
	: "${OS:=$( awk 'sub(/^NAME="?/, "") {
		sub(/"$/,"")
		print
	}' /etc/os-release )}"
	case "$OS" in
	Ubuntu)
		MIRROR=https://mirrors.ocf.berkeley.edu/centos/7/os/
		MIRROR=${MIRROR%/}/x86_64/Packages/
		RPMDEVTOOLS=rpmdevtools-8.3-5.el7.noarch.rpm
		: "${UBUNTU:=$( awk 'sub(/^VERSION="?/, "") {
			sub(/"$/, "")
			print
		}' /etc/os-release )}" ;;
	esac
fi
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

debfilenames()
{
	rpmfilenames "$@" | awk '{
		if (match($0, /-[0-9].*/)) $0 = sprintf("%s_%s",
			substr($0, 1, RSTART - 1), substr($0, RSTART + 1))
		sub(/\.noarch\.rpm$/, "_all.deb")
		sub(/\.x86_64\.rpm$/, "_amd64.deb")
		print
	}' # END-QUOTE
}

deps()
{
	local spec="$1"
	awk '/^BuildRequires:/&&$2!~/%{.*}/{print $2}' "$spec"
}

build()
{
	local OPTIND=1 OPTARG flag
	local exclude=
	local nodeps=
	local file name
	local exists
	local rpms debs debfile
	local spec
	local tool

	while getopts x: flag; do
		case "$flag" in
		x) exclude="$OPTARG" ;;
		esac
	done
	shift $(( $OPTIND - 1 ))

	tool="$1"

	case "$OS" in
	RedHat)
		spec=spec
		case "$REDHAT" in
		*" 7."*) spec=spec7 ;;
		esac
		;;
	Ubuntu)
		spec=uspec
		nodeps=1
		;;
	esac


	if have figlet; then
		printf "\033[36m%s\033[m\n" "$( figlet "$tool" )"
	else
		printf "\033[36m#\n# Building %s\n#\033[39m\n" "$tool"
	fi

	exists=1
	rpms=$( rpmfiles ${exclude:+-x"$exclude"} $tool/$tool.$spec )
	for file in $rpms; do
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
	else
		eval2 cd $tool || die

		eval2 mkdir -p ~/rpmbuild/SOURCES || die
		for p in *.patch; do
			[ -e "$p" ] || continue
			eval2 cp $p ~/rpmbuild/SOURCES/ || die
		done

		eval2 spectool -g -R $tool.$spec || die
		local needed dep to_install=
		needed=$( eval2 deps $tool.$spec ) || die
		eval2 os_install $needed
		( eval2 rpmbuild ${nodeps:+--nodeps} -bb $tool.$spec $*;
			echo EXIT:$? ) 2>&1 | awk '
			BEGIN { err = "error: failed to stat .*: "
				err = err "No such file or directory" }
			sub(/^EXIT:/, "") { exit_status = $0; next }
			{ NR_1 = NR_0; print NR_0 = $0 }
			END { exit NR_1 ~ /^\+ exit 0$/ &&
				NR_0 ~ "^" err "$" ? 0 : exit_status }
		' || die

		eval2 cd -
	fi
	case "$OS" in
	RedHat) return $? ;;
	esac

	# NOTREACHED unless Ubuntu

	exists=1
	debs=$( debfiles ${exclude:+-x"$exclude"} $tool/$tool.$spec )
	for file in $debs; do
		name="${file##*/}"
		if [ -e "$file" ]; then
			printf "\033[32m%s exists\033[39m\n" "$file"
			continue
		fi
		printf "\033[33m%s does not exist\033[39m\n" "$file"
		exists=
	done
	if [ "$exists" ]; then
		echo "All DEBS exist (skipping $tool)"
		return $SUCCESS
	fi
	for file in $rpms; do
		rpmfile2debfile "$file" debfile
		[ ! -e "$debfile" ] || continue
		eval2 mkdir -p "${debfile%/*}" || die
		eval2 cd "${debfile%/*}" || die
		eval2 sudo alien --to-deb --bump=0 "$file" || die
		eval2 cd -
	done
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

rpmfile2debfile()
{
	local __file="$1" __var_to_set="$2"
	local __left __right __arch __vers
	__left="${__file%/RPMS/*}"
	__right="${__file##*/RPMS/}"
	__file="$__left/DEBS/$__right"
	__left="${__file%/*}"
	__right="${__file##*/}"
	__arch="${__left##*/}"
	__left="${__left%/*}"
	case "$__arch" in
	noarch) __arch=all ;;
	x86_64) __arch=amd64 ;;
	esac
	__file="$__left/$__arch/${__right%.*.rpm}"
	__left="${__file##*/}"
	__left="${__left%%-[0-9]*}"
	__vers="${__file##*/}"
	__vers="${__vers#$__left-}"
	__file="${__file%/*}/${__left}_${__vers}_$__arch.deb"
	if [ "$__var_to_set" ]; then
		eval $__var_to_set=\"\$__file\"
	else
		echo "$__file"
	fi
}

debfiles()
{
	debfilenames "$@" | awk -v p="$HOME/rpmbuild/DEBS/" '
		BEGIN { sub("/$", "", p) }
		/-debuginfo_/ { next }
		{
			arch = $0
			sub(/\.deb$/, "", arch)
			sub(/.*_/, "", arch)
			printf "%s/%s/%s\n", p, arch, $0
		}
	' # END-QUOTE
}

yum_install()
{
	local need to_install=
	[ $# -gt 1 ] || return $SUCCESS
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

apt_install()
{
	local need to_install=
	[ $# -gt 1 ] || return $SUCCESS
	for need in $*; do
		if dpkg -l $need | grep -q ^ii; then
			printf "\033[32m%s installed\033[39m\n" "$need"
		else
			printf "\033[33m%s not installed\033[39m\n" "$need"
			to_install="$to_install $need"
		fi
	done
	[ "$to_install" ] || return $SUCCESS
	eval2 sudo apt-get install -y $to_install || die
}

os_install()
{
	case "$OS" in
	RedHat) yum_install "$@" ;;
	Ubuntu) apt_install "$@" ;;
	esac
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

deb_install()
{
	local file to_install=
	for file in $*; do
		name=${file##*/}
		name=${name%%_[0-9]*}
		eval2 dpkg -l $name && continue
		to_install="$to_install $file"
	done
	[ "$to_install" ] || return $SUCCESS
	eval2 sudo dpkg -i $to_install || die
}

rpm_uninstall()
{
	local also changes deps file found installed name path
	local exists=
	local to_uninstall=
	for path in $*; do
		file="${path##*/}"
		name="${file%%-[0-9]*}"
		installed=$( rpm -q $name 2> /dev/null ) || continue
		[ "$installed" != "${file%.rpm}" ] || continue
		to_uninstall="$to_uninstall $installed"
	done
	if [ "$to_uninstall" ]; then
		deps="$to_uninstall"
		while :; do
			deps=$( eval2 rpm -q --provides $deps |
				awk '(sub(/ .*/,"")||1)&&!_[$0]++' |
				xargs rpm -q --whatrequires |
				awk '!/^no package/'
			)
			changes=
			for also in $deps; do
				found=
				for name in $to_uninstall; do
					[ "$name" = "$also" ] || continue
					found=1
					break
				done
				[ "$found" ] && continue
				to_uninstall="$to_uninstall $also"
				changes=1
			done
			[ "$changes" ] || break
		done
		eval2 sudo rpm -e $to_uninstall \|\| : errors ignored
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

deb_uninstall()
{
	local also changes deps file found installed name path
	local exists=
	local to_uninstall=
	for path in $*; do
		file="${path##*/}"
		name="${file%%_[0-9]*}"
		installed=$( dpkg -l $name 2> /dev/null | awk '
			$1 == "ii" { printf "%s_%s_%s\n", $2, $3, $4 }
		' ) || continue
		[ "$installed" ] || continue
		[ "$installed" != "${file%.deb}" ] || continue
		to_uninstall="$to_uninstall $installed"
	done
	if [ "$to_uninstall" ]; then
		deps="$to_uninstall"
		while :; do
			deps=$( eval2 COLUMNS=200 dpkg -l |
				awk '$1=="ii"{print $2}' |
				xargs dpkg -s | awk '
					sub(/^Package: /, "") { pkg = $0 }
					sub(/^Depends: /, "") {
						n = split($0, dep, /, /)
						for (; n; n--) {
							sub(/ .*/, "", dep[n])
							print pkg, dep[n]
						}
					}
				' | awk -v depstr="$deps" '
					BEGIN {
						ndeps = split(depstr, dep)
						for (n = ndeps; n; n--)
							deps[dep[n]]
					}
					{
						for (n = 2; n <= NF; n++) {
							if (!($n in deps))
								continue
							depstr = depstr " " $n
							next
						}
					}
					END { print depstr }
				' # END-QUOTE
			)
			changes=
			for also in $deps; do
				found=
				for name in $to_uninstall; do
					[ "$name" = "$also" ] || continue
					found=1
					break
				done
				[ "$found" ] && continue
				to_uninstall="$to_uninstall $also"
				changes=1
			done
			[ "$changes" ] || break
		done
		eval2 sudo dpkg -P $to_uninstall \|\| : errors ignored
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
case "$OS" in
RedHat)
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
	eval2 os_install $needed
	;;
Ubuntu)
	needed="rpm alien"
	case "$UBUNTU" in
	*"18.04"*)
		eval2 os_install $needed
		dir=rpmbuild/RPMS/noarch
		name=rpmdevtools
		if ! quietly dpkg -l $name; then
			printf "\033[36m#\n# Installing $name\n#\033[39m\n"
			eval2 mkdir -p ~/$dir || die
			eval2 curl -LO "${MIRROR%/}/$RPMDEVTOOLS" || die
			eval2 mv $RPMDEVTOOLS ~/$dir/ || die
			eval2 sudo alien -i ~/$dir/$RPMDEVTOOLS || die
		fi
		;;
	*)
		die "Unknown Ubuntu release ($UBUNTU)"
	esac
	;;
*)
	die "Unknown OS ($OS)"
esac
eval2 os_install $needed

#
# Install bcc build-dependencies
#
case "$OS" in
RedHat)
	spec=spec
	case "$REDHAT" in
	*" 7."*)
		spec=spec7
		eval2 build bpftool
		eval2 rpm_install $( rpmfiles bpftool/bpftool.$spec )
		if ! quietly rpm -q ebpftoolsbuilder-llvm-clang; then
			eval2 build llvm-clang
			eval2 rpm_uninstall clang clang-devel llvm llvm-devel
			eval2 rpm_install $(
				rpmfiles llvm-clang/llvm-clang.$spec
			)
		fi
		;;
	*" 8.0"*)
		eval2 build bpftool
		eval2 rpm_install $( rpmfiles bpftool/bpftool.$spec )
		;;
	*" 8."*)
		eval2 yum_install bpftool # from BaseOS
		;;
	esac
	;;
Ubuntu)
	spec=uspec
	case "$UBUNTU" in
	"18.04"*)
		eval2 build bpftool
		eval2 deb_install $( debfiles bpftool/bpftool.$spec )
		;;
	*) # 20 and above
		eval2 apt_install linux-tools-common
	esac
esac

#
# Build and install bcc
# NB: bpftrace dependency
#
case "$OS" in
RedHat)
	eval2 build -x lua bcc
	files=$( rpmfiles -x lua bcc/bcc.$spec ) # with lua = false
	eval2 rpm_uninstall $files # Only uninstalls wrong versions
	eval2 rpm_install $files
	;;
Ubuntu)
	case "$UBUNTU" in
	"18.04"*)
		eval2 build -x lua bcc
		files=$( debfiles -x lua bcc/bcc.$spec ) # with lua = false
		eval2 deb_uninstall $files # Only uninstalls wrong versions
		eval2 deb_install $files
		;;
	*) # 20 and above
		eval2 apt_install linux-tools-$( uname -r )
	esac
	;;
esac

#
# Install bpftrace build-dependencies
#
case "$OS" in
RedHat)
	case "$REDHAT" in
	*" 7."*) needed="ncurses-static binutils-devel" ;;
	*" 8."*) needed="binutils-devel" ;;
	esac
	eval2 yum_install $needed
	;;
esac

#
# Build and install bpftrace
#
case "$OS" in
RedHat)
	eval2 build bpftrace
	#eval2 build bpftrace --with static
	#eval2 build bpftrace --with git
	#eval2 build bpftrace --with git --with static
	eval2 rpm_install $( rpmfiles bpftrace/bpftrace.$spec )
	;;
Ubuntu)
	case "$UBUNTU" in
	"18.04"*)
		eval2 build bpftrace
		#eval2 build bpftrace --with static
		#eval2 build bpftrace --with git
		#eval2 build bpftrace --with git --with static
		eval2 deb_install $( debfiles bpftrace/bpftrace.$spec )
		;;
	*) # 20 and above
		eval2 apt_install bpftrace
	esac
	;;
esac

#
# All software built
#
eval2 : SUCCESS

################################################################################
# END
################################################################################
