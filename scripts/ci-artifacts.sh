#!/bin/sh
# Collect build artifacts and test logs for upload as GitHub Actions artifacts.
#
# This helper is used by .github/workflows/ci.yml.  It is kept separate from
# scripts/ci-build.sh so that artifact collection is identical for every build
# system / platform, and so that a partially failed build never prevents the
# remaining artifacts (in particular the test logs) from being collected.
#
# usage:
#   scripts/ci-artifacts.sh binaries  <dest-dir> [<build> ...]
#   scripts/ci-artifacts.sh test-logs <dest-dir>
#
# <build> is one of the build system identifiers understood by
# scripts/ci-build.sh:  meson, cmake, cmake-asan, scons, autobuild
# If no <build> is given, all of them are collected.  The binaries of each build
# are collected in their own subdirectory <dest-dir>/<build>/ so that artifacts
# of different build systems never overwrite each other.
#
# For "test-logs", <dest-dir> is the directory that scripts/ci-build.sh writes
# its per-command logs to (CI_TEST_LOG_DIR); ctest / meson test / lighttpd test
# framework logs are copied into it, mirroring their location in the build
# directory tree.
#
# optional environment:
#   CI_RUNTIME_DLL_DIRS  space separated list of extra directories with runtime
#                        DLLs which are copied next to the executables
#                        (e.g. vcpkg installed/<triplet>/bin on Windows)
#   CI_ARTIFACT_NOTE     free-form text added to the generated MANIFEST.txt
#   GITHUB_STEP_SUMMARY  if set, the MANIFEST.txt is appended to the job summary
#
# The script is POSIX sh and is limited to portable find/cp/sed options so that
# it runs on Linux, Alpine (busybox ash), MSYS2, Cygwin and Git Bash for Windows.

set -eu

usage() {
	echo "usage: $0 binaries  <dest-dir> [<build> ...]" >&2
	echo "       $0 test-logs <dest-dir>" >&2
	echo "build: meson cmake cmake-asan scons autobuild" >&2
	exit 2
}

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# libtool creates a shell script wrapper next to the real binary in .libs/;
# only the real binary is useful in an artifact
is_binary() {
	[ -f "$1" ] || return 1
	if [ "$(head -c 2 "$1" 2>/dev/null)" = "#!" ]; then
		return 1
	fi
	return 0
}

# turn a relative path into a single path component
# ("./src/.libs" -> "src_.libs")
flatname() {
	echo "$1" | sed -e 's|^\./||' -e 's|/$||' -e 's|/|_|g'
}

# copy <file> into <dir>; if a file of that name was already collected from a
# different build directory (e.g. scons dynamic vs. static build), it is put
# into <dir>/<sub> instead of overwriting the first one
copy_into() {
	_cf_src="$1"
	_cf_dir="$2"
	_cf_sub="$3"
	_cf_name="$(basename "${_cf_src}")"
	if [ -e "${_cf_dir}/${_cf_name}" ]; then
		# libtool often keeps an identical copy of the binary in .libs/ and in
		# the build directory; do not collect it twice
		if command -v cmp >/dev/null 2>&1 &&
			cmp -s "${_cf_src}" "${_cf_dir}/${_cf_name}"; then
			echo "collected (duplicate skipped): ${_cf_src}"
			return 0
		fi
		_cf_dir="${_cf_dir}/${_cf_sub}"
	fi
	mkdir -p "${_cf_dir}"
	cp -f "${_cf_src}" "${_cf_dir}/${_cf_name}"
	echo "collected: ${_cf_src} -> ${_cf_dir}/${_cf_name}"
}

# candidate build directories for a build system, in order of preference
# (most useful binary first)
build_dirs() {
	case "$1" in
	meson)
		echo "build/src"
		;;
	cmake | cmake-asan)
		# scripts/ci-build.sh builds into ./cmakebuild;
		# a plain "cmake -B build" puts the targets into build/build
		echo "cmakebuild/build cmakebuild build/build"
		;;
	scons)
		echo "sconsbuild/build sconsbuild/static/build sconsbuild/fullstatic/build"
		;;
	autobuild)
		# in-tree autotools build; libtool puts the real binaries in .libs/
		echo "src/.libs src"
		;;
	esac
}

