.PHONY: all clean debug everything ptx clean-% asan msan ssan tsan

include $(BASE)/Config.mk

# Set defaults if not defined in Config.mk
ifndef CXX
CXX:=$(shell command -v clang++ 2> /dev/null)
endif
ifndef CABAL
CABAL:=$(shell command -v cabal 2> /dev/null)
endif
ifndef GHC
GHC:=$(shell command -v ghc 2> /dev/null)
endif
ifndef NVCC
NVCC:=$(shell command -v nvcc 2> /dev/null)
endif
ifndef PROJECTFILE
GHC_VERSION_PARTS:=$(subst ., ,$(shell $(GHC) --numeric-version))
GHC_VERSION:=$(word 1,$(GHC_VERSION_PARTS)).$(word 2,$(GHC_VERSION_PARTS))
ifneq ($(wildcard $(BASE)/cabal.project.ghc-$(GHC_VERSION)),)
PROJECTFILE:=cabal.project.ghc-$(GHC_VERSION)
else
PROJECTFILE:=cabal.project.ghc-8.10
endif
endif

all:
debug: asan msan ssan tsan
everything: all debug

clean: clean-objs clean-ptx

clean-objs:
clean-ptx:
clean-libs:
clean-bins:
clean-deps:
clean-debug: clean-asan clean-msan clean-ssan clean-tsan
clean-asan:
clean-msan:
clean-ssan:
clean-tsan:
clean-all: clean-objs clean-libs clean-deps clean-deps clean-ptx clean-bins \
    clean-debug
	$(PRINTF) "removing build directory...\n"
	$(AT)rm -rf $(BUILD) $(BASE)/cabal.project.local

.DELETE_ON_ERROR:

V = 0
AT_0 := @
AT_1 :=
AT = $(AT_$(V))

ifeq ($(V), 1)
    PRINTF := @\#
else
    PRINTF := @printf
endif

.PHONY: missing-cuda
missing-cuda:
	$(PRINTF) "nvcc not found, skipping GPU kernel libraries\n"

COMMON_CXXFLAGS=-MMD -MP -std=c++17 -g -I$(BASE)

CLANGWFLAGS=-Weverything -Wno-c++98-compat -Wno-c++98-compat-pedantic \
         -Wno-documentation-deprecated-sync -Wno-documentation -Wno-padded \
         -Wno-unused-const-variable -Wno-reserved-id-macro \
         -Wno-global-constructors -Wno-exit-time-destructors

CLANGCXXFLAGS=$(COMMON_CXXFLAGS) $(CLANGWFLAGS) -ftrapv

CXXFLAGS=$(if $(findstring clang++, $(CXX)), $(CLANGCXXFLAGS), $(COMMON_CXXFLAGS))

CXX_IS_CLANG:=$(findstring clang++, $(CXX))

LD=$(CXX)
LDFLAGS=-ldl -g

ifdef CXX_IS_CLANG
    CLANG_LIB_PATH:=$(shell $(CXX) --version | grep "^InstalledDir: " | sed 's/InstalledDir: //')
    LDFLAGS+= -rpath $(CLANG_LIB_PATH)/../lib/
endif

NVCC?=nvcc
NVCCXXFLAGS?=-std=c++11 -O3 -g -Wno-deprecated-declarations
NVCCARCHFLAGS?= \
    -gencode arch=compute_30,code=sm_30 \
    -gencode arch=compute_35,code=sm_35 \
    -gencode arch=compute_50,code=sm_50 \
    -gencode arch=compute_52,code=sm_52 \
    -gencode arch=compute_53,code=sm_53 \
    -gencode arch=compute_60,code=sm_60 \
    -gencode arch=compute_61,code=sm_61 \
    -gencode arch=compute_62,code=sm_62 \
    -gencode arch=compute_70,code=sm_70 \
    -gencode arch=compute_72,code=sm_72 \
    -gencode arch=compute_75,code=sm_75

PTXARCH?=sm_53

NVCCHOSTCXXFLAGS?=

NVLINK=$(NVCC)
SED?=sed

DOWNLOAD:=$(BUILD)/download
PREFIX:=$(BUILD)/prefix

