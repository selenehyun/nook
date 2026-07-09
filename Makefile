PROJECT := Nook.xcodeproj
SCHEME := Nook
DESTINATION := platform=macOS
DERIVED_DATA_PATH := DerivedData
BUILD_FLAGS := CODE_SIGNING_ALLOWED=NO

.PHONY: build clean open

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DESTINATION)' -derivedDataPath $(DERIVED_DATA_PATH) $(BUILD_FLAGS) build

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED_DATA_PATH) clean

open:
	xed .
