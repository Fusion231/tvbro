#pragma once

#include <windows.h>

#include <cmath>
#include <string>

// Temporary, per-monitor mode change. Never writes the user's display registry.
class DisplayRefreshMatcher {
 public:
  bool Restore() {
    if (!saved_) return true;
    const LONG result = ChangeDisplaySettingsExW(
        device_.c_str(), &original_, nullptr, 0, nullptr);
    if (result == DISP_CHANGE_SUCCESSFUL) saved_ = false;
    return result == DISP_CHANGE_SUCCESSFUL;
  }

  bool Apply(HWND window, double fps) {
    if (!std::isfinite(fps) || fps < 10.0 || fps > 240.0) return Restore();
    MONITORINFOEXW monitor{};
    monitor.cbSize = sizeof(monitor);
    if (!GetMonitorInfoW(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST),
                         reinterpret_cast<MONITORINFO*>(&monitor))) return false;
    if (saved_ && device_ != monitor.szDevice && !Restore()) return false;
    DEVMODEW current{};
    current.dmSize = sizeof(current);
    if (!EnumDisplaySettingsExW(monitor.szDevice, ENUM_CURRENT_SETTINGS,
                                &current, 0)) return false;
    const auto matches = [fps](DWORD rate) {
      const double multiple = std::round(static_cast<double>(rate) / fps);
      return multiple >= 1.0 &&
             std::fabs(static_cast<double>(rate) - fps * multiple) <= 0.15;
    };
    if (matches(current.dmDisplayFrequency)) return true;
    DEVMODEW chosen{};
    bool found = false;
    for (DWORD index = 0;; ++index) {
      DEVMODEW mode{};
      mode.dmSize = sizeof(mode);
      if (!EnumDisplaySettingsExW(monitor.szDevice, index, &mode, 0)) break;
      if (mode.dmPelsWidth != current.dmPelsWidth ||
          mode.dmPelsHeight != current.dmPelsHeight ||
          mode.dmBitsPerPel != current.dmBitsPerPel ||
          mode.dmDisplayOrientation != current.dmDisplayOrientation ||
          mode.dmDisplayFlags != current.dmDisplayFlags ||
          !matches(mode.dmDisplayFrequency)) continue;
      if (!found || mode.dmDisplayFrequency < chosen.dmDisplayFrequency) {
        chosen = mode;
        found = true;
      }
    }
    if (!found) return false;
    if (ChangeDisplaySettingsExW(monitor.szDevice, &chosen, nullptr,
                                CDS_TEST, nullptr) != DISP_CHANGE_SUCCESSFUL) {
      return false;
    }
    if (ChangeDisplaySettingsExW(monitor.szDevice, &chosen, nullptr,
                                CDS_FULLSCREEN, nullptr) != DISP_CHANGE_SUCCESSFUL) {
      return false;
    }
    if (!saved_) {
      original_ = current;
      device_ = monitor.szDevice;
      saved_ = true;
    }
    return true;
  }

 private:
  bool saved_ = false;
  DEVMODEW original_{};
  std::wstring device_;
};