LIBS := $(BUILD)
UNAME := $(shell uname -s)
ifeq ($(UNAME),Darwin)
    CXXFLAGS += -isystem$(CUDA_PATH)/include/ -Wno-undefined-func-template

    CLANGWFLAGS += -Wno-poison-system-directories
    DYLIBLDFLAGS += -flat_namespace -undefined suppress

    NVWFLAGS = $(CLANGWFLAGS) -Wno-unused-macros -Wno-c++11-long-long \
               -Wno-old-style-cast -Wno-used-but-marked-unused \
               -Wno-unused-function -Wno-missing-variable-declarations \
               -Wno-pedantic -Wno-missing-prototypes -Wno-unused-parameter \
               -Wno-missing-noreturn

    NVCCXXFLAGS += --compiler-options "$(NVWFLAGS) $(NVCCHOSTCXXFLAGS)" \
                   -isystem $(CUDA_PATH)/include/

endif
ifeq ($(UNAME),Linux)
    CLANGWFLAGS += -Wno-reserved-id-macro
    CLANGCXXFLAGS += -stdlib=libc++

    CXXFLAGS += -isystem$(CUDA_PATH)/include/
    LDFLAGS += -lpthread

ifdef CXX_IS_CLANG
    LD += -stdlib=libc++
endif

    NVWFLAGS =

    NVCCXXFLAGS += --compiler-options "$(NVWFLAGS) $(NVCCHOSTCXXFLAGS)" \
                   -Wno-deprecated-gpu-targets
endif

$(BUILD)/kernels/ $(DOWNLOAD)/ $(PREFIX)/ $(TARGET)/:
	$(PRINTF) " MKDIR\t$@\n"
	$(AT)mkdir -p $@

PKG_CONFIG_PATH:=$(patsubst :%,%,$(patsubst %:,%,$(PKG_CONFIG_PATH)))

ifdef CABAL
CABALCONFIG:=$(BASE)/cabal.project.local
ifeq ($(BASE)/$(PROJECTFILE).freeze, $(wildcard $(BASE)/$(PROJECTFILE).freeze))
CABALFREEZE:=$(BASE)/cabal.project.freeze
endif
endif

.PHONY: haskell-dependencies
haskell-dependencies: $(CABALCONFIG) $(CABALFREEZE)
ifndef CABAL
	$(PRINTF) "cabal-install not found, skipping Haskell parts\n"
else
	$(PRINTF) " CABAL\t$@\n"
	$(AT)$(CABAL) --builddir="$(abspath $(BUILD)/haskell/)" \
	    v2-build all $(if $(AT),2>/dev/null >/dev/null,)

$(BASE)/cabal.project: $(BASE)/$(PROJECTFILE) $(BASE)/Config.mk
	$(PRINTF) " CP\t$(@F)\n"
	$(AT)cp $< $@

$(BASE)/cabal.project.freeze: $(BASE)/$(PROJECTFILE).freeze $(BASE)/Config.mk
	$(PRINTF) " CP\t$(@F)\n"
	$(AT)cp $< $@

$(CABALCONFIG): $(BASE)/cabal.project
	$(PRINTF) " CABAL\tconfigure\n"
	$(AT)$(CABAL) --builddir="$(abspath $(BUILD)/haskell/)" v2-update \
	    $(if $(AT),2>/dev/null >/dev/null,)
ifneq ($(BASE)/$(PROJECTFILE).freeze, $(wildcard $(BASE)/$(PROJECTFILE).freeze))
	$(AT)rm -f $(BASE)/cabal.project.freeze
endif
	$(AT)$(CABAL) --builddir="$(abspath $(BUILD)/haskell/)" \
	    --with-compiler="$(GHC)" -j24 v2-configure \
	    $(if $(AT),2>/dev/null >/dev/null,)
	$(AT)rm -f $(CABALCONFIG)~

.PHONY: report-cabal
report-cabal:
	$(PRINTF) "$(CABAL)"

.PHONY: report-cxx
report-cxx:
	$(PRINTF) "$(CXX) $(filter-out -MMD -MP,$(CXXFLAGS))"

