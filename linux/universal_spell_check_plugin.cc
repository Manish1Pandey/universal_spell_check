// Linux implementation of universal_spell_check, backed by Enchant-2.
//
// libenchant-2 is loaded at runtime with dlopen() instead of being linked,
// so apps using this plugin still start (and simply report "unavailable")
// on systems where Enchant is not installed.
//
// Channel "universal_spell_check":
//  - checkWords {words: [string], language, maxSuggestions}
//      -> [null | [string]] (null = correctly spelled), or null when Enchant
//         or a dictionary for the language is missing.
//  - resolveLanguage {language} -> string or null
//  - availableLanguages -> [string]
//
// Tokenisation happens in Dart (tokenizeWords) so UTF-16 offsets are
// computed in one tested place.

#include "include/universal_spell_check/universal_spell_check_plugin.h"

#include <dlfcn.h>
#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <sys/types.h>

#include <cstring>

// Opaque Enchant types (we never include enchant.h so that building does not
// require the Enchant development package either).
typedef struct _EnchantBroker EnchantBroker;
typedef struct _EnchantDict EnchantDict;
typedef void (*EnchantDictDescribeFn)(const char* lang_tag,
                                      const char* provider_name,
                                      const char* provider_desc,
                                      const char* provider_file,
                                      void* user_data);

typedef struct {
  EnchantBroker* (*broker_init)(void);
  void (*broker_free)(EnchantBroker* broker);
  EnchantDict* (*broker_request_dict)(EnchantBroker* broker, const char* tag);
  void (*broker_free_dict)(EnchantBroker* broker, EnchantDict* dict);
  int (*broker_dict_exists)(EnchantBroker* broker, const char* tag);
  void (*broker_list_dicts)(EnchantBroker* broker, EnchantDictDescribeFn fn,
                            void* user_data);
  int (*dict_check)(EnchantDict* dict, const char* word, ssize_t len);
  char** (*dict_suggest)(EnchantDict* dict, const char* word, ssize_t len,
                         size_t* out_n_suggs);
  void (*dict_free_string_list)(EnchantDict* dict, char** string_list);
} EnchantApi;

#define UNIVERSAL_SPELL_CHECK_PLUGIN(obj)                                  \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), universal_spell_check_plugin_get_type(), \
                              UniversalSpellCheckPlugin))

struct _UniversalSpellCheckPlugin {
  GObject parent_instance;

  gboolean load_attempted;
  void* library;  // dlopen handle, NULL when Enchant is unavailable.
  EnchantApi api;
  EnchantBroker* broker;
  // Resolved language tag (owned gchar*) -> EnchantDict* (owned by broker).
  GHashTable* dicts;
};

G_DEFINE_TYPE(UniversalSpellCheckPlugin, universal_spell_check_plugin,
              g_object_get_type())

// Loads libenchant-2 once. Returns TRUE when the API is usable.
static gboolean ensure_enchant(UniversalSpellCheckPlugin* self) {
  if (self->broker != nullptr) {
    return TRUE;
  }
  if (self->load_attempted) {
    return FALSE;
  }
  self->load_attempted = TRUE;

  const char* candidates[] = {"libenchant-2.so.2", "libenchant-2.so"};
  for (const char* name : candidates) {
    self->library = dlopen(name, RTLD_LAZY | RTLD_LOCAL);
    if (self->library != nullptr) {
      break;
    }
  }
  if (self->library == nullptr) {
    g_debug("universal_spell_check: libenchant-2 not found: %s", dlerror());
    return FALSE;
  }

#define LOAD_SYMBOL(field, symbol)                                        \
  self->api.field = reinterpret_cast<decltype(self->api.field)>(         \
      dlsym(self->library, symbol));                                      \
  if (self->api.field == nullptr) {                                       \
    g_warning("universal_spell_check: missing Enchant symbol %s", symbol); \
    dlclose(self->library);                                               \
    self->library = nullptr;                                              \
    return FALSE;                                                         \
  }

  LOAD_SYMBOL(broker_init, "enchant_broker_init")
  LOAD_SYMBOL(broker_free, "enchant_broker_free")
  LOAD_SYMBOL(broker_request_dict, "enchant_broker_request_dict")
  LOAD_SYMBOL(broker_free_dict, "enchant_broker_free_dict")
  LOAD_SYMBOL(broker_dict_exists, "enchant_broker_dict_exists")
  LOAD_SYMBOL(broker_list_dicts, "enchant_broker_list_dicts")
  LOAD_SYMBOL(dict_check, "enchant_dict_check")
  LOAD_SYMBOL(dict_suggest, "enchant_dict_suggest")
  LOAD_SYMBOL(dict_free_string_list, "enchant_dict_free_string_list")
#undef LOAD_SYMBOL

  self->broker = self->api.broker_init();
  if (self->broker == nullptr) {
    dlclose(self->library);
    self->library = nullptr;
    return FALSE;
  }
  return TRUE;
}

