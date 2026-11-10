#include "device_identity.h"

#include <windows.h>
#include <roapi.h>
#include <sddl.h>
#include <winrt/Windows.Security.Cryptography.h>
#include <winrt/Windows.Storage.Streams.h>
#include <winrt/Windows.System.Profile.h>

#include <optional>
#include <string>
#include <vector>

#include <flutter/standard_method_codec.h>

namespace {

std::string CurrentUserSid() {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return {};
  DWORD size = 0;
  GetTokenInformation(token, TokenUser, nullptr, 0, &size);
  if (size == 0) {
    CloseHandle(token);
    return {};
  }
  std::vector<BYTE> buffer(size);
  const BOOL read = GetTokenInformation(token, TokenUser, buffer.data(), size, &size);
  CloseHandle(token);
  if (!read) return {};
  const auto* user = reinterpret_cast<const TOKEN_USER*>(buffer.data());
  LPWSTR sid = nullptr;
  if (!ConvertSidToStringSidW(user->User.Sid, &sid)) return {};
  const std::wstring value(sid);
  LocalFree(sid);
  return winrt::to_string(value);
}

std::optional<std::string> StableIdentityScope() {
  const auto sid = CurrentUserSid();
  if (sid.empty()) return std::nullopt;
  // The runner already uses a single-threaded COM apartment. Balance this
  // WinRT initialization locally without changing its lifetime.
  if (FAILED(RoInitialize(RO_INIT_SINGLETHREADED))) return std::nullopt;
  std::optional<std::string> scope;
  try {
    using winrt::Windows::System::Profile::SystemIdentification;
    using winrt::Windows::System::Profile::SystemIdentificationSource;
    const auto info = SystemIdentification::GetSystemIdForPublisher();
    if (info && info.Source() != SystemIdentificationSource::None &&
        info.Id() && info.Id().Length() > 0) {
      const auto hex = winrt::Windows::Security::Cryptography::CryptographicBuffer::
          EncodeToHexString(info.Id());
      // Publisher ID alone spans Windows users (and is generic for unpackaged
      // apps). Add the current user's SID and TVBro app scope before Dart hashes.
      scope = "app.tvbro.player|" + winrt::to_string(hex) + "|" + sid;
    }
  } catch (...) {
    // No restricted userSystemId capability, hardware/MAC fallback or raw logs.
  }
  RoUninitialize();
  return scope;
}

}  // namespace

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
CreateDeviceIdentityChannel(flutter::BinaryMessenger* messenger) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "iptvs/device", &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() != "stableIdentity") {
          result->NotImplemented();
          return;
        }
        const auto scope = StableIdentityScope();
        result->Success(scope ? flutter::EncodableValue(*scope)
                              : flutter::EncodableValue());
      });
  return channel;
}
