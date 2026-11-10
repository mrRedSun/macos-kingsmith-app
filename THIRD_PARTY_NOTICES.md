# Protocol references

The interoperability research in [Mwea/walkingpad-js](https://github.com/Mwea/walkingpad-js), revision `d4d48ba4b879a1ebc56dae1071bd0907be426923`, informed this client's C2 support, particularly the optional two-byte step-count suffix.

That project's material is licensed under [Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International](https://creativecommons.org/licenses/by-nc-sa/4.0/). Its [license notice](https://github.com/Mwea/walkingpad-js/blob/d4d48ba4b879a1ebc56dae1071bd0907be426923/LICENSE) reads "Copyright (c) 2024" and does not name a copyright holder. Attribution here does not imply endorsement.

This client contains a separate Swift implementation. It neither bundles nor executes the upstream JavaScript/TypeScript implementation. Differences include standard FTMS flag handling, opt-in step decoding, control-point acknowledgement handling, a priority Stop queue, and native SQLite persistence.

The legacy FE00 characteristic roles, status query, and motor command frames follow [ph4r05/ph4-walkingpad](https://github.com/ph4r05/ph4-walkingpad), revision `3a2e37bace91122cab0592cdf382255e6bece0ac`, MIT license. This client re-implements them in Swift and does not include that project's code. A KS-BDC2 confirmed the characteristic roles, status query, manual mode, Start, speed, and Stop frames. It also showed that Start must follow manual mode after a short delay. The stored-walk query `F7 A7 AA FF 50 FD` also follows that library. On KS-BDC2 its `F8 A7` reply holds a walk ID (start time on the pad's clock), time, distance, and steps; that layout was worked out from KS-BDC2 captures.

Bluetooth Fitness Machine Service identifiers and field definitions are Bluetooth SIG protocol definitions. Bluetooth and its marks belong to their respective owners. WalkingPad and KingSmith names identify compatible equipment; this is not an official product.

Before redistributing code derived from upstream material, review that material's noncommercial and share-alike conditions. This notice does not grant rights beyond those of the respective rights holders.
