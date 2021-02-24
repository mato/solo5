#!/bin/sh
# Copyright (c) 2015-2020 Contributors as noted in the AUTHORS file
#
# This file is part of Solo5, a sandboxed execution environment.
#
# Permission to use, copy, modify, and/or distribute this software
# for any purpose with or without fee is hereby granted, provided
# that the above copyright notice and this permission notice appear
# in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL
# WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE
# AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR
# CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS
# OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT,
# NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN
# CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

prog_NAME="$(basename $0)"

err()
{
    echo "${prog_NAME}: ERROR: $@" 1>&2
}

die()
{
    echo "${prog_NAME}: ERROR: $@" 1>&2
    exit 1
}

warn()
{
    echo "${prog_NAME}: WARNING: $@" 1>&2
}

usage()
{
    cat <<EOM 1>&2
usage: ${prog_NAME} [ OPTIONS ]

Configures the Solo5 build system.

Options:
    --prefix=DIR:
        Installation prefix (default: /usr/local).
EOM
    exit 1
}

cc_maybe_gcc()
{
    ${CC} -dM -E - </dev/null | grep -Eq '^#define __GNUC__ ([4-9]$|[1-9][0-9]+$)'
}

cc_is_clang()
{
    ${CC} -dM -E - </dev/null | grep -Eq '^#define __clang__ 1$'
}

cc_has_pie()
{
    ${CC} -dM -E - </dev/null | grep -Eq '^#define __PIE__ [1-9]$'
}

cc_is_gcc()
{
    cc_maybe_gcc && ! cc_is_clang
}

cc_check_option()
{
    ${CC} "$@" -x c -c -o /dev/null - <<EOM >/dev/null 2>&1
int main(int argc, char *argv[])
{
    return 0;
}
EOM
}

cc_check_header()
{
    ${CC} ${PKG_CFLAGS} -x c -o /dev/null - <<EOM >/dev/null 2>&1
#include <$@>

int main(int argc, char *argv[])
{
    return 0;
}
EOM
}

cc_check_lib()
{
    ${CC} -x c -o /dev/null - "$@" ${PKG_LIBS} <<EOM >/dev/null 2>&1
int main(int argc, char *argv[])
{
    return 0;
}
EOM
}

ld_is_lld()
{
    ${LD} --version 2>&1 | grep -q '^LLD'
}

# Arguments: PATH, FILES...
# For the header FILES..., all of which must be relative to PATH, resolve their
# dependencies using the C preprocessor and output a list of FILES... plus all
# their unique dependencies, also relative to PATH.
cc_get_header_deps()
{
    local path="$1"
    shift
    (
        # XXX This will leak ${temp} on failure, too bad.
        temp="$(mktemp)"
        cd ${path} || exit 1
        ${CC} -M "$@" >${temp} || exit 1
        sed -e 's!.*\.o:!!g' -e "s!${path}/!!g" ${temp} \
            | tr ' \\' '\n' \
            | sort \
            | uniq
        rm ${temp}
    )
}

OPT_PREFIX=/usr/local
OPT_TARGET=
while [ $# -gt 0 ]; do
    OPT="$1"

    case "${OPT}" in
        --prefix=*)
            OPT_PREFIX="${OPT##*=}"
            ;;
        --target=*)
            OPT_TARGET="${OPT##*=}"
            ;;
        --help)
            usage
            ;;
        *)
            err "Unknown option: '${OPT}'"
            usage
            ;;
    esac

    shift
done

HOST_CC=${HOST_CC:-cc}
HOST_CC_MACHINE=$(${HOST_CC} -dumpmachine)
[ $? -ne 0 ] &&
    die "Could not run '${HOST_CC} -dumpmachine', is your compiler working?"
echo "${prog_NAME}: Using ${HOST_CC} for host toolchain (${HOST_CC_MACHINE})"

CONFIG_SPT_TENDER=
CONFIG_HVT_TENDER=
case ${HOST_CC_MACHINE} in
    x86_64-*linux*)
        CONFIG_HOST_ARCH=x86_64 CONFIG_HOST=Linux
        CONFIG_SPT_TENDER=1 CONFIG_HVT_TENDER=1
        ;;
    aarch64-*linux*)
        CONFIG_HOST_ARCH=aarch64 CONFIG_HOST=Linux
        CONFIG_SPT_TENDER=1 CONFIG_HVT_TENDER=1
        ;;
    powerpc64le-*linux*|ppc64le-*linux*)
        CONFIG_HOST_ARCH=ppc64le CONFIG_HOST=Linux
        CONFIG_SPT_TENDER=1
        ;;
    x86_64-*freebsd*)
        CONFIG_HOST_ARCH=x86_64 CONFIG_HOST=FreeBSD
        CONFIG_HVT_TENDER=1
        ;;
    amd64-*openbsd*)
        CONFIG_HOST_ARCH=x86_64 CONFIG_HOST=OpenBSD
        CONFIG_HVT_TENDER=1
        ;;
    *)
        die "Unsupported host toolchain: ${HOST_CC_MACHINE}"
        ;;