static void collect_dict_tag(const char* lang_tag, const char* provider_name,
                             const char* provider_desc,
                             const char* provider_file, void* user_data) {
  GPtrArray* tags = static_cast<GPtrArray*>(user_data);
  for (guint i = 0; i < tags->len; i++) {
    if (g_strcmp0(static_cast<const char*>(g_ptr_array_index(tags, i)),
                  lang_tag) == 0) {
      return;
    }
  }
  g_ptr_array_add(tags, g_strdup(lang_tag));
}

// Returns a newly allocated array of available dictionary tags.
static GPtrArray* list_dict_tags(UniversalSpellCheckPlugin* self) {
  GPtrArray* tags = g_ptr_array_new_with_free_func(g_free);
  if (ensure_enchant(self)) {
    self->api.broker_list_dicts(self->broker, collect_dict_tag, tags);
  }
  return tags;
}

// Maps a BCP-47 tag ("en-US") to an Enchant dictionary tag ("en_US"), or
// returns NULL. The result is newly allocated.
static gchar* resolve_language(UniversalSpellCheckPlugin* self,
                               const gchar* tag) {
  if (tag == nullptr || *tag == '\0' || !ensure_enchant(self)) {
    return nullptr;
  }
  g_autofree gchar* normalized = g_strdup(tag);
  g_strdelimit(normalized, "-", '_');

  g_auto(GStrv) parts = g_strsplit(normalized, "_", -1);
  const gchar* language = parts[0];
  guint n_parts = g_strv_length(parts);

  g_autofree gchar* language_region =
      n_parts >= 2 ? g_strdup_printf("%s_%s", language, parts[n_parts - 1])
                   : nullptr;
  const gchar* candidates[] = {normalized, language_region, language};
  for (const gchar* candidate : candidates) {
    if (candidate != nullptr && *candidate != '\0' &&
        self->api.broker_dict_exists(self->broker, candidate)) {
      return g_strdup(candidate);
    }
  }

  // Any regional variant of the same language ("en" -> "en_GB").
  g_autofree gchar* prefix = g_strdup_printf("%s_", language);
  g_autoptr(GPtrArray) tags = list_dict_tags(self);
  for (guint i = 0; i < tags->len; i++) {
    const gchar* available = static_cast<const gchar*>(g_ptr_array_index(tags, i));
    if (g_ascii_strncasecmp(available, prefix, strlen(prefix)) == 0) {
      return g_strdup(available);
    }
  }
  return nullptr;
}

// Returns the (cached) dictionary for a BCP-47 tag, or NULL.
static EnchantDict* dict_for(UniversalSpellCheckPlugin* self,
                             const gchar* tag) {
  g_autofree gchar* resolved = resolve_language(self, tag);
  if (resolved == nullptr) {
    return nullptr;
  }
  EnchantDict* dict =
      static_cast<EnchantDict*>(g_hash_table_lookup(self->dicts, resolved));
  if (dict != nullptr) {
    return dict;
  }
  dict = self->api.broker_request_dict(self->broker, resolved);
  if (dict != nullptr) {
    g_hash_table_insert(self->dicts, g_steal_pointer(&resolved), dict);
  }
  return dict;
}

static FlValue* lookup_arg(FlValue* args, const gchar* key,
                           FlValueType type) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return nullptr;
  }
  FlValue* value = fl_value_lookup_string(args, key);
  if (value == nullptr || fl_value_get_type(value) != type) {
    return nullptr;
  }
  return value;
}

