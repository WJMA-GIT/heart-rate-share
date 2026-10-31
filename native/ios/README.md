# iOS native shell

The Xcode target is not generated in this round. When adding it, register
`HrsPlugin.swift`, add `NSBluetoothAlwaysUsageDescription`, and declare
`bluetooth-central` only when background HRS collection is enabled. Local
network use also requires `NSLocalNetworkUsageDescription` and Bonjour service
entries. The current Dart source deliberately reports unsupported on iOS.
