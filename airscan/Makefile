# Binaire universel (Apple Silicon + Intel) du serveur AirScan, sans dépendance tierce.
SRC = $(wildcard *.swift)
SWIFTFLAGS = -swift-version 5 -O

ds720d-airscan: $(SRC)
	swiftc $(SWIFTFLAGS) -target arm64-apple-macos11 -o $@.arm64 $(SRC)
	swiftc $(SWIFTFLAGS) -target x86_64-apple-macos11 -o $@.x86_64 $(SRC)
	lipo -create -output $@ $@.arm64 $@.x86_64
	rm -f $@.arm64 $@.x86_64
	codesign -s - -f -o runtime $@

clean:
	rm -f ds720d-airscan ds720d-airscan.arm64 ds720d-airscan.x86_64
