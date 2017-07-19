ROOTDIR = $(CURDIR)

ifndef config
ifneq ("$(wildcard ./config.mk)","")
	config ?= config.mk
else
	config ?= make/config.mk
endif
endif

include $(config)

.PHONY: clean all test doc pylint cpplint lint verilog cython cython2 cython3 web runtime

BUILD_TARGETS ?= lib/libtvm.so lib/libtvm_runtime.so
all: ${BUILD_TARGETS}
runtime: lib/libtvm_runtime.so
web: lib/libtvm_web_runtime.js lib/libtvm_web_runtime.bc

ifndef DMLC_CORE_PATH
  DMLC_CORE_PATH = $(ROOTDIR)/dmlc-core
endif

ifndef DLPACK_PATH
  DLPACK_PATH = $(ROOTDIR)/dlpack
endif

# The source code dependencies
LIB_HALIDEIR = HalideIR/lib/libHalideIR.a

CC_SRC = $(filter-out src/contrib/%.cc src/runtime/%.cc,\
             $(wildcard src/*/*.cc src/*/*/*.cc))
METAL_SRC = $(wildcard src/runtime/metal/*.mm)
CUDA_SRC = $(wildcard src/runtime/cuda/*.cc)
OPENCL_SRC = $(wildcard src/runtime/opencl/*.cc)
RPC_SRC = $(wildcard src/runtime/rpc/*.cc)
RUNTIME_SRC = $(wildcard src/runtime/*.cc)

# Objectives
METAL_OBJ = $(patsubst src/%.mm, build/%.o, $(METAL_SRC))
CUDA_OBJ = $(patsubst src/%.cc, build/%.o, $(CUDA_SRC))
OPENCL_OBJ = $(patsubst src/%.cc, build/%.o, $(OPENCL_SRC))
RPC_OBJ = $(patsubst src/%.cc, build/%.o, $(RPC_SRC))
CC_OBJ = $(patsubst src/%.cc, build/%.o, $(CC_SRC))
RUNTIME_OBJ = $(patsubst src/%.cc, build/%.o, $(RUNTIME_SRC))
CONTRIB_OBJ =

UNAME_S := $(shell uname -s)

# Deps
ALL_DEP = $(CC_OBJ) $(CONTRIB_OBJ) $(LIB_HALIDEIR)
RUNTIME_DEP = $(RUNTIME_OBJ)

# The flags
LDFLAGS = -pthread -lm -ldl
INCLUDE_FLAGS = -Iinclude -I$(DLPACK_PATH)/include -I$(DMLC_CORE_PATH)/include -IHalideIR/src -Itopi/include
CFLAGS = -std=c++11 -Wall -O2 $(INCLUDE_FLAGS) -fPIC
LLVM_CFLAGS= -fno-rtti -DDMLC_ENABLE_RTTI=0
FRAMEWORKS =
OBJCFLAGS = -fno-objc-arc
EMCC_FLAGS= -s RESERVED_FUNCTION_POINTERS=2 -s NO_EXIT_RUNTIME=1 -s MAIN_MODULE=1 -DDMLC_LOG_STACK_TRACE=0\
	 -std=c++11 -Oz $(INCLUDE_FLAGS)

# Dependency specific rules
ifdef CUDA_PATH
	NVCC=$(CUDA_PATH)/bin/nvcc
	CFLAGS += -I$(CUDA_PATH)/include
	LDFLAGS += -L$(CUDA_PATH)/lib64
endif

ifeq ($(USE_CUDA), 1)
	CFLAGS += -DTVM_CUDA_RUNTIME=1
	LDFLAGS += -lcuda -lcudart -lnvrtc
	RUNTIME_DEP += $(CUDA_OBJ)
else
	CFLAGS += -DTVM_CUDA_RUNTIME=0
endif

ifeq ($(USE_OPENCL), 1)
	CFLAGS += -DTVM_OPENCL_RUNTIME=1
	ifeq ($(UNAME_S), Darwin)
		FRAMEWORKS += -framework OpenCL
	else
		LDFLAGS += -lOpenCL
	endif
	RUNTIME_DEP += $(OPENCL_OBJ)
else
	CFLAGS += -DTVM_OPENCL_RUNTIME=0
endif

ifeq ($(USE_METAL), 1)
	CFLAGS += -DTVM_METAL_RUNTIME=1
	LDFLAGS += -lObjc
	RUNTIME_DEP += $(METAL_OBJ)
	FRAMEWORKS += -framework Metal -framework Foundation
else
	CFLAGS += -DTVM_METAL_RUNTIME=0
endif

ifeq ($(USE_RPC), 1)
	RUNTIME_DEP += $(RPC_OBJ)
endif

# llvm configuration
ifdef LLVM_CONFIG
	LLVM_VERSION=$(shell $(LLVM_CONFIG) --version| cut -b 1,3)
	LLVM_INCLUDE=$(filter -I%, $(shell $(LLVM_CONFIG) --cxxflags))
	LDFLAGS += $(shell $(LLVM_CONFIG) --ldflags --libs --system-libs)
	LLVM_CFLAGS += $(LLVM_INCLUDE) -DTVM_LLVM_VERSION=$(LLVM_VERSION)
endif

include make/contrib/cblas.mk
include make/contrib/nnpack.mk

ifdef ADD_CFLAGS
	CFLAGS += $(ADD_CFLAGS)
endif

ifdef ADD_LDFLAGS
	LDFLAGS += $(ADD_LDFLAGS)
endif

ifeq ($(OS),Windows_NT)
	JVM_PKG_PROFILE := windows
else
	UNAME_S := $(shell uname -s)
	ifeq ($(UNAME_S), Darwin)
		JVM_PKG_PROFILE := osx-x86_64
	else
		JVM_PKG_PROFILE := linux-x86_64
	endif
endif

JVM_TEST_ARGS := $(if $(JVM_TEST_ARGS),$(JVM_TEST_ARGS),-DskipTests -Dcheckstyle.skip=true)

ifeq ($(USE_CUDA), 1)
	JVM_PKG_PROFILE := $(JVM_PKG_PROFILE)-gpu
else ifeq ($(USE_OPENCL), 1)
	JVM_PKG_PROFILE := $(JVM_PKG_PROFILE)-gpu
else ifeq ($(USE_METAL), 1)
	JVM_PKG_PROFILE := $(JVM_PKG_PROFILE)-gpu
else
	JVM_PKG_PROFILE := $(JVM_PKG_PROFILE)-cpu
endif

include tests/cpp/unittest.mk

test: $(TEST)

include verilog/verilog.mk
verilog: $(VER_LIBS)


# Special rules for LLVM related modules.
build/codegen/llvm/%.o: src/codegen/llvm/%.cc
	@mkdir -p $(@D)
	$(CXX) $(CFLAGS) -MM -MT build/codegen/llvm/$*.o $< >build/codegen/llvm/$*.d
	$(CXX) -c $(CFLAGS) $(LLVM_CFLAGS) -c $< -o $@

build/runtime/metal/%.o: src/runtime/metal/%.mm
	@mkdir -p $(@D)
	$(CXX) $(CFLAGS) -MM -MT build/runtime/metal/$*.o $< >build/runtime/metal/$*.d
	$(CXX) $(OBJCFLAGS) -c $(CFLAGS) -c $< -o $@

build/%.o: src/%.cc
	@mkdir -p $(@D)
	$(CXX) $(CFLAGS) -MM -MT build/$*.o $< >build/$*.d
	$(CXX) -c $(CFLAGS) -c $< -o $@

lib/libtvm.so: $(ALL_DEP) $(RUNTIME_DEP)
	@mkdir -p $(@D)
	$(CXX) $(CFLAGS) $(FRAMEWORKS) -shared -o $@ $(filter %.o %.a, $^) $(LDFLAGS)

lib/libtvm_runtime.so: $(RUNTIME_DEP)
	@mkdir -p $(@D)
	$(CXX) $(CFLAGS) $(FRAMEWORKS) -shared -o $@ $(filter %.o %.a, $^) $(LDFLAGS)

lib/libtvm_web_runtime.bc: web/web_runtime.cc
	@mkdir -p build/web
	@mkdir -p $(@D)
	$(CXX) $(CFLAGS) -MM -MT lib/libtvm_web_runtime.bc $< >build/web/web_runtime.d
	emcc $(EMCC_FLAGS) -o $@ web/web_runtime.cc

lib/libtvm_web_runtime.js: lib/libtvm_web_runtime.bc
	@mkdir -p $(@D)
	emcc $(EMCC_FLAGS) -o $@ lib/libtvm_web_runtime.bc

$(LIB_HALIDEIR): LIBHALIDEIR

LIBHALIDEIR:
	+ cd HalideIR; make lib/libHalideIR.a ; cd $(ROOTDIR)

cpplint:
	python dmlc-core/scripts/lint.py topi cpp topi/include;
	python dmlc-core/scripts/lint.py tvm cpp include src verilog\
	 examples/extension/src examples/graph_executor/src

pylint:
	pylint python/tvm --rcfile=$(ROOTDIR)/tests/lint/pylintrc
	pylint topi/python/topi --rcfile=$(ROOTDIR)/tests/lint/pylintrc

jnilint:
	python dmlc-core/scripts/lint.py tvm4j-jni cpp jvm/native/src

lint: cpplint pylint jnilint

doc:
	doxygen docs/Doxyfile

# Cython build
cython:
	cd python; python setup.py build_ext --inplace

cython2:
	cd python; python2 setup.py build_ext --inplace

cython3:
	cd python; python3 setup.py build_ext --inplace

cyclean:
	rm -rf python/tvm/*/*/*.so python/tvm/*/*/*.cpp

jvmpkg:
	(cd $(ROOTDIR)/jvm; \
		mvn clean package -P$(JVM_PKG_PROFILE) -Dcxx="$(CXX)" \
			-Dcflags="$(CFLAGS)" -Dldflags="$(LDFLAGS)" \
			-Dcurrent_libdir="$(ROOTDIR)/lib" $(JVM_TEST_ARGS))

clean:
	$(RM) -rf build lib bin *~ */*~ */*/*~ */*/*/*~ */*.o */*/*.o */*/*/*.o */*.d */*/*.d */*/*/*.d
	cd HalideIR; make clean; cd $(ROOTDIR)

-include build/*.d
-include build/*/*.d
-include build/*/*/*.d