collect_from_dir() {
	_cd_parent="$1"
	_cd_out="$2"
	[ -d "${_cd_parent}" ] || return 0

	# multi-config generators (Visual Studio, Xcode) put the binaries into a
	# per-configuration subdirectory, e.g. build/build/Release/lighttpd.exe
	for _cd_dir in "${_cd_parent}" \
	                "${_cd_parent}/Release" "${_cd_parent}/RelWithDebInfo" \
	                "${_cd_parent}/Debug" "${_cd_parent}/MinSizeRel"; do
		[ -d "${_cd_dir}" ] || continue
		_cd_sub="$(flatname "${_cd_dir}")"

		for _cd_f in "${_cd_dir}/lighttpd" "${_cd_dir}/lighttpd.exe" \
		             "${_cd_dir}/lighttpd-angel" "${_cd_dir}/lighttpd-angel.exe"; do
			[ -f "${_cd_f}" ] || continue
			if ! is_binary "${_cd_f}"; then
				echo "note: skipping script ${_cd_f} (libtool wrapper?)"
				continue
			fi
			copy_into "${_cd_f}" "${_cd_out}" "${_cd_sub}"
		done

		for _cd_f in "${_cd_dir}"/mod_*.so "${_cd_dir}"/mod_*.dll \
		             "${_cd_dir}"/mod_*.dylib; do
			[ -f "${_cd_f}" ] || continue
			is_binary "${_cd_f}" || continue
			copy_into "${_cd_f}" "${_cd_out}/modules" "${_cd_sub}"
		done

		# liblightcomp is the shared core library of the autotools build when
		# the linker does not allow referencing symbols of the binary
		# (NO_RDYNAMIC, e.g. on Cygwin).  The executables need it next to
		# them at runtime.  Cygwin prefixes shared libraries with "cyg".
		for _cd_f in "${_cd_dir}"/liblightcomp*.so "${_cd_dir}"/liblightcomp*.so.* \
		             "${_cd_dir}"/liblightcomp*.dylib \
		             "${_cd_dir}"/liblightcomp*.dll \
		             "${_cd_dir}"/cyglightcomp*.dll; do
			[ -f "${_cd_f}" ] || continue
			is_binary "${_cd_f}" || continue
			copy_into "${_cd_f}" "${_cd_out}" "${_cd_sub}"
		done
	done

	return 0
}

