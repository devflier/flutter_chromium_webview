#include "include/dummy_plugin/dummy_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "dummy_plugin.h"

void DummyPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  dummy_plugin::DummyPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
