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

cleanup()
{
    rm -f conftmp.c conftmp.d conftmp*.o
}

err()
{
    echo "${prog_NAME}: ERROR: $@" 1>&2
}

die()
{
    echo "${prog_NAME}: ERROR: $@" 1>&2
    cleanup
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
    --target=ARCH:
        Produce a Solo5 toolchain cross-targetted to ARCH.
        (default: Host system ARCH).
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

# Check that the linker ${LD} is available and suitable for our purposes.
check_ld()
{
    echo -n "${prog_NAME}: Checking if ${LD} is available: "
    if [ -x "$(command -v ${LD})" ]; then
        echo "yes"
    else
        echo "no"
        return 1
    fi
    echo -n "${prog_NAME}: Checking if ${LD} is LLD: "
    if ld_is_lld; then
        echo "yes"
        # LLD < 8 chokes on the Xen ldscript, so refuse to use it.
        echo -n "${prog_NAME}: Checking if LLD ${LD} is LLVM 8 or newer: "
        if ${LD} --version 2>&1 | grep -q '^LLD [1-7]\.'; then
            echo "no"
            return 1
        else
            echo "yes"
        fi
    else
        echo "no"
    fi

    cat >conftmp.c <<EOM
int foo(void)
{
    return 1;
}
EOM
    ${CC} -c conftmp.c -o conftmp.o || return 1

    echo -n "${prog_NAME}: Checking if ${LD} understands ${CONFIG_TARGET_ARCH}: "
    if ! ${LD} -r -o conftmp1.o conftmp.o >/dev/null 2>&1; then
        echo "no"
        return 1
    else
        echo "yes"
    fi
    return 0
}

# Check that the objcopy ${OBJCOPY} is available and suitable for our purposes.
check_objcopy()
{
    echo -n "${prog_NAME}: Checking if ${OBJCOPY} is available: "
    if [ -x "$(command -v ${OBJCOPY})" ]; then
        echo "yes"
    else
        echo "no"
        return 1
    fi

    cat >conftmp.c <<EOM
int KEEP_ME(void)
{
    return 1;
}
int local(void)
{
    return 1;
}
EOM
    ${CC} -c conftmp.c -o conftmp.o || return 1

    # A LLVM objcopy will understand any LLVM-supported architecture.
    # A GNU objcopy will only understand the architecture it was targetted for.
    echo -n "${prog_NAME}: Checking if ${OBJCOPY} understands ${CONFIG_TARGET_ARCH}: "
    if ! ${OBJCOPY} conftmp.o conftmp.o >/dev/null 2>&1; then
        echo "no"
        return 1
    else
        echo "yes"
    fi
    # For LLVM objcopy, -w and -G were introduced in
    # https://reviews.llvm.org/D66613.
    echo -n "${prog_NAME}: Checking if ${OBJCOPY} understands -w -G: "
    if ! ${OBJCOPY} -w -G KEEP\* conftmp.o conftmp.o >/dev/null 2>&1; then
        echo "no"
        return 1
    else
        echo "yes"
    fi
    return 0
}

OPT_PREFIX=/usr/local
while [ $# -gt 0 ]; do
    OPT="$1"

    case "${OPT}" in
        --prefix=*)
            OPT_PREFIX="${OPT##*=}"
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

TARGET_CC="${TARGET_CC:-cc}"

echo -n "${prog_NAME}: Checking that ${TARGET_CC} works: "
cat >conftmp.c <<EOM
int foo(void)
{
    return 1;
}
EOM
if ! ${TARGET_CC} -c conftmp.c -o conftmp.o >/dev/null 2>&1; then
    echo "no"
    die "Could not find a working compiler for target toolchain"
else
    echo "yes"
fi
TARGET_CC_MACHINE=$(${TARGET_CC} -dumpmachine)

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
echo "${prog_NAME}: Using ${TARGET_CC} for target compiler"

# TODO Can we simplify this a bit more somehow?
case ${CONFIG_HOST} in
    Linux)
        TARGET_LD="${TARGET_LD:-ld}"
        TARGET_OBJCOPY="${TARGET_OBJCOPY:-objcopy}"
        ;;
    FreeBSD)
        TARGET_LD="${TARGET_LD:-ld}"
        TARGET_OBJCOPY="${TARGET_OBJCOPY:-objcopy}"
        ;;
    OpanBSD)
        TARGET_LD="${TARGET_LD:-ld.lld}"
        TARGET_OBJCOPY="${TARGET_OBJCOPY:-objcopy}"
        if ! LD="${TARGET_LD}" ld_is_lld; then
            err "${TARGET_LD} is not LLVM LLD"
            die "Using GNU LD is not supported on OpenBSD"
        fi
        # TODO ex config_host_openbsd()
        # CONFIG_CFLAGS="${CONFIG_CFLAGS} -mno-retpoline -fno-ret-protector -nostdlibinc"
        # CONFIG_LDFLAGS="${CONFIG_LDFLAGS} -nopie"
        ;;
    *)
        die "Unsupported host system: ${CONFIG_HOST}"
        ;;
