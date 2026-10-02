# Out-of-tree build of two 7.2.8 modules with the 7.3 PX13 fixes applied:
#   snd-soc-tas2783-sdw  (codecs/)    stereo split, port power-up, read-only regs
#   snd-soc-sdw-utils    (sdw_utils/) re-prepare the stream on PCM resume
# codecs/rt1308.h is only there for sdw_utils/soc_sdw_rt_amp.c.

obj-m := snd-soc-tas2783-sdw.o snd-soc-sdw-utils.o
snd-soc-tas2783-sdw-y := codecs/tas2783-sdw.o
snd-soc-sdw-utils-y := sdw_utils/soc_sdw_utils.o sdw_utils/soc_sdw_dmic.o \
	sdw_utils/soc_sdw_rt_dmic.o sdw_utils/soc_sdw_rt700.o \
	sdw_utils/soc_sdw_rt711.o sdw_utils/soc_sdw_rt5682.o \
	sdw_utils/soc_sdw_rt_sdca_jack_common.o sdw_utils/soc_sdw_rt_amp.o \
	sdw_utils/soc_sdw_rt_mf_sdca.o sdw_utils/soc_sdw_bridge_cs35l56.o \
	sdw_utils/soc_sdw_cs42l42.o sdw_utils/soc_sdw_cs42l43.o \
	sdw_utils/soc_sdw_cs42l45.o sdw_utils/soc_sdw_cs47l47.o \
	sdw_utils/soc_sdw_cs_amp.o sdw_utils/soc_sdw_es9356.o \
	sdw_utils/soc_sdw_maxim.o sdw_utils/soc_sdw_ti_amp.o

KVER ?= $(shell uname -r)
KDIR ?= /lib/modules/$(KVER)/build
ifneq ($(shell grep -s '^CONFIG_CC_IS_CLANG=y' $(KDIR)/.config),)
LLVM_FLAG := LLVM=1
endif

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) $(LLVM_FLAG) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) $(LLVM_FLAG) clean