# Copy runtime DLLs next to the executables and modules so that the artifact
# is runnable on a machine without a build environment.  Best effort only,
# never fatal.
copy_runtime_dlls() {
	set +e
	_rd_out="$1"
	_rd_seen=""

	if [ -n "${CI_RUNTIME_DLL_DIRS:-}" ]; then
		for _rd_dir in ${CI_RUNTIME_DLL_DIRS}; do
			[ -d "${_rd_dir}" ] || continue
			for _rd_f in "${_rd_dir}"/*.dll; do
				[ -f "${_rd_f}" ] || continue
				cp -f "${_rd_f}" "${_rd_out}/" 2>/dev/null &&
					echo "collected runtime dll: ${_rd_f}"
			done
		done
	fi

	# runtime DLLs of the executables and of the modules (Cygwin: cyg*.dll,
	# MSYS2/MinGW: /mingw*/bin); Linux/macOS binaries are not touched
	_rd_grep=""
	case "$(uname -s 2>/dev/null)" in
	MINGW* | MSYS*) _rd_grep='/(mingw|ucrt|clang)[0-9]*/' ;;
	CYGWIN*) _rd_grep='^(/usr/bin|/bin)/(cyg|lib)' ;;
	esac
	if [ -n "${_rd_grep}" ] && command -v ldd >/dev/null 2>&1; then
		for _rd_exe in "${_rd_out}"/lighttpd "${_rd_out}"/lighttpd.exe \
			"${_rd_out}"/modules/*.dll "${_rd_out}"/modules/*.so; do
			[ -f "${_rd_exe}" ] || continue
			for _rd_f in $(ldd "${_rd_exe}" 2>/dev/null |
				awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^\//) { print $i; break } }' |
				grep -Ei "${_rd_grep}"); do
				[ -f "${_rd_f}" ] || continue
				# never copy the Cygwin core DLL: a second copy of
				# cygwin1.dll next to the binary makes the loader
				# pick the wrong cygheap ("cygheap base mismatch"),
				# the binary then fails to start
				case "$(basename "${_rd_f}")" in
				cygwin1.dll) continue ;;
				esac
				case " ${_rd_seen} " in
				*" ${_rd_f} "*) continue ;;
				esac
				_rd_seen="${_rd_seen} ${_rd_f}"
				cp -f "${_rd_f}" "${_rd_out}/" 2>/dev/null &&
					echo "collected runtime dll: ${_rd_f}"
			done
		done
	fi

	set -e
	return 0
}

write_manifest() {
	_wm_dest="$1"
	_wm_manifest="${_wm_dest}/MANIFEST.txt"
	{
		echo "# lighttpd CI artifacts"
		echo "# generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
		echo "# host:      $(uname -srm 2>/dev/null || echo unknown)"
		if [ -n "${CI_ARTIFACT_NOTE:-}" ]; then
			echo "# note:      ${CI_ARTIFACT_NOTE}"
		fi
		echo "#"
		echo "#     size  file"
		(cd "${_wm_dest}" && find . -type f ! -name MANIFEST.txt | sort |
			while IFS= read -r _wm_f; do
				printf '%9s  %s\n' "$(wc -c < "${_wm_f}" | tr -d ' ')" "${_wm_f}"
			done)
	} > "${_wm_manifest}"
	echo "--- ${_wm_manifest} ---"
	cat "${_wm_manifest}"
	if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
		{
			echo "### artifacts: \`${_wm_dest}\`"
			echo '```'
			cat "${_wm_manifest}"
			echo '```'
		} >> "${GITHUB_STEP_SUMMARY}"
	fi
}

# ---------------------------------------------------------------------------
# binaries
# ---------------------------------------------------------------------------
collect_binaries() {
	_dest="$1"
	shift

	for _b in "$@"; do
		case "${_b}" in
		meson | cmake | cmake-asan | scons | autobuild) ;;
		*)
			echo "unknown build system: ${_b}" >&2
			usage
			;;
		esac
	done
	[ $# -gt 0 ] || set -- meson cmake cmake-asan scons autobuild

	mkdir -p "${_dest}"
	_missing=""
	for _b in "$@"; do
		_out="${_dest}/${_b}"
		_found=0
		for _d in $(build_dirs "${_b}"); do
			[ -d "${_d}" ] || continue
			collect_from_dir "${_d}" "${_out}"
			_found=1
		done
		if [ "${_found}" -eq 0 ]; then
			echo "error: no build directory found for '${_b}'" >&2
			_missing="${_missing} ${_b}"
			continue
		fi
		mkdir -p "${_out}"
		copy_runtime_dlls "${_out}"
		if [ -z "$(find "${_out}" -type f \( -name lighttpd -o -name lighttpd.exe \) \
			-print -quit)" ]; then
			echo "error: no lighttpd executable collected for '${_b}'" >&2
			_missing="${_missing} ${_b}"
		fi
	done

	if [ -n "${_missing}" ]; then
		echo "error: no binaries collected for build system(s):${_missing}" >&2
		echo "no binaries were collected for:${_missing}" > "${_dest}/NO-BINARIES.txt"
	fi
	write_manifest "${_dest}"
	if [ -n "${_missing}" ]; then
		exit 1
	fi
}

# ---------------------------------------------------------------------------
# test logs
# ---------------------------------------------------------------------------
collect_test_logs() {
	_dest="$1"
	mkdir -p "${_dest}"

	# logs written by scripts/ci-build.sh live in CI_TEST_LOG_DIR; copy them
	# over if a different directory is used for the artifact
	if [ -n "${CI_TEST_LOG_DIR:-}" ] && [ -d "${CI_TEST_LOG_DIR}" ] &&
		[ "$(cd "${CI_TEST_LOG_DIR}" && pwd -P)" != "$(cd "${_dest}" && pwd -P)" ]; then
		for _f in "${CI_TEST_LOG_DIR}"/*.log; do
			[ -f "${_f}" ] || continue
			cp -f "${_f}" "${_dest}/"
		done
	fi

	# do not descend into .git, into the artifact staging directory used by the
	# workflow, and (if relative) not into the destination itself
	_prune_expr='( -path ./.git -o -path ./artifacts )'
	case "${_dest}" in
	/*) ;;
	*)
		_prune_expr="( -path ./.git -o -path ./artifacts \
			-o -path ./$(echo "${_dest}" | sed -e 's|^\./||' -e 's|/$||') )"
		;;
	esac

	# shellcheck disable=SC2086  # (word split of the prune expression is intended)
	_list="$(find . ${_prune_expr} -prune -o -type f \
		\( \
			-path '*/Testing/Temporary/*.log' \
			-o -path '*/meson-logs/testlog*' \
			-o -path '*/tests/*.log' \
			-o -path '*/tests/*.trs' \
			-o -path '*/tests/tmp/*/logs/*' \
		\) \
		-print 2>/dev/null | sort)"

	if [ -z "${_list}" ]; then
		echo "warning: no test logs were found" >&2
		echo "no test logs were found in this job" > "${_dest}/NO-TEST-LOGS.txt"
	else
		printf '%s\n' "${_list}" | while IFS= read -r _f; do
			[ -n "${_f}" ] || continue
			_rel="${_f#./}"
			mkdir -p "${_dest}/$(dirname "${_rel}")"
			cp -f "${_f}" "${_dest}/${_rel}"
		done
	fi

	echo "collected $(find "${_dest}" -type f | wc -l | tr -d ' ') test log file(s) into '${_dest}'"
	write_manifest "${_dest}"
}

# ---------------------------------------------------------------------------

[ $# -ge 2 ] || usage
mode="$1"
dest="$2"
shift 2

case "${mode}" in
binaries)
	collect_binaries "${dest}" "$@"
	;;
test-logs)
	collect_test_logs "${dest}"
	;;
*)
	usage
	;;
esac
