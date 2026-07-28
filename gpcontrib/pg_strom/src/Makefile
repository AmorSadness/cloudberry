#
# PG-Strom Makefile
#
include ../Makefile.common

PGSTROM_WITH_ARROW ?= 1
ifeq ($(filter $(PGSTROM_WITH_ARROW),0 1),)
$(error PGSTROM_WITH_ARROW must be either 0 or 1)
endif

#
# Source of PG-Strom host code
#
STROM_OBJS = main.o githash.o extra.o codegen.o executor.o fallback.o \
             gpu_device.o gpu_service.o dpu_device.o \
             gpu_scan.o gpu_join.o gpu_preagg.o \
             relscan.o brin.o gist.o gpu_cache.o select_into.o \
             misc.o float2.o tinyint.o aggfuncs.o
ifeq ($(PGSTROM_WITH_ARROW),1)
STROM_OBJS += arrow_fdw.o arrow_meta.o parquet_read.o
else
STROM_OBJS += arrow_stubs.o
endif
GENERATED-HEADERS = gpu_devattrs.h githash.c pgstrom_device_config.h
STROM_HEADERS = arrow_defs.h arrow_ipc.h float2.h

#
# PostgreSQL storage constants used by CUDA/DPU code
#
# Device sources cannot include postgres.h, so keep their fundamental storage
# layout constants synchronized with the server selected by PG_CONFIG.
# pgstrom_device_config.h is installed with the CUDA sources and participates
# in the fatbin content hash; the runtime fatbin builder therefore consumes
# exactly the same configuration as the host extension build.

