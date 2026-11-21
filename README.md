# Clear Charge

<img src="icon.png" alt="Clear Charge icon" width="160">

Clear Charge removes the battery outline and percent sign when Battery Percentage is enabled. You get a plain number on the Home Screen, Lock Screen and in apps, with a bolt beside it when connected to power. The number stays in place when you plug in or unplug. The bolt dims when charging is on hold and the number turns amber in Low Power Mode.

Targets iOS 16 and later with a compatible battery renderer. Tested on iOS 26.0.1 with RootHide.

Enable Battery Percentage in iOS Settings, install the matching package from [Releases](https://github.com/sahinkaa/ClearCharge/releases) and respring.

Build with `make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless`. For RootHide, use RootHide Theos and set `THEOS_PACKAGE_SCHEME=roothide`.