static FlMethodResponse* check_words(UniversalSpellCheckPlugin* self,
                                     FlValue* args) {
  FlValue* words = lookup_arg(args, "words", FL_VALUE_TYPE_LIST);
  FlValue* language = lookup_arg(args, "language", FL_VALUE_TYPE_STRING);
  if (words == nullptr || language == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "bad_arguments", "checkWords needs 'words' and 'language'", nullptr));
  }
  int64_t max_suggestions = 5;
  FlValue* max_value = lookup_arg(args, "maxSuggestions", FL_VALUE_TYPE_INT);
  if (max_value != nullptr) {
    max_suggestions = fl_value_get_int(max_value);
    if (max_suggestions < 0) max_suggestions = 0;
  }

  EnchantDict* dict = dict_for(self, fl_value_get_string(language));
  if (dict == nullptr) {
    // null: Enchant or a dictionary for this language is not installed.
    g_autoptr(FlValue) none = fl_value_new_null();
    return FL_METHOD_RESPONSE(fl_method_success_response_new(none));
  }

  g_autoptr(FlValue) results = fl_value_new_list();
  const size_t count = fl_value_get_length(words);
  for (size_t i = 0; i < count; i++) {
    FlValue* item = fl_value_get_list_value(words, i);
    if (fl_value_get_type(item) != FL_VALUE_TYPE_STRING) {
      fl_value_append_take(results, fl_value_new_null());
      continue;
    }
    const gchar* word = fl_value_get_string(item);
    // 0 = correct, > 0 = misspelled, < 0 = error (treated as correct so a
    // broken provider never floods the text with marks).
    if (*word == '\0' || !g_utf8_validate(word, -1, nullptr) ||
        self->api.dict_check(dict, word, -1) <= 0) {
      fl_value_append_take(results, fl_value_new_null());
      continue;
    }
    FlValue* suggestions = fl_value_new_list();
    if (max_suggestions > 0) {
      size_t n = 0;
      char** list = self->api.dict_suggest(dict, word, -1, &n);
      if (list != nullptr) {
        for (size_t k = 0; k < n && static_cast<int64_t>(k) < max_suggestions;
             k++) {
          fl_value_append_take(suggestions, fl_value_new_string(list[k]));
        }
        self->api.dict_free_string_list(dict, list);
      }
    }
    fl_value_append_take(results, suggestions);
  }
  return FL_METHOD_RESPONSE(fl_method_success_response_new(results));
}

static FlMethodResponse* resolve_language_response(
    UniversalSpellCheckPlugin* self, FlValue* args) {
  FlValue* language = lookup_arg(args, "language", FL_VALUE_TYPE_STRING);
  if (language == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "bad_arguments", "resolveLanguage needs 'language'", nullptr));
  }
  g_autofree gchar* resolved =
      resolve_language(self, fl_value_get_string(language));
  g_autoptr(FlValue) result = resolved != nullptr
                                  ? fl_value_new_string(resolved)
                                  : fl_value_new_null();
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* available_languages(UniversalSpellCheckPlugin* self) {
  g_autoptr(GPtrArray) tags = list_dict_tags(self);
  g_autoptr(FlValue) result = fl_value_new_list();
  for (guint i = 0; i < tags->len; i++) {
    fl_value_append_take(
        result,
        fl_value_new_string(static_cast<const gchar*>(g_ptr_array_index(tags, i))));
  }
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

// Called when a method call is received from Flutter.
static void universal_spell_check_plugin_handle_method_call(
    UniversalSpellCheckPlugin* self, FlMethodCall* method_call) {
  g_autoptr(FlMethodResponse) response = nullptr;

  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);

  if (strcmp(method, "checkWords") == 0) {
    response = check_words(self, args);
  } else if (strcmp(method, "resolveLanguage") == 0) {
    response = resolve_language_response(self, args);
  } else if (strcmp(method, "availableLanguages") == 0) {
    response = available_languages(self);
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
}

static void free_dict_entry(gpointer key, gpointer value, gpointer user_data) {
  UniversalSpellCheckPlugin* self =
      static_cast<UniversalSpellCheckPlugin*>(user_data);
  self->api.broker_free_dict(self->broker, static_cast<EnchantDict*>(value));
}

static void universal_spell_check_plugin_dispose(GObject* object) {
  UniversalSpellCheckPlugin* self = UNIVERSAL_SPELL_CHECK_PLUGIN(object);
  if (self->dicts != nullptr) {
    if (self->broker != nullptr) {
      g_hash_table_foreach(self->dicts, free_dict_entry, self);
    }
    g_clear_pointer(&self->dicts, g_hash_table_destroy);
  }
  if (self->broker != nullptr) {
    self->api.broker_free(self->broker);
    self->broker = nullptr;
  }
  if (self->library != nullptr) {
    dlclose(self->library);
    self->library = nullptr;
  }
  G_OBJECT_CLASS(universal_spell_check_plugin_parent_class)->dispose(object);
}

static void universal_spell_check_plugin_class_init(
    UniversalSpellCheckPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = universal_spell_check_plugin_dispose;
}

static void universal_spell_check_plugin_init(UniversalSpellCheckPlugin* self) {
  self->load_attempted = FALSE;
  self->library = nullptr;
  memset(&self->api, 0, sizeof(self->api));
  self->broker = nullptr;
  self->dicts = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, nullptr);
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data) {
  UniversalSpellCheckPlugin* plugin = UNIVERSAL_SPELL_CHECK_PLUGIN(user_data);
  universal_spell_check_plugin_handle_method_call(plugin, method_call);
}

void universal_spell_check_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  UniversalSpellCheckPlugin* plugin = UNIVERSAL_SPELL_CHECK_PLUGIN(
      g_object_new(universal_spell_check_plugin_get_type(), nullptr));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            "universal_spell_check", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      channel, method_call_cb, g_object_ref(plugin), g_object_unref);

  g_object_unref(plugin);
}
