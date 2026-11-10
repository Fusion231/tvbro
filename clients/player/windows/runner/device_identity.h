#ifndef RUNNER_DEVICE_IDENTITY_H_
#define RUNNER_DEVICE_IDENTITY_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

// Returns platform scope only to the in-process Dart channel. Dart hashes it
// before pairing; the scope is neither logged nor an account credential.
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
CreateDeviceIdentityChannel(flutter::BinaryMessenger* messenger);

#endif  // RUNNER_DEVICE_IDENTITY_H_