#
# Githash.c checker
#
GITHASH_CHECKS := $(shell grep -q \"$(PGSTROM_GITHASH)\" githash.c 2>/dev/null || rm -f githash.c)

#
# Source of NVIDIA GPU device code
#
include Makefile.cuda

#
# Installation Scripts
#
__STROM_SQL = pg_strom--4.0--5.0.sql \
              pg_strom--5.0.sql \
              pg_strom--5.0--5.1.sql \
              pg_strom--5.1--6.0.sql
STROM_SQL = $(addprefix sql/,$(__STROM_SQL))

#
# Flags to build
#
PGSTROM_FLAGS += $(PGSTROM_FLAGS_CUSTOM)
PGSTROM_FLAGS += -D__PGSTROM_MODULE__=1
PGSTROM_FLAGS += -DPGSTROM_VERSION=\"$(PGSTROM_VERSION)\"

ifeq ($(PGSTROM_DEBUG),1)
PGSTROM_FLAGS += -g -O0 -DPGSTROM_DEBUG_BUILD=1
endif
PGSTROM_FLAGS += -D__STROM_HOST__=1
ifeq ($(shell uname -m),aarch64)
PGSTROM_FLAGS += -DHAVE_FLOAT2 -mfp16-format=ieee
endif
ifneq ($(PGSTROM_GITHASH),)
PGSTROM_FLAGS += -DPGSTROM_GITHASH=\"$(PGSTROM_GITHASH)\"
endif
PGSTROM_FLAGS += -DPGSHAREDIR=\"$(shell $(PG_CONFIG) --sharedir)\"   \
        -DPGINCLUDEDIR=\"$(shell $(PG_CONFIG) --includedir-server)\" \
        -DCUDA_MAXREGCOUNT=$(MAXREGCOUNT)                 \
        -DCUDA_MAXTHREADS_PER_BLOCK=$(MAXTHREADS_PER_BLOCK) \
        -DCUDA_CORE_FILES="\"$(__CUDA_CORE_FILES)\""      \
        -DCUDA_CORE_HEADERS="\"$(__CUDA_CORE_HEADERS)\""  \
        -DCUDA_TOOLKIT_BASEDIR="\"$(CUDA_PATH)\""
#
# Pre-built Fatbin (only debugging purpose)
#
ifeq ($(WITH_FATBIN),1)
DATA_built = $(CUDA_FATBIN)
PGSTROM_FLAGS += -DWITH_FATBIN=1
endif

#
# libarrow / libparquet
#
# Make this opt-in/opt-out explicit so packages installed on the builder do
# not silently change the MVP artifact.
ifeq ($(PGSTROM_WITH_ARROW),1)
HAS_LIBARROW = $(shell pkgconf --exists arrow>/dev/null 2>&1   && echo -n yes)
HAS_PARQUET  = $(shell pkgconf --exists parquet>/dev/null 2>&1 && echo -n yes)
ifneq ($(HAS_LIBARROW),yes)
$(error PGSTROM_WITH_ARROW=1 requires the Arrow development package)
endif
ifneq ($(HAS_PARQUET),yes)
$(error PGSTROM_WITH_ARROW=1 requires the Parquet development package)
endif
else
HAS_LIBARROW = no
HAS_PARQUET  = no
endif
ifeq ($(HAS_LIBARROW),yes)
PGSTROM_FLAGS += -DHAS_LIBARROW=1
PG_CXXFLAGS += $(shell pkgconf --cflags arrow)
ifeq ($(HAS_PARQUET),yes)
PGSTROM_FLAGS += -DHAS_PARQUET=1
PG_CXXFLAGS += $(shell pkgconf --cflags parquet)
SHLIB_LINK += $(shell pkgconf --libs parquet)
PARQUET_LIBDIR = $(shell pkgconf --variable=libdir parquet)
ifneq ($(PARQUET_LIBDIR),)
SHLIB_LINK += -Wl,-rpath,$(PARQUET_LIBDIR)
endif
else
SHLIB_LINK += $(shell pkgconf --libs arrow)
ARROW_LIBDIR = $(shell pkgconf --variable=libdir arrow)
ifneq ($(ARROW_LIBDIR),)
SHLIB_LINK += -Wl,-rpath,$(ARROW_LIBDIR)
endif
endif
endif

#
# Definition of PG-Strom Extension
#
MODULE_big = pg_strom
MODULEDIR  = pg_strom
DATA = $(STROM_SQL) ../LICENSE Makefile.cuda \
       $(CUDA_SRCS) $(CUDA_HEADERS) $(STROM_HEADERS)
OBJS = $(STROM_OBJS)

EXTRA_CLEAN = $(CUDA_OBJS) $(GENERATED-HEADERS) \
              $(shell ls -d pgstrom-gpucode-V*-*.fatbin 2>/dev/null)
EXTENSION = pg_strom
PG_CPPFLAGS := $(PGSTROM_FLAGS) -I $(CUDA_IPATH)
PG_CXXFLAGS := -std=c++17 -Wno-sign-compare
SHLIB_LINK += -L $(CUDA_LPATH) -lcuda

PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# Our C++ code (and libarrow/libparquet) expects C++17 as baseline,
# however, some distribution has different defaults for clang.
# PostgreSQL's makefile has no particular label to give "-std=c++17"
# to clang to build JIT bytecode. So, we inject this option after
# the inclusion of buildchain.
#
BITCODE_CXXFLAGS += $(PG_CXXFLAGS)

#
# Device Attributes
#
submake-generated-headers: $(GENERATED-HEADERS)

# PGXS does not make a directly requested module target wait for this custom
# submake target.  Express the real dependency as well, including for -j.
$(STROM_OBJS): | $(GENERATED-HEADERS)
gpu_service.o: pgstrom_device_config.h

gpu_devattrs.h: $(CUDA_IPATH)/cuda.h
	cat $(CUDA_IPATH)/cuda.h | \
	grep -E '^[ ]+CU_DEVICE_ATTRIBUTE_' | \
	grep -v -E 'CU_DEVICE_ATTRIBUTE_MAX$$' | \
	grep -v 'Deprecated[,\.]' | \
	sed -e 's|[ ]*CU_DEVICE_ATTRIBUTE_|DEV_ATTR(|g' \
	    -e 's| =.*/\*\*<[ ]*|, "|g' \
	    -e 's|[ ]*\*/|")|g' \
        -e 's| =.*$$|, NULL)|g' > $@

githash.c:
	echo "const char *pgstrom_githash_cstring = \"$(PGSTROM_GITHASH)\";" > githash.c

pgstrom_device_config.h: $(PG_CONFIG_HEADER) $(PG_CONFIG_MANUAL_HEADER) \
						 $(PG_BUFPAGE_HEADER) Makefile Makefile.cuda
	@{ \
		echo '/* auto-generated from the server selected by PG_CONFIG */'; \
		echo '#ifndef PGSTROM_DEVICE_CONFIG_H'; \
		echo '#define PGSTROM_DEVICE_CONFIG_H'; \
		echo '#define PGSTROM_DEVICE_NAMEDATALEN $(PGSTROM_DEVICE_NAMEDATALEN)'; \
		echo '#define PGSTROM_DEVICE_BLCKSZ $(PGSTROM_DEVICE_BLCKSZ)'; \
		echo '#define PGSTROM_DEVICE_RELSEG_SIZE $(PGSTROM_DEVICE_RELSEG_SIZE)'; \
		echo '#define PGSTROM_DEVICE_PAGE_LAYOUT_VERSION $(PGSTROM_DEVICE_PAGE_LAYOUT_VERSION)'; \
		echo '#define PGSTROM_DEVICE_MAXIMUM_ALIGNOF $(PGSTROM_DEVICE_MAXIMUM_ALIGNOF)'; \
		echo '#endif /* PGSTROM_DEVICE_CONFIG_H */'; \
	} > $@.tmp
	@if ! cmp -s $@.tmp $@; then mv -f $@.tmp $@; else rm -f $@.tmp; fi

#
# GPU Device Code
#
%.o: %.cu $(CUDA_HEADERS)
	$(NVCC) $(NVCC_CFLAGS)  --device-c -o $@ $<

$(CUDA_FATBIN): $(CUDA_OBJS)
	$(NVCC) $(NVCC_LDFLAGS) --device-link --fatbin -o $@ $(CUDA_OBJS)

fatbin: $(CUDA_FATBIN)
