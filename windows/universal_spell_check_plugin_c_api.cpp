#include "include/universal_spell_check/universal_spell_check_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "universal_spell_check_plugin.h"

void UniversalSpellCheckPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  universal_spell_check::UniversalSpellCheckPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
