#!/bin/sh
# build script used by jenkins

set -ex

# Optional: also write the output of every compile/test command to a separate
# log file, for upload as CI artifact (.github/workflows/ci.yml).  The log file
# name is <CI_TEST_LOG_DIR>/<log-name>.log.  If CI_TEST_LOG_DIR is not set,
# commands are run exactly as before (output only on the console).
# A relative path is resolved against the initial working directory, since
# some build systems below change into their build directory.
if [ -n "${CI_TEST_LOG_DIR:-}" ]; then
    case "${CI_TEST_LOG_DIR}" in
    /*) ;;
    *) CI_TEST_LOG_DIR="$(pwd)/${CI_TEST_LOG_DIR}" ;;
    esac
    export CI_TEST_LOG_DIR
fi

# run_logged <log-name> <command> [<arg> ...]
# Run a command, showing its output on the console and (if CI_TEST_LOG_DIR is
# set) also writing it to a log file.  The exit status of the command is
# preserved, so a failed build or test still fails the build script.
run_logged() {
    log_name="$1"
    shift
    if [ -z "${CI_TEST_LOG_DIR:-}" ]; then
        "$@"
        return $?
    fi
    mkdir -p "${CI_TEST_LOG_DIR}"
    log_file="${CI_TEST_LOG_DIR}/${log_name}.log"
    echo "==> $* (log: ${log_file})"
    set +e
    # (the subshell disables -e/-x for the command so that its exit code is
    #  always recorded, even if the command fails)
    ( { set +ex; } 2>/dev/null; "$@"; echo $? > "${log_file}.exitcode" ) 2>&1 | tee "${log_file}"
    log_rc="$(cat "${log_file}.exitcode" 2>/dev/null || true)"
    rm -f "${log_file}.exitcode"
    set -e
    [ -n "${log_rc}" ] || log_rc=1
    return "${log_rc}"
}

build="${1:-autobuild}" # build system: coverity, autobuild, cmake, scons, ...
label="$2"              # label: {debian-{stable,testing},freebsd*}-{i386,amd64}
compiler="${3:-gcc}"    # might want to overwrite a compiler
# build=coverity:
# - create "cov-int" directory for upload (gets `tar`d)
# - access coverity binaries with export PATH="${COVERITY_PATH}"

# disable --with-wolfssl by default, but allow it to be enabled by caller,
# e.g. disable on Alpine Linux where wolfssl package is not built including
# features required by lighttpd (--with-opensslextra --enable-lighty)
#${WITH_WOLFSSL:=true}
[ -n "$NO_WOLFSSL" ] && unset WITH_WOLFSSL

${WITH_DBI:=true}
[ -n "$NO_DBI" ] && unset WITH_DBI

${WITH_GNUTLS:=true}
[ -n "$NO_GNUTLS" ] && unset WITH_GNUTLS

${WITH_KRB5:=true}
[ -n "$NO_KRB5" ] && unset WITH_KRB5

${WITH_MYSQL:=true}
[ -n "$NO_MYSQL" ] && unset WITH_MYSQL

${WITH_PAM:=true}
[ -n "$NO_PAM" ] && unset WITH_PAM

${WITH_PGSQL:=true}
[ -n "$NO_PGSQL" ] && unset WITH_PGSQL

${WITH_SASL:=true}
[ -n "$NO_SASL" ] && unset WITH_SASL

${WITH_UNWIND:=true}
[ -n "$NO_UNWIND" ] && unset WITH_UNWIND

sysname="$(uname -s)"

if [ "$sysname" = "Darwin" ]; then
    # keg-only package installs not linked into /opt/homebrew
    #   brew install cyrus-sasl krb5 libressl libpq libxml2 mariadb-connector-c openldap zlib
    export PKG_CONFIG_PATH="/opt/homebrew/opt/cyrus-sasl/lib/pkgconfig:/opt/homebrew/opt/krb5/lib/pkgconfig:/opt/homebrew/opt/libressl/lib/pkgconfig:/opt/homebrew/opt/libpq/lib/pkgconfig:/opt/homebrew/opt/libxml2/lib/pkgconfig:/opt/homebrew/opt/mariadb-connector-c/lib/pkgconfig:/opt/homebrew/opt/openldap/lib/pkgconfig:/opt/homebrew/opt/zlib/lib/pkgconfig"
fi

if [ "$sysname" = "FreeBSD" ]; then
    export CPPFLAGS=-I/usr/local/include
    export LDFLAGS=-L/usr/local/lib
fi

if [ "$sysname" = "NetBSD" ]; then
    export CPPFLAGS=-I/usr/pkg/include
    export LDFLAGS=-L/usr/pkg/lib
    export LD_LIBRARY_PATH=/usr/pkg/lib
fi

if [ "$sysname" = "OpenBSD" ]; then
    export CPPFLAGS=-I/usr/local/include
    export LDFLAGS=-L/usr/local/lib
    export PKG_CONFIG_LIBDIR=/usr/lib/pkgconfig:/usr/local/lib/pkgconfig:/usr/local/heimdal/lib/pkgconfig
fi

case "${build}" in
"autobuild")
	mkdir -p m4
	autoreconf --force --install
	./configure -C \
		--with-pic --enable-extra-warnings \
		${WITH_DBI:+--with-dbi} \
		${WITH_MYSQL:+--with-mysql} \
		${WITH_PGSQL:+--with-pgsql} \
		--with-ldap --with-pcre2 \
		--with-zlib --with-zstd --with-brotli --with-libdeflate \
		--with-lua \
		${WITH_UNWIND:+--with-libunwind} \
		${WITH_KRB5:+--with-krb5} \
		${WITH_PAM:+--with-pam} \
		${WITH_SASL:+--with-sasl} \
		--with-maxminddb \
		--with-nettle \
		${WITH_GNUTLS:+--with-gnutls} \
		--with-mbedtls \
		--with-nss \
		--with-openssl \
		${WITH_WOLFSSL:+--with-wolfssl} \
		--with-webdav-props
	run_logged build-autobuild make -j 4
	run_logged tests-autobuild make check
	;;
"cmake"|"cmake-asan")
	mkdir -p cmakebuild
	cd cmakebuild
	if [ "${build}" = "cmake-asan" ]; then
		asan_opts="-DBUILD_SANITIZE_ADDRESS=ON -DBUILD_SANITIZE_UNDEFINED=ON"
	else
		asan_opts=""
	fi
	cmake \
		-DBUILD_EXTRA_WARNINGS=ON \
		${asan_opts} \
		-DCMAKE_BUILD_TYPE=RelWithDebInfo \
		-DWITH_PCRE2=ON \
		-DWITH_ZLIB=ON \
		-DWITH_ZSTD=ON \
		-DWITH_BROTLI=ON \
		-DWITH_LIBDEFLATE=ON \
		-DWITH_LDAP=ON \
		${WITH_UNWIND:+-DWITH_LIBUNWIND=ON} \
		-DWITH_LUA=ON \
		-DWITH_MAXMINDDB=ON \
		${WITH_DBI:+-DWITH_DBI=ON} \
		${WITH_MYSQL:+-DWITH_MYSQL=ON} \
		${WITH_PGSQL:+-DWITH_PGSQL=ON} \
		${WITH_KRB5:+-DWITH_KRB5=ON} \
		${WITH_PAM:+-DWITH_PAM=ON} \
		${WITH_SASL:+-DWITH_SASL=ON} \
		${WITH_GNUTLS:+-DWITH_GNUTLS=ON} \
		-DWITH_MBEDTLS=ON \
		-DWITH_NETTLE=ON \
		-DWITH_NSS=ON \
		-DWITH_OPENSSL=ON \
		${WITH_WOLFSSL:+-DWITH_WOLFSSL=ON} \
		-DWITH_WEBDAV_PROPS=ON \
		..
	run_logged "build-${build}" make -j 4 VERBOSE=1
	run_logged "tests-${build}" ctest -V
	;;
"meson"|"coverity")
	[ -d build ] || meson setup build
	meson configure --buildtype debugoptimized \
	  -Dbuild_extra_warnings=true \
	  -Dwith_brotli=enabled \
	  ${WITH_DBI:+-Dwith_dbi=enabled} \
	  ${WITH_GNUTLS:+-Dwith_gnutls=true} \
	  ${WITH_KRB5:+-Dwith_krb5=enabled} \
	  -Dwith_ldap=enabled \
	  -Dwith_libdeflate=enabled \
	  ${WITH_UNWIND:+-Dwith_libunwind=enabled} \
	  -Dwith_lua=true \
	  -Dwith_maxminddb=enabled \
	  -Dwith_mbedtls=true \
	  ${WITH_MYSQL:+-Dwith_mysql=enabled} \
	  -Dwith_nettle=true \
	  -Dwith_nss=true \
	  -Dwith_openssl=true \
	  ${WITH_PAM:+-Dwith_pam=enabled} \
	  -Dwith_pcre2=true \
	  ${WITH_PGSQL:+-Dwith_pgsql=enabled} \
	  ${WITH_SASL:+-Dwith_sasl=enabled} \
	  -Dwith_webdav_props=enabled \
	  ${WITH_WOLFSSL:+-Dwith_wolfssl=true} \
	  -Dwith_zlib=enabled \
	  -Dwith_zstd=enabled \
	  build
	cd build
	case "${build}" in
	"meson")
		run_logged build-meson meson compile -j 4 --verbose
		run_logged tests-meson meson test --verbose
		;;
	"coverity")
		[ -z "${COVERITY_PATH}" ] || export PATH="${COVERITY_PATH}"
		run_logged build-coverity cov-build --dir "../cov-int" -- meson compile -j 4 --verbose
		;;
	esac
	;;
"scons")
	case "${label}" in
	debian*)
		# static linking needs some extra stuff on debian
		export LDFLAGS="-pthread"
		export LIBS="-ldl"
		;;
	esac
	run_logged tests-scons scons -j 4 with_pcre2=yes with_zlib=yes with_openssl=yes with_brotli=yes -k check_static check_dynamic
	run_logged tests-scons-fullstatic scons -j 4 with_pcre2=yes with_zlib=yes with_openssl=yes -k check_fullstatic
	;;
*)
	echo >&2 "Unknown build system: ${build}"
	exit 1
	;;
esac
