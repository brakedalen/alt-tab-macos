#!/bin/bash

xcodebuild \
  -project alt-tab-macos.xcodeproj \
  -scheme "AltTab dev" \
  -configuration Release \
  -derivedDataPath DerivedData \
  -jobs 4