esac

CONFIG_SPT_TENDER_NO_PIE=
CONFIG_SPT_TENDER_LIBSECCOMP_CFLAGS=
CONFIG_SPT_TENDER_LIBSECCOMP_LDFLAGS=
if [ -n "${CONFIG_SPT_TENDER}" ]; then
    # If the host toolchain is NOT configured to build PIE exectuables by
    # default, assume it has no support for that and apply a workaround by
    # locating the spt tender starting at a virtual address of 1 GB.
    if ! CC=${HOST_CC} cc_has_pie; then
        warn "Host toolchain does not build PIE executables, spt guest size will be limited to 1GB"
        warn "Consider upgrading to a Linux distribution with PIE support"
        CONFIG_SPT_TENDER_NO_PIE=1
    fi

    if ! command -v pkg-config >/dev/null; then
        die "pkg-config is required"
    fi
    if ! pkg-config libseccomp; then
        die "libseccomp development headers are required"
    else
        if ! pkg-config --atleast-version=2.3.3 libseccomp; then
            # TODO Make this a hard error once there are no distros with
            # libseccomp < 2.3.3 in the various CIs.
            warn "libseccomp >= 2.3.3 is required for correct spt tender operation"
            warn "Proceeding anyway, expect tests to fail"
        elif ! pkg-config --atleast-version=2.4.1 libseccomp; then
            warn "libseccomp < 2.4.1 has known vulnerabilities"
            warn "Proceeding anyway, but consider upgrading"
        fi
        CONFIG_SPT_TENDER_LIBSECCOMP_CFLAGS="$(pkg-config --cflags libseccomp)"
        CONFIG_SPT_TENDER_LIBSECCOMP_LDLIBS="$(pkg-config --libs libseccomp)"
    fi
    if ! CC="${HOST_CC}" PKG_CFLAGS="${CONFIG_SPT_TENDER_LIBSECCOMP_CFLAGS}" \
        cc_check_header seccomp.h; then
        die "Could not compile with seccomp.h"
    fi
    if [ -n "${CONFIG_SPT_TENDER_LIBSECCOMP_LDLIBS}" ]; then
        if ! CC="${HOST_CC}" cc_check_lib ${CONFIG_SPT_TENDER_LIBSECCOMP_LDLIBS}; then
            die "Could not link with ${CONFIG_SPT_TENDER_LIBSECCOMP_LDLIBS}"
        fi
    fi
fi

CONFIG_HVT_TENDER_FREEBSD_ENABLE_CAPSICUM=
if [ "${CONFIG_HOST}" = "FreeBSD" -a -n "${CONFIG_HVT_TENDER}" ]; then
    # enable capsicum(4) sandbox if FreeBSD kernel is new enough
    [ "$(uname -K)" -ge 1200086 ] && CONFIG_HVT_TENDER_FREEBSD_ENABLE_CAPSICUM=1
fi

TARGET_CC=${TARGET_CC:-clang}
TARGET_LD=${TARGET_LD:-ld}
TARGET_OBJCOPY=${TARGET_OBJCOPY:-objcopy}

if [ -n "${OPT_TARGET}" ]; then
    TARGET_CC="${TARGET_CC} --target=${OPT_TARGET}-unknown-none"
    # TODO figure out binutils target triple
    TARGET_LD="${OPT_TARGET}-linux-gnu-ld"
    TARGET_OBJCOPY="${OPT_TARGET}-linux-gnu-objcopy"
fi

TARGET_CC_MACHINE=$(${TARGET_CC} -dumpmachine)
[ $? -ne 0 ] &&
    die "Could not run '${TARGET_CC} -dumpmachine', is your compiler working?"