esac
if ! CC="${TARGET_CC}" LD="${TARGET_LD}" check_ld; then
    die "Could not find a working target linker"
fi
if ! CC="${TARGET_CC}" OBJCOPY="${TARGET_OBJCOPY}" check_objcopy; then
    die "Could not find a working target objcopy"
fi
echo "${prog_NAME}: Using ${TARGET_LD} for target linker"
echo "${prog_NAME}: Using ${TARGET_OBJCOPY} for target objcopy"

CONFIG_TARGET_TRIPLE="${CONFIG_TARGET_ARCH}-solo5-none-static"
echo "${prog_NAME}: Target toolchain triple is ${CONFIG_TARGET_TRIPLE}"

CONFIG_TARGET_CC_CFLAGS=
if CC="${TARGET_CC}" cc_is_clang; then
    CONFIG_TARGET_CC_CFLAGS=-nostdlibinc
else
    CONFIG_TARGET_CC_CFLAGS=-nostdinc
fi
case ${TARGET_CC_MACHINE} in
    x86_64-*linux*|ppc64-*linux*)
        CC="${TARGET_CC}" cc_check_option -mstack-protector-guard=global || \
            die "${TARGET_CC} does not support -mstack-protector-guard="
        CONFIG_TARGET_CC_CFLAGS="${CONFIG_TARGET_CC_CFLAGS} -mstack-protector-guard=global"
        ;;
esac

echo -n "${prog_NAME}: Enabled bindings: stub"
[ -n "${CONFIG_HVT}" ]    && echo -n " hvt"
[ -n "${CONFIG_SPT}" ]    && echo -n " spt"
[ -n "${CONFIG_VIRTIO}" ] && echo -n " virtio"
[ -n "${CONFIG_MUEN}" ]   && echo -n " muen"
[ -n "${CONFIG_XEN}" ]    && echo -n " xen"
echo "."
echo -n "${prog_NAME}: Enabled tenders:"
[ -n "${CONFIG_HVT_TENDER}" ]    && echo -n " hvt"
[ -n "${CONFIG_SPT_TENDER}" ]    && echo -n " spt"
echo "."

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
CONFIG_TARGET_TRIPLE=${CONFIG_TARGET_TRIPLE}
CONFIG_TARGET_CC=${TARGET_CC}
CONFIG_TARGET_CC_CFLAGS=${CONFIG_TARGET_CC_EXTRA_CFLAGS}
CONFIG_TARGET_LD=${TARGET_LD}
CONFIG_TARGET_LD_MAX_PAGE_SIZE=${CONFIG_TARGET_LD_MAX_PAGE_SIZE}
CONFIG_TARGET_OBJCOPY=${TARGET_OBJCOPY}
EOM

#
# Generate Makeconf.sh, to be included by shell scripts.
#
sed -Ee 's/^([A-Z_]+)=(.*)$/\1="\2"/' Makeconf >Makeconf.sh

cleanup
