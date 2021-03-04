#!/bin/sh

prog_NAME="$(basename $0)"

cleanup()
{
    rm -f conftmp.c conftmp.d conftmp*.o
}

die()
{
    echo "${prog_NAME}: ERROR: $@" 1>&2
    cleanup
    exit 1
}

cc_is_clang()
{
    ${CC} -dM -E - </dev/null | grep -Eq '^#define __clang__ 1$'
}

# Arguments: PATH, FILES...
# For the header FILES..., all of which must be relative to PATH, resolve their
# dependencies using the C preprocessor and output a list of FILES... plus all
# their unique dependencies, also relative to PATH.
cc_get_header_deps()
{
    temp="$PWD/conftmp.d"
    local path="$1"
    shift
    (
        cd ${path} || return 1
        ${CC} -M "$@" >${temp} || return 1
        sed -e 's!.*\.o:!!g' -e "s!${path}/!!g" ${temp} \
            | tr ' \\' '\n' \
            | sort \
            | uniq
        rm ${temp}
    )
}

[ "$#" -ne 1 ] && die "Missing DESTDIR"
DESTDIR=$1
. ../Makeconf.sh

mkdir -p ${DESTDIR} || die "mkdir failed"

if CC=${CONFIG_TARGET_CC} cc_is_clang; then
    case ${CONFIG_HOST} in
        # The BSDs don't ship some standard headers that we need in Clang's
        # resource directory. Appropriate these from the host system.
        FreeBSD|OpenBSD)
            SRCDIR=/usr/include
            SRCS="float.h stddef.h stdint.h stdbool.h stdarg.h"
            DEPS="$(mktemp)"
            CC=${CONFIG_TARGET_CC} cc_get_header_deps ${SRCDIR} ${SRCS} >${DEPS} || \
                die "Failure getting dependencies of host headers"
            # cpio will fail if CRT_INCDIR is below a symlink, so squash that
            DESTDIR="$(readlink -f ${DESTDIR})"
            Q=
            [ "${CONFIG_HOST}" = "FreeBSD" ] && Q="--quiet"
            (cd ${SRCDIR} && cpio ${Q} -Lpdm ${DESTDIR} <${DEPS}) || \
                die "Failure copying host headers"
            rm ${DEPS}
            ;;
    esac
else
    SRCDIR="$(${CONFIG_TARGET_CC} -print-file-name=include)"
    [ -d "${SRCDIR}" ] || die "Cannot determine gcc include directory"
    cp -R "${SRCDIR}/." ${DESTDIR} || \
        die "Failure copying host headers"
fi

cleanup