CONFIG_HVT= CONFIG_SPT= CONFIG_VIRTIO= CONFIG_MUEN= CONFIG_XEN=
case ${TARGET_CC_MACHINE} in
    x86_64-*|amd64-*)
        CONFIG_TARGET_ARCH=x86_64
        CONFIG_TARGET_LD_MAX_PAGE_SIZE=0x1000
        CONFIG_HVT=1 CONFIG_SPT=1 CONFIG_VIRTIO=1 CONFIG_MUEN=1 CONFIG_XEN=1
        ;;
    aarch64-*)
        CONFIG_TARGET_ARCH=aarch64
        CONFIG_TARGET_LD_MAX_PAGE_SIZE=0x1000
        CONFIG_HVT=1 CONFIG_SPT=1
        ;;
    powerpc64le-*|ppc64le-*)
        CONFIG_TARGET_ARCH=ppc64le
        CONFIG_TARGET_LD_MAX_PAGE_SIZE=0x10000
        CONFIG_SPT=1
        ;;
    *)
        die "Unsupported target toolchain: ${TARGET_CC_MACHINE}"
        ;;
esac

# TODO ex config_host_openbsd()
# CONFIG_CFLAGS="${CONFIG_CFLAGS} -mno-retpoline -fno-ret-protector -nostdlibinc"
# CONFIG_LDFLAGS="${CONFIG_LDFLAGS} -nopie"

case ${TARGET_CC_MACHINE} in
    *openbsd*)
        if ! LD="${TARGET_LD}" ld_is_lld; then
            TARGET_LD="/usr/bin/ld.lld"
            warn "Using GNU 'ld' is not supported on OpenBSD"
            warn "Falling back to ${TARGET_LD}"
            [ -e "${TARGET_LD}" ] || die "${TARGET_LD} does not exist"
        fi
        ;;
esac

CONFIG_TARGET_SPEC="${CONFIG_TARGET_ARCH}-solo5-none"
CONFIG_TARGET_CLANG="${CONFIG_TARGET_ARCH}-unknown-none"
echo "${prog_NAME}: Using ${TARGET_CC} for target toolchain (${CONFIG_TARGET_CLANG})"

[ -d "$PWD/toolchain" ] && err "toolchain/ already exists, run make distclean" \
    && exit 1

# Make Solo5 public headers available to the in-tree toolchain at a well-defined path.
mkdir -p $PWD/toolchain/include
ln -s ../../include $PWD/toolchain/include/solo5

CRT_INCDIR=$PWD/toolchain/include/${CONFIG_TARGET_SPEC}
mkdir -p ${CRT_INCDIR}
case ${HOST_CC_MACHINE} in
    *freebsd*|*openbsd*)
        INCDIR=/usr/include
        SRCS="float.h stddef.h stdint.h stdbool.h stdarg.h"
        DEPS="$(mktemp)"
        CC=${HOST_CC} cc_get_header_deps ${INCDIR} ${SRCS} >${DEPS} || \
            die "Failure getting dependencies of host headers"
        # cpio will fail if CRT_INCDIR is below a symlink, so squash that
        CRT_INCDIR="$(readlink -f ${CRT_INCDIR})"
        Q=
        [ "${CONFIG_HOST}" = "FreeBSD" ] && Q="--quiet"
        (cd ${INCDIR} && cpio ${Q} -Lpdm ${CRT_INCDIR} <${DEPS}) || \
            die "Failure copying host headers"
        rm ${DEPS}
        ;;
esac

L="$PWD/toolchain/lib/${CONFIG_TARGET_SPEC}"
mkdir -p ${L}
[ -n "${CONFIG_HVT}" ] && ln -s ../../../bindings/hvt/solo5_hvt.lds ${L}/solo5_hvt.lds
[ -n "${CONFIG_HVT}" ] && ln -s ../../../bindings/hvt/solo5_hvt.o ${L}/solo5_hvt.o
[ -n "${CONFIG_SPT}" ] && ln -s ../../../bindings/spt/solo5_spt.lds ${L}/solo5_spt.lds
[ -n "${CONFIG_SPT}" ] && ln -s ../../../bindings/spt/solo5_spt.o ${L}/solo5_spt.o
[ -n "${CONFIG_VIRTIO}" ] && ln -s ../../../bindings/virtio/solo5_virtio.lds ${L}/solo5_virtio.lds
[ -n "${CONFIG_VIRTIO}" ] && ln -s ../../../bindings/virtio/solo5_virtio.o ${L}/solo5_virtio.o
[ -n "${CONFIG_MUEN}" ] && ln -s ../../../bindings/muen/solo5_muen.lds ${L}/solo5_muen.lds
[ -n "${CONFIG_MUEN}" ] && ln -s ../../../bindings/muen/solo5_muen.o ${L}/solo5_muen.o
[ -n "${CONFIG_XEN}" ] && ln -s ../../../bindings/xen/solo5_xen.lds ${L}/solo5_xen.lds
[ -n "${CONFIG_XEN}" ] && ln -s ../../../bindings/xen/solo5_xen.o ${L}/solo5_xen.o

