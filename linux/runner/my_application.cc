#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

struct StreamWarningCall {
  FlMethodCall* method_call;
  bool responded = false;
};

static void respond_stream_warning(StreamWarningCall* call, bool accepted) {
  if (call->responded) return;
  call->responded = true;
  g_autoptr(FlValue) result = fl_value_new_bool(accepted);
  fl_method_call_respond_success(call->method_call, result, nullptr);
}

static void stream_warning_response(GtkDialog* dialog, gint response,
                                    gpointer user_data) {
  respond_stream_warning(static_cast<StreamWarningCall*>(user_data),
                         response == GTK_RESPONSE_ACCEPT);
  gtk_widget_destroy(GTK_WIDGET(dialog));
}

static void stream_warning_destroy(GtkWidget* dialog, gpointer user_data) {
  auto* call = static_cast<StreamWarningCall*>(user_data);
  respond_stream_warning(call, false);
  g_object_unref(call->method_call);
  delete call;
}

static const gchar* stream_warning_text(FlValue* args, const gchar* key) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return nullptr;
  }
  FlValue* value = fl_value_lookup_string(args, key);
  return value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_STRING
             ? fl_value_get_string(value)
             : nullptr;
}

static void native_player_method_call(FlMethodChannel* channel,
                                      FlMethodCall* method_call,
                                      gpointer user_data) {
  if (g_strcmp0(fl_method_call_get_name(method_call),
                "confirmProviderStreamWarning") != 0) {
    fl_method_call_respond_not_implemented(method_call, nullptr);
    return;
  }
  FlValue* args = fl_method_call_get_args(method_call);
  const gchar* title = stream_warning_text(args, "title");
  const gchar* message = stream_warning_text(args, "message");
  const gchar* cancel = stream_warning_text(args, "cancelLabel");
  const gchar* proceed = stream_warning_text(args, "continueLabel");
  if (title == nullptr || message == nullptr || cancel == nullptr ||
      proceed == nullptr) {
    fl_method_call_respond_error(method_call, "invalid_arguments",
                                "Missing stream warning text", nullptr, nullptr);
    return;
  }
  GtkWidget* dialog = gtk_message_dialog_new(
      GTK_WINDOW(user_data),
      static_cast<GtkDialogFlags>(GTK_DIALOG_MODAL | GTK_DIALOG_DESTROY_WITH_PARENT),
      GTK_MESSAGE_WARNING, GTK_BUTTONS_NONE, "%s", title);
  gtk_window_set_title(GTK_WINDOW(dialog), title);
  gtk_message_dialog_format_secondary_text(GTK_MESSAGE_DIALOG(dialog), "%s",
                                           message);
  gtk_dialog_add_button(GTK_DIALOG(dialog), cancel, GTK_RESPONSE_CANCEL);
  gtk_dialog_add_button(GTK_DIALOG(dialog), proceed, GTK_RESPONSE_ACCEPT);
  gtk_dialog_set_default_response(GTK_DIALOG(dialog), GTK_RESPONSE_CANCEL);
  auto* call = new StreamWarningCall{FL_METHOD_CALL(g_object_ref(method_call))};
  g_signal_connect(dialog, "response", G_CALLBACK(stream_warning_response), call);
  g_signal_connect(dialog, "destroy", G_CALLBACK(stream_warning_destroy), call);
  // The native mpv player is a separate window; keep this choice in front.
  gtk_window_set_keep_above(GTK_WINDOW(dialog), TRUE);
  gtk_widget_show(dialog);
  gtk_window_present(GTK_WINDOW(dialog));
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "IPTVS Player");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "IPTVS Player");
  }

  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  g_autoptr(FlStandardMethodCodec) native_codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) native_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "iptvs/native_hdr_player", FL_METHOD_CODEC(native_codec));
  fl_method_channel_set_method_call_handler(
      native_channel, native_player_method_call, g_object_ref(window),
      g_object_unref);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