.PHONY: freeze
freeze:
	$(PRINTF) "Generating frozen config.\n"
	$(AT)rm -f $(BASE)/cabal.project.freeze
	$(AT)$(CABAL) --builddir="$(abspath $(BUILD)/haskell/)" \
	    v2-freeze $(if $(AT),2>/dev/null >/dev/null,)
	$(AT)cp "$(BASE)/cabal.project.freeze" "$(BASE)/$(PROJECTFILE).freeze"

.PHONY: haskell-%
haskell-%: $(CABALCONFIG) $(CABALFREEZE)
	$(PRINTF) " CABAL\t$@\n"
	$(AT)$(CABAL) --builddir="$(abspath $(BUILD)/haskell/)" \
	    v2-build $* $(if $(AT),2>/dev/null >/dev/null,)

.PHONY: install-%
install-%: $(CABALCONFIG) $(CABALFREEZE) | $(TARGET)/
ifdef TARGET
	$(PRINTF) " CABAL\t$@\n"
	$(AT)cp $$($(CABAL) --builddir="$(abspath $(BUILD)/haskell/)" \
	    v2-exec -- command -v $*) $(TARGET)/ \
	    $(if $(AT),2>/dev/null >/dev/null,)
else
	$(PRINTF) "TARGET is not set.\n"
endif
endif

BOOST_VERSION:=1.70.0
BOOST_NAME:=boost_1_70_0
BOOST_SHASUM:=882b48708d211a5f48e60b0124cf5863c1534cd544ecd0664bb534a4b5d506e9
BOOST_ROOT:=$(DOWNLOAD)/$(BOOST_NAME)
BOOST_PREREQ:=$(PREFIX)/include/boost/

BOOST_CXX_FLAGS:=-I$(PREFIX)/include -isystem$(PREFIX)/include
BOOST_LD_FLAGS:=-L$(PREFIX)/lib -L$(PREFIX)/lib64
ifdef CXX_IS_CLANG
BOOST_LD_FLAGS+= -rpath $(abspath $(PREFIX))/lib -rpath $(abspath $(PREFIX))/lib64
else
BOOST_LD_FLAGS+= -Wl,-rpath -Wl,$(abspath $(PREFIX))/lib -Wl,-rpath \
                 -Wl,$(abspath $(PREFIX))/lib64
endif

$(DOWNLOAD)/$(BOOST_NAME).tar.gz: | $(DOWNLOAD)/
	$(PRINTF) " CURL\tboost $(BOOST_VERSION)\n"
	$(AT)curl -s -L https://dl.bintray.com/boostorg/release/$(BOOST_VERSION)/source/$(BOOST_NAME).tar.gz >$@
	$(AT)printf "$(BOOST_SHASUM)  $@\n" | shasum -c /dev/stdin >/dev/null

$(BOOST_ROOT)/: $(DOWNLOAD)/$(BOOST_NAME).tar.gz
	$(PRINTF) " UNTAR\tboost $(BOOST_VERSION)\n"
	$(AT)tar xf $< -C $(DOWNLOAD)/

ifdef CXX_IS_CLANG
    $(BOOST_PREREQ): BOOST_B2_ARGS:=cxxflags="-stdlib=libc++" linkflags="-stdlib=libc++"
    BOOST_COMPILER:=clang
else
    BOOST_COMPILER:=gcc
endif
$(BOOST_PREREQ): | $(BOOST_ROOT)/
	$(PRINTF) " B2\tboost $(BOOST_VERSION)\n"
	$(AT)printf "using $(BOOST_COMPILER) : : $(CXX) ;" >$|/tools/build/src/user-config.jam
	$(AT)cd $| && ./bootstrap.sh toolset=$(BOOST_COMPILER) \
	    --prefix="$(abspath $(PREFIX))" \
	    --with-libraries=filesystem,system,regex \
	    $(if $(AT),2>/dev/null >/dev/null,)
	$(AT)cd $| && ./b2 toolset=$(BOOST_COMPILER) -j24 $(BOOST_B2_ARGS) \
	    $(if $(AT),2>/dev/null >/dev/null,)
	$(AT)cd $| && ./b2 toolset=$(BOOST_COMPILER) install \
	    $(if $(AT),2>/dev/null >/dev/null,)