T="toolchain/bin"
mkdir -p ${T}
cat >"${T}/${CONFIG_TARGET_SPEC}-cc" <<EOM
#!/bin/sh
I="\$(dirname \$0)/../include"
[ ! -d "\${I}" ] && echo "\$0: Could not determine include path" 1>&2 && exit 1
exec ${TARGET_CC} \
    --target=${CONFIG_TARGET_CLANG} \
    -nostdlibinc -isystem \${I}/${CONFIG_TARGET_SPEC} -I \${I}/solo5 \
    -ffreestanding \
    -fstack-protector-strong \
    "\$@"
EOM
chmod +x "${T}/${CONFIG_TARGET_SPEC}-cc"
cat >"${T}/${CONFIG_TARGET_SPEC}-ld" <<EOM
#!/bin/sh
L="\$(dirname \$0)/../lib/${CONFIG_TARGET_SPEC}"
[ ! -d "\${L}" ] && echo "\$0: Could not determine library path" 1>&2 && exit 1
B=
for arg do
    shift
    case "\$arg" in
        --solo5=*)
            B="\${arg##*=}"
            continue
        ;;
    esac
    set -- "\$@" "\$arg"
done
[ -n "\${B}" ] && B="-T solo5_\${B}.lds -l :solo5_\${B}.o"
exec ${TARGET_LD} \
    -nostdlib \
    -L \${L} \
    -z max-page-size=${CONFIG_TARGET_LD_MAX_PAGE_SIZE} \
    -static \
    \${B} \
    "\$@"
EOM
chmod +x "${T}/${CONFIG_TARGET_SPEC}-ld"
cat >"${T}/${CONFIG_TARGET_SPEC}-objcopy" <<EOM
#!/bin/sh
exec ${TARGET_OBJCOPY} \
    "\$@"
EOM
chmod +x "${T}/${CONFIG_TARGET_SPEC}-objcopy"

#
# Generate Makeconf, to be included by Makefiles.
#
cat <<EOM >Makeconf
# Generated by configure.sh, using CC=${CC} for target ${CC_MACHINE}
CONFIG_PREFIX=${OPT_PREFIX}
CONFIG_HOST_ARCH=${CONFIG_HOST_ARCH}
CONFIG_HOST=${CONFIG_HOST}
CONFIG_HOST_CC=${HOST_CC}
CONFIG_HVT=${CONFIG_HVT}
CONFIG_HVT_TENDER_FREEBSD_ENABLE_CAPSICUM=${CONFIG_HVT_TENDER_FREEBSD_ENABLE_CAPSICUM}
CONFIG_HVT_TENDER=${CONFIG_HVT_TENDER}
CONFIG_SPT=${CONFIG_SPT}
CONFIG_SPT_TENDER=${CONFIG_SPT_TENDER}
CONFIG_SPT_TENDER_NO_PIE=${CONFIG_SPT_NO_PIE}
CONFIG_SPT_TENDER_LIBSECCOMP_CFLAGS=${CONFIG_SPT_TENDER_LIBSECCOMP_CFLAGS}
CONFIG_SPT_TENDER_LIBSECCOMP_LDLIBS=${CONFIG_SPT_TENDER_LIBSECCOMP_LDLIBS}
CONFIG_VIRTIO=${CONFIG_VIRTIO}
CONFIG_MUEN=${CONFIG_MUEN}
CONFIG_XEN=${CONFIG_XEN}
CONFIG_TARGET_ARCH=${CONFIG_TARGET_ARCH}
CONFIG_TARGET_CC=${CONFIG_TARGET_SPEC}-cc
CONFIG_TARGET_LD=${CONFIG_TARGET_SPEC}-ld
CONFIG_TARGET_OBJCOPY=${CONFIG_TARGET_SPEC}-objcopy
EOM

#
# Generate Makeconf.sh, to be included by shell scripts.
#
sed -Ee 's/^([A-Z_]+)=(.*)$/\1="\2"/' Makeconf >Makeconf.sh

