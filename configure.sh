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

[ -z "${OPT_TARGET}" ] && OPT_TARGET=${CONFIG_HOST_ARCH}
TARGET_CC="${TARGET_CC:-clang} --target=${OPT_TARGET}-unknown-none"

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
        # Ah, the wonders of different Linux distributions and LLVM versions.
        # If the user did not specify a TARGET_LD, try and find one that
        # will work.
        if [ -z "${TARGET_LD}" ]; then
            if CC=${TARGET_CC} LD=ld.lld check_ld; then
                TARGET_LD=ld.lld
            elif CC=${TARGET_CC} LD=ld check_ld; then
                TARGET_LD=ld
            else
                err "Could not find a working linker for ${OPT_TARGET}"
                die "Try running with TARGET_LD set to a compatible linker"
            fi
        fi
        # If the user did not specify a TARGET_OBJCOPY, try and find one that
        # will work.
        if [ -z "${TARGET_OBJCOPY}" ]; then
            if CC=${TARGET_CC} OBJCOPY=llvm-objcopy check_objcopy; then
                TARGET_OBJCOPY=llvm-objcopy
            elif CC=${TARGET_CC} OBJCOPY=objcopy check_objcopy; then
                TARGET_OBJCOPY=objcopy
            else
                err "Could not find a working objcopy for ${OPT_TARGET}"
                die "Try running with TARGET_OBJCOPY set to a compatible objcopy"
            fi
        fi
        ;;
    FreeBSD)
        # FreeBSD 12+ has LLVM 8+ and an objcopy that works, so just use them,
        # but test them anyway unless explicitly overriden.
        if [ -z "${TARGET_LD}" ]; then
            if CC=${TARGET_CC} LD=ld check_ld; then
                TARGET_LD=ld
            else
                err "Could not find a working linker for ${OPT_TARGET}"
                die "Try running with TARGET_LD set to a compatible linker"
            fi
        fi
        if [ -z "${TARGET_OBJCOPY}" ]; then
            if CC=${TARGET_CC} OBJCOPY=objcopy check_objcopy; then
                TARGET_OBJCOPY=objcopy
            else
                err "Could not find a working objcopy for ${OPT_TARGET}"
                die "Try running with TARGET_OBJCOPY set to a compatible objcopy"
            fi
        fi
        ;;
    OpanBSD)
        # OpenBSD (since ?) has LLVM (version ?) and an objcopy that works, so
        # just use them, but test them anyway unless explicitly overriden.
        if [ -z "${TARGET_LD}" ]; then
            if CC=${TARGET_CC} LD=ld.lld check_ld; then
                TARGET_LD=ld.lld
            else
                err "Could not find a working linker for ${OPT_TARGET}"
                die "Try running with TARGET_LD set to a compatible linker"
            fi
        fi
        if [ -z "${TARGET_OBJCOPY}" ]; then
            if CC=${TARGET_CC} OBJCOPY=objcopy check_objcopy; then
                TARGET_OBJCOPY=objcopy
            else
                err "Could not find a working objcopy for ${OPT_TARGET}"
                die "Try running with TARGET_OBJCOPY set to a compatible objcopy"
            fi
        fi
        ;;
    *)
        die "Unsupported host system: ${CONFIG_HOST}"
        ;;
esac
if ! LD="${TARGET_LD}" ld_is_lld; then
    warn "${TARGET_LD} is not LLVM LLD, proceeding anyway"
fi
echo "${prog_NAME}: Using ${TARGET_LD} for target linker"
echo "${prog_NAME}: Using ${TARGET_OBJCOPY} for target objcopy"
# TODO ex config_host_openbsd()
# no longer required with clang --target?
# CONFIG_CFLAGS="${CONFIG_CFLAGS} -mno-retpoline -fno-ret-protector -nostdlibinc"
# CONFIG_LDFLAGS="${CONFIG_LDFLAGS} -nopie"

CONFIG_TARGET_SPEC="${CONFIG_TARGET_ARCH}-solo5-none-static"
CONFIG_TARGET_CLANG="${CONFIG_TARGET_ARCH}-unknown-none"
echo "${prog_NAME}: Target toolchain spec is ${CONFIG_TARGET_SPEC}"

[ -d "$PWD/toolchain" ] && die "toolchain/ already exists, run make distclean"

mkdir -p $PWD/toolchain/include
ln -s ../../include $PWD/toolchain/include/solo5

# Unlike Linux, the BSDs don't ship some standard headers that we need in
# Clang's resource directory. Appropriate these from the host system.
# TODO XXX Are these fine for cross-ARCH compliation?
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

L="$PWD/toolchain/lib"
mkdir -p ${L}
ln -s ../../bindings ${L}/${CONFIG_TARGET_SPEC}

# TODO generate these wrappers using a Makefile and sed, avoiding too many \s
T="toolchain/bin"
mkdir -p ${T}
cat >"${T}/${CONFIG_TARGET_SPEC}-cc" <<EOM
#!/bin/sh
I="\$(dirname \$0)/../include"
[ ! -d "\${I}" ] && echo "\$0: Could not determine include path" 1>&2 && exit 1
[ -n "\${__V}" ] && set -x
exec ${TARGET_CC} \
    --target=${CONFIG_TARGET_CLANG} \
    -nostdlibinc -isystem \${I}/${CONFIG_TARGET_SPEC} -I \${I}/solo5 \
    -ffreestanding -D__ELF__ \
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
        --solo5-abi=*)
            B="\${arg##*=}"
            continue
        ;;
    esac
    set -- "\$@" "\$arg"
done
[ -n "\${B}" ] && B="-T solo5_\${B}.lds -l :solo5_\${B}.o"
[ -n "\${__V}" ] && set -x
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
[ -n "\${__V}" ] && set -x
exec ${TARGET_OBJCOPY} \
    "\$@"
EOM
chmod +x "${T}/${CONFIG_TARGET_SPEC}-objcopy"
# TODO provide other usual tools? nm, ar, readelf, ...?

echo -n "${prog_NAME}: Enabled bindings:"
[ -n "${CONFIG_HVT}" ]    && echo -n " hvt"
[ -n "${CONFIG_SPT}" ]    && echo -n " spt"
[ -n "${CONFIG_VIRTIO}" ] && echo -n " virtio"
[ -n "${CONFIG_MUEN}" ]   && echo -n " muen"
[ -n "${CONFIG_XEN}" ]    && echo -n " xen"
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
CONFIG_TARGET_SPEC=${CONFIG_TARGET_SPEC}
CONFIG_TARGET_CC=${CONFIG_TARGET_SPEC}-cc
CONFIG_TARGET_LD=${CONFIG_TARGET_SPEC}-ld
CONFIG_TARGET_OBJCOPY=${CONFIG_TARGET_SPEC}-objcopy
EOM

#
# Generate Makeconf.sh, to be included by shell scripts.
#
sed -Ee 's/^([A-Z_]+)=(.*)$/\1="\2"/' Makeconf >Makeconf.sh

cleanup
