.PHONY: all clean clean-objs clean-bins clean-libs clean-deps clean-all

all:

clean: clean-objs

CLEAN_OBJS:=
CLEAN_BINS:=
CLEAN_LIBS:=
CLEAN_DEPS:=

clean-objs:
	$(PRINTF) "cleaning object files...\n"
	$(AT)rm -rf $(CLEAN_OBJS)

clean-libs:
	$(PRINTF) "cleaning libraries...\n"
	$(AT)rm -rf $(CLEAN_LIBS)

clean-bins:
	$(PRINTF) "cleaning executables...\n"
	$(AT)rm -rf $(CLEAN_BINS)

clean-deps:
	$(PRINTF) "cleaning dependencies...\n"
	$(AT)rm -rf $(CLEAN_DEPS)

clean-all: clean-objs clean-libs clean-deps clean-deps

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

COMMON_CXXFLAGS=-O3 -MMD -MP -std=c++14 -g

CLANGWFLAGS=-Weverything -Wno-c++98-compat -Wno-c++98-compat-pedantic \
         -Wno-documentation-deprecated-sync -Wno-documentation -Wno-padded \
         -Wno-unused-const-variable -Wno-reserved-id-macro \
         -Wno-global-constructors -Wno-exit-time-destructors

CLANGCXXFLAGS=$(COMMON_CXXFLAGS) $(CLANGWFLAGS) -ftrapv

ICCWFLAGS=-Wall -Wremarks -Wcheck -Werror -diag-disable=869,981,10382,11074,11076
ICC_CXXFLAGS=$(COMMON_CXXFLAGS) $(ICCWFLAGS) -xHost

CXX=clang++
CXXFLAGS=$(if $(findstring clang++, $(CXX)), $(CLANGCXXFLAGS), \
            $(if $(findstring icc, $(CXX)), $(ICC_CXXFLAGS), $(COMMON_CXXFLAGS)))
LDFLAGS=-ldl -g

LD=$(CXX)

NVCC?=nvcc
NVCCXXFLAGS=-std=c++11 -O3 -g -G -lineinfo
NVCCARCHFLAGS= \
    -gencode arch=compute_20,code=sm_20 \
    -gencode arch=compute_20,code=sm_21 \
    -gencode arch=compute_30,code=sm_30 \
    -gencode arch=compute_35,code=sm_35 \
    -gencode arch=compute_50,code=sm_50 \
    -gencode arch=compute_52,code=sm_52 \
    -gencode arch=compute_53,code=sm_53

NVCCHOSTCXXFLAGS?=

NVLINK=$(NVCC)
SED?=sed

BOOST_PATH?=$(HOME)/opt/

UNAME := $(shell uname -s)
ifeq ($(UNAME),Darwin)
    CXXFLAGS += -isystem$(CUDA_PATH)/include/

    NVWFLAGS = $(CLANGWFLAGS) -Wno-unused-macros -Wno-c++11-long-long \
               -Wno-old-style-cast -Wno-used-but-marked-unused \
               -Wno-unused-function -Wno-missing-variable-declarations \
               -Wno-pedantic -Wno-missing-prototypes -Wno-unused-parameter

    NVCCXXFLAGS += --compiler-options "$(NVWFLAGS) $(NVCCHOSTCXXFLAGS)" \
                 -isystem $(CUDA_PATH)/include/

endif
ifeq ($(UNAME),Linux)
    CLANGWFLAGS += -Wno-reserved-id-macro
    CLANGCXXFLAGS += --gcc-toolchain=$(addsuffix .., $(dir $(shell which gcc)))

    CXXFLAGS += -isystem$(CUDA_PATH)/include/

    NVWFLAGS =

    NVCCXXFLAGS += --compiler-options "$(NVWFLAGS) $(NVCCHOSTCXXFLAGS)"
endif

$(DEST)/:
	$(AT)mkdir -p $@

$(DEST)/%.o: %.cpp | $(DEST)/
	$(PRINTF) " CXX\t$*.cpp\n"
	$(AT)$(CXX) $(CXXFLAGS) -I. $< -c -o $@

$(DEST)/%.obj: %.cu | $(DEST)/
	$(PRINTF) " NVCC\t$*.cu\n"
	$(AT)$(NVCC) $(NVCCXXFLAGS) -M -I. $< -o $(@:.obj=.d)
	$(AT)$(SED) -i.bak "s#$(notdir $*).o#$(@)#" $(@:.obj=.d)
	$(AT)rm -f $(@:.obj=.d).bak
	$(AT)$(NVCC) $(NVCCXXFLAGS) $(NVCCARCHFLAGS) -I. --device-c $< -o $@
