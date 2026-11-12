# Binaire universel (Apple Silicon + Intel), sans dépendance tierce.
ARCHS ?= -arch arm64 -arch x86_64
MINOS ?= -mmacosx-version-min=11.0
CFLAGS += -O2 -Wall -Wextra -Wno-unused-result -fobjc-arc $(ARCHS) $(MINOS)
FRAMEWORKS = -framework Foundation -framework IOKit -framework IOUSBHost

ds720d-usbd: ds720d-usbd.m
	$(CC) $(CFLAGS) -o $@ $< $(FRAMEWORKS)
	codesign -s - -f -o runtime --entitlements usbd.entitlements $@

clean:
	rm -f ds720d-usbd
