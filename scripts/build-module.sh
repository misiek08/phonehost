#!/bin/sh
# Runs inside an alpine:edge container. /kernel = kernel tree, /mod = module dir.
set -eu

apk add --quiet --no-progress clang lld llvm binutils gcc g++ libgcc make bash bc bison flex \
	openssl-dev elfutils-dev perl python3 pahole zstd musl-dev linux-headers \
	diffutils findutils sed grep coreutils

cd /kernel
cp /work/phone.config .config

echo "== olddefconfig"
make ARCH=arm64 LLVM=1 HOSTCC=gcc HOSTCXX=g++ olddefconfig >/tmp/cfg.log 2>&1 || { tail -20 /tmp/cfg.log; exit 1; }

# Confirm the identity bits that make up vermagic survived olddefconfig
grep -E '^CONFIG_(LOCALVERSION=|SMP=|PREEMPT=|MODULE_UNLOAD=)' .config

echo "== modules_prepare"
make ARCH=arm64 LLVM=1 HOSTCC=gcc HOSTCXX=g++ -j"$(nproc)" modules_prepare >/tmp/prep.log 2>&1 || { tail -30 /tmp/prep.log; exit 1; }

echo "== build module"
# Module.symvers does not exist (we only ran modules_prepare, not a full kernel
# build). With CONFIG_MODVERSIONS=n the kernel resolves symbols at insmod time,
# so let modpost warn instead of failing; unknown symbols then show up as an
# insmod error rather than silently.
make ARCH=arm64 LLVM=1 HOSTCC=gcc HOSTCXX=g++ KBUILD_MODPOST_WARN=1 \
	-C /kernel M=/mod modules 2>&1 | tail -8

echo "== result"
ls -l /mod/pm6150_chg.ko
llvm-strip --strip-debug /mod/pm6150_chg.ko 2>/dev/null || true
cp /mod/pm6150_chg.ko /work/pm6150_chg.ko
modinfo /work/pm6150_chg.ko 2>/dev/null | head -8 || strings /work/pm6150_chg.ko | grep -m2 vermagic
