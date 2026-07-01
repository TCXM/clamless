#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct __IOMobileFramebuffer *IOMobileFramebufferRef;
typedef CGSize IOMobileFramebufferDisplaySize;

typedef CGError (*SLSGetDisplayListFn)(uint32_t maxDisplays,
                                       CGDirectDisplayID *displays,
                                       uint32_t *displayCount);
typedef CGError (*SLSConfigureDisplayEnabledFn)(CGDisplayConfigRef config,
                                                CGDirectDisplayID display,
                                                bool enabled);

typedef kern_return_t (*IOMobileFramebufferOpenFn)(io_service_t service,
                                                   task_port_t owningTask,
                                                   unsigned int type,
                                                   IOMobileFramebufferRef *pointer);
typedef kern_return_t (*IOMobileFramebufferGetIDFn)(IOMobileFramebufferRef pointer,
                                                   uint32_t *outID);
typedef kern_return_t (*IOMobileFramebufferGetDisplaySizeFn)(IOMobileFramebufferRef pointer,
                                                            IOMobileFramebufferDisplaySize *size);
typedef kern_return_t (*IOMobileFramebufferRequestPowerChangeFn)(IOMobileFramebufferRef pointer,
                                                                uint32_t value);

typedef struct {
    void *handle;
    SLSGetDisplayListFn get_display_list;
    SLSConfigureDisplayEnabledFn configure_display_enabled;
} SkyLightAPI;

typedef struct {
    void *handle;
    IOMobileFramebufferOpenFn open;
    IOMobileFramebufferGetIDFn get_id;
    IOMobileFramebufferGetDisplaySizeFn get_display_size;
    IOMobileFramebufferRequestPowerChangeFn request_power_change;
} IOMFBAPI;

typedef enum {
    COMMIT_AUTO = 0,
    COMMIT_SESSION,
    COMMIT_PERMANENT,
    COMMIT_APP_ONLY
} CommitPreference;

static int commit_options_for_preference(CommitPreference preference,
                                         CGConfigureOption *options,
                                         size_t max_options);

static const char *yes_no(bool value) {
    return value ? "yes" : "no";
}

static const char *commit_name(CGConfigureOption option) {
    switch (option) {
        case kCGConfigureForSession: return "session";
        case kCGConfigurePermanently: return "permanent";
        case kCGConfigureForAppOnly: return "app-only";
        default: return "unknown";
    }
}

static void *load_symbol(void *handle, const char *name) {
    void *symbol = dlsym(handle, name);
    if (!symbol) {
        symbol = dlsym(RTLD_DEFAULT, name);
    }
    return symbol;
}

static bool load_skylight(SkyLightAPI *api) {
    memset(api, 0, sizeof(*api));

    const char *paths[] = {
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        "/System/Library/PrivateFrameworks/SkyLight.framework"
    };

    for (size_t i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        api->handle = dlopen(paths[i], RTLD_LAZY);
        if (api->handle) {
            break;
        }
    }

    if (!api->handle) {
        fprintf(stderr, "SkyLight dlopen failed: %s\n", dlerror());
        return false;
    }

    api->get_display_list = (SLSGetDisplayListFn)load_symbol(api->handle, "SLSGetDisplayList");
    api->configure_display_enabled =
        (SLSConfigureDisplayEnabledFn)load_symbol(api->handle, "SLSConfigureDisplayEnabled");

    if (!api->get_display_list || !api->configure_display_enabled) {
        fprintf(stderr,
                "missing SkyLight symbols: SLSGetDisplayList=%p SLSConfigureDisplayEnabled=%p\n",
                (void *)api->get_display_list,
                (void *)api->configure_display_enabled);
        return false;
    }

    return true;
}

static bool load_iomfb(IOMFBAPI *api) {
    memset(api, 0, sizeof(*api));

    const char *path = "/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer";
    api->handle = dlopen(path, RTLD_LAZY);
    if (!api->handle) {
        fprintf(stderr, "IOMobileFramebuffer dlopen failed: %s\n", dlerror());
        return false;
    }

    api->open = (IOMobileFramebufferOpenFn)dlsym(api->handle, "IOMobileFramebufferOpen");
    api->get_id = (IOMobileFramebufferGetIDFn)dlsym(api->handle, "IOMobileFramebufferGetID");
    api->get_display_size =
        (IOMobileFramebufferGetDisplaySizeFn)dlsym(api->handle, "IOMobileFramebufferGetDisplaySize");
    api->request_power_change =
        (IOMobileFramebufferRequestPowerChangeFn)dlsym(api->handle, "IOMobileFramebufferRequestPowerChange");

    if (!api->open || !api->request_power_change) {
        fprintf(stderr,
                "missing IOMobileFramebuffer symbols: open=%p requestPowerChange=%p\n",
                (void *)api->open,
                (void *)api->request_power_change);
        return false;
    }

    return true;
}

static bool cf_string_to_c(CFTypeRef value, char *buf, size_t len) {
    if (!value || CFGetTypeID(value) != CFStringGetTypeID()) {
        return false;
    }
    return CFStringGetCString((CFStringRef)value, buf, len, kCFStringEncodingUTF8);
}

static bool cf_number_to_i64(CFTypeRef value, int64_t *out) {
    if (!value || CFGetTypeID(value) != CFNumberGetTypeID()) {
        return false;
    }
    return CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, out);
}

static CFTypeRef copy_prop(io_service_t service, const char *name) {
    CFStringRef key = CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
    if (!key) {
        return NULL;
    }
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    CFRelease(key);
    return value;
}

static bool dict_get_string(CFDictionaryRef dict, const char *key, char *buf, size_t len) {
    CFStringRef cf_key = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    if (!cf_key) {
        return false;
    }
    CFTypeRef value = CFDictionaryGetValue(dict, cf_key);
    CFRelease(cf_key);
    return cf_string_to_c(value, buf, len);
}

static bool dict_get_i64(CFDictionaryRef dict, const char *key, int64_t *out) {
    CFStringRef cf_key = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    if (!cf_key) {
        return false;
    }
    CFTypeRef value = CFDictionaryGetValue(dict, cf_key);
    CFRelease(cf_key);
    return cf_number_to_i64(value, out);
}

static bool get_io_name_matched(io_service_t service, char *buf, size_t len) {
    CFTypeRef value = copy_prop(service, "IONameMatched");
    bool ok = cf_string_to_c(value, buf, len);
    if (value) {
        CFRelease(value);
    }
    return ok;
}

static bool service_is_builtin_candidate(io_service_t service) {
    char name_matched[256] = {0};
    if (get_io_name_matched(service, name_matched, sizeof(name_matched)) &&
        strncmp(name_matched, "disp0", 5) == 0) {
        return true;
    }

    CFTypeRef attrs_value = copy_prop(service, "DisplayAttributes");
    if (!attrs_value || CFGetTypeID(attrs_value) != CFDictionaryGetTypeID()) {
        if (attrs_value) {
            CFRelease(attrs_value);
        }
        return false;
    }

    bool result = false;
    CFDictionaryRef attrs = (CFDictionaryRef)attrs_value;
    CFTypeRef product_value = CFDictionaryGetValue(attrs, CFSTR("ProductAttributes"));
    if (product_value && CFGetTypeID(product_value) == CFDictionaryGetTypeID()) {
        char manufacturer[128] = {0};
        if (dict_get_string((CFDictionaryRef)product_value,
                            "ManufacturerID",
                            manufacturer,
                            sizeof(manufacturer))) {
            result = strcmp(manufacturer, "00-10-fa") == 0;
        }
    }

    CFRelease(attrs_value);
    return result;
}

static void print_iomfb_power_props(io_service_t service) {
    CFTypeRef value = copy_prop(service, "IOPowerManagement");
    if (value && CFGetTypeID(value) == CFDictionaryGetTypeID()) {
        int64_t current = -1;
        int64_t max = -1;
        if (dict_get_i64((CFDictionaryRef)value, "CurrentPowerState", &current)) {
            printf(" current_power=%lld", (long long)current);
        }
        if (dict_get_i64((CFDictionaryRef)value, "MaxPowerState", &max)) {
            printf(" max_power=%lld", (long long)max);
        }
    }
    if (value) {
        CFRelease(value);
    }

    value = copy_prop(service, "IdleState");
    int64_t idle = -1;
    if (cf_number_to_i64(value, &idle)) {
        printf(" idle_state=%lld", (long long)idle);
    }
    if (value) {
        CFRelease(value);
    }
}

static int collect_iomfb_services(io_service_t **out_services, int *out_count) {
    *out_services = NULL;
    *out_count = 0;

    CFMutableDictionaryRef match = IOServiceMatching("IOMobileFramebuffer");
    if (!match) {
        fprintf(stderr, "IOServiceMatching(IOMobileFramebuffer) failed\n");
        return 2;
    }

    io_iterator_t iter = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "IOServiceGetMatchingServices failed: 0x%x\n", kr);
        return 2;
    }

    int capacity = 8;
    int count = 0;
    io_service_t *services = calloc((size_t)capacity, sizeof(io_service_t));
    if (!services) {
        IOObjectRelease(iter);
        return 2;
    }

    io_service_t service;
    while ((service = IOIteratorNext(iter))) {
        if (count == capacity) {
            capacity *= 2;
            io_service_t *next = realloc(services, (size_t)capacity * sizeof(io_service_t));
            if (!next) {
                IOObjectRelease(service);
                break;
            }
            services = next;
        }
        services[count++] = service;
    }

    IOObjectRelease(iter);
    *out_services = services;
    *out_count = count;
    return 0;
}

static int find_builtin_iomfb_index(io_service_t *services, int count) {
    int fallback = -1;
    for (int i = 0; i < count; i++) {
        if (!service_is_builtin_candidate(services[i])) {
            continue;
        }

        if (fallback < 0) {
            fallback = i;
        }

        char name_matched[256] = {0};
        if (get_io_name_matched(services[i], name_matched, sizeof(name_matched)) &&
            strncmp(name_matched, "disp0", 5) == 0) {
            return i;
        }
    }
    return fallback;
}

static void release_iomfb_services(io_service_t *services, int count) {
    if (!services) {
        return;
    }
    for (int i = 0; i < count; i++) {
        IOObjectRelease(services[i]);
    }
    free(services);
}

static int collect_sls_displays(SkyLightAPI *sky,
                                CGDirectDisplayID **out_displays,
                                uint32_t *out_count) {
    *out_displays = NULL;
    *out_count = 0;

    uint32_t count = 0;
    CGError err = sky->get_display_list(0, NULL, &count);
    if (err != kCGErrorSuccess) {
        fprintf(stderr, "SLSGetDisplayList(count) failed: %d\n", err);
        return 2;
    }
    if (count == 0) {
        return 0;
    }

    CGDirectDisplayID *displays = calloc(count, sizeof(CGDirectDisplayID));
    if (!displays) {
        return 2;
    }

    err = sky->get_display_list(count, displays, &count);
    if (err != kCGErrorSuccess) {
        fprintf(stderr, "SLSGetDisplayList(values) failed: %d\n", err);
        free(displays);
        return 2;
    }

    *out_displays = displays;
    *out_count = count;
    return 0;
}

static bool is_active_display(CGDirectDisplayID display) {
    uint32_t count = 0;
    if (CGGetActiveDisplayList(0, NULL, &count) != kCGErrorSuccess || count == 0) {
        return false;
    }

    CGDirectDisplayID *displays = calloc(count, sizeof(CGDirectDisplayID));
    if (!displays) {
        return false;
    }

    bool found = false;
    if (CGGetActiveDisplayList(count, displays, &count) == kCGErrorSuccess) {
        for (uint32_t i = 0; i < count; i++) {
            if (displays[i] == display) {
                found = true;
                break;
            }
        }
    }

    free(displays);
    return found;
}

static bool display_has_mirror_state(CGDirectDisplayID display) {
    return CGDisplayMirrorsDisplay(display) != kCGNullDirectDisplay ||
           CGDisplayIsInMirrorSet(display) ||
           CGDisplayIsInHWMirrorSet(display);
}

static bool any_display_has_mirror_state(SkyLightAPI *sky) {
    CGDirectDisplayID *displays = NULL;
    uint32_t count = 0;
    if (collect_sls_displays(sky, &displays, &count) != 0) {
        return false;
    }

    bool mirrored = false;
    for (uint32_t i = 0; i < count; i++) {
        if (display_has_mirror_state(displays[i])) {
            mirrored = true;
            break;
        }
    }

    free(displays);
    return mirrored;
}

static int active_external_count(void) {
    uint32_t count = 0;
    if (CGGetActiveDisplayList(0, NULL, &count) != kCGErrorSuccess || count == 0) {
        return 0;
    }

    CGDirectDisplayID *displays = calloc(count, sizeof(CGDirectDisplayID));
    if (!displays) {
        return 0;
    }

    int external = 0;
    if (CGGetActiveDisplayList(count, displays, &count) == kCGErrorSuccess) {
        for (uint32_t i = 0; i < count; i++) {
            if (!CGDisplayIsBuiltin(displays[i])) {
                external++;
            }
        }
    }

    free(displays);
    return external;
}

static bool connection_mapping_entry_is_display(CFDictionaryRef entry) {
    char product[256] = {0};
    int64_t width = -1;
    int64_t height = -1;

    if (dict_get_string(entry, "ProductName", product, sizeof(product)) && product[0] != '\0') {
        return true;
    }

    return dict_get_i64(entry, "MaxW", &width) &&
           dict_get_i64(entry, "MaxH", &height) &&
           width > 0 &&
           height > 0;
}

static int physical_external_count(void) {
    CFMutableDictionaryRef match = IOServiceMatching("AppleDisplayConnectionManager");
    if (!match) {
        return -1;
    }

    io_iterator_t iter = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter);
    if (kr != KERN_SUCCESS) {
        return -1;
    }

    int total = 0;
    io_service_t service;
    while ((service = IOIteratorNext(iter))) {
        CFTypeRef mapping = copy_prop(service, "ConnectionMapping");
        if (mapping && CFGetTypeID(mapping) == CFArrayGetTypeID()) {
            CFArrayRef entries = (CFArrayRef)mapping;
            CFIndex count = CFArrayGetCount(entries);
            for (CFIndex i = 0; i < count; i++) {
                CFTypeRef entry = CFArrayGetValueAtIndex(entries, i);
                if (entry &&
                    CFGetTypeID(entry) == CFDictionaryGetTypeID() &&
                    connection_mapping_entry_is_display((CFDictionaryRef)entry)) {
                    total++;
                }
            }
        }
        if (mapping) {
            CFRelease(mapping);
        }
        IOObjectRelease(service);
    }

    IOObjectRelease(iter);
    return total;
}

static bool external_iomfb_display_key(io_service_t service, char *buf, size_t len) {
    if (service_is_builtin_candidate(service)) {
        return false;
    }

    CFTypeRef attrs_value = copy_prop(service, "DisplayAttributes");
    if (!attrs_value || CFGetTypeID(attrs_value) != CFDictionaryGetTypeID()) {
        if (attrs_value) {
            CFRelease(attrs_value);
        }
        return false;
    }

    bool ok = false;
    CFDictionaryRef attrs = (CFDictionaryRef)attrs_value;
    CFTypeRef product_value = CFDictionaryGetValue(attrs, CFSTR("ProductAttributes"));
    if (product_value && CFGetTypeID(product_value) == CFDictionaryGetTypeID()) {
        CFDictionaryRef product_attrs = (CFDictionaryRef)product_value;
        int64_t vendor = -1;
        int64_t product = -1;
        int64_t serial = 0;
        if (dict_get_i64(product_attrs, "LegacyManufacturerID", &vendor) &&
            dict_get_i64(product_attrs, "ProductID", &product)) {
            (void)dict_get_i64(product_attrs, "SerialNumber", &serial);
            ok = snprintf(buf,
                          len,
                          "cgdisplay:%lld:%lld:%lld",
                          (long long)vendor,
                          (long long)product,
                          (long long)serial) > 0;
        }
    }

    CFRelease(attrs_value);
    return ok;
}

static void print_hardware_external_keys(void) {
    io_service_t *services = NULL;
    int count = 0;
    int rc = collect_iomfb_services(&services, &count);
    if (rc != 0) {
        printf(" external_keys=unknown");
        return;
    }

    bool printed = false;
    printf(" external_keys=");
    for (int i = 0; i < count; i++) {
        char key[128] = {0};
        if (!external_iomfb_display_key(services[i], key, sizeof(key))) {
            continue;
        }
        if (printed) {
            printf(",");
        }
        printf("%s", key);
        printed = true;
    }

    if (!printed) {
        printf("none");
    }
    release_iomfb_services(services, count);
}

static void scan_crossbar_events_for_class(const char *class_name,
                                           int64_t *last_unplug_event,
                                           int64_t *last_plug_event) {
    CFMutableDictionaryRef match = IOServiceMatching(class_name);
    if (!match) {
        return;
    }

    io_iterator_t iter = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter);
    if (kr != KERN_SUCCESS) {
        return;
    }

    io_service_t service;
    while ((service = IOIteratorNext(iter))) {
        CFTypeRef event_log = copy_prop(service, "EventLog");
        if (event_log && CFGetTypeID(event_log) == CFArrayGetTypeID()) {
            CFArrayRef events = (CFArrayRef)event_log;
            CFIndex count = CFArrayGetCount(events);
            for (CFIndex i = 0; i < count; i++) {
                CFTypeRef entry_value = CFArrayGetValueAtIndex(events, i);
                if (!entry_value || CFGetTypeID(entry_value) != CFDictionaryGetTypeID()) {
                    continue;
                }

                CFDictionaryRef entry = (CFDictionaryRef)entry_value;
                int64_t event_time = -1;
                if (!dict_get_i64(entry, "EventTime", &event_time)) {
                    continue;
                }

                CFTypeRef payload_value = CFDictionaryGetValue(entry, CFSTR("EventPayload"));
                if (!payload_value || CFGetTypeID(payload_value) != CFDictionaryGetTypeID()) {
                    continue;
                }

                char action[64] = {0};
                if (!dict_get_string((CFDictionaryRef)payload_value, "Action", action, sizeof(action))) {
                    continue;
                }

                if (strcmp(action, "Unplug") == 0 && event_time > *last_unplug_event) {
                    *last_unplug_event = event_time;
                } else if (strcmp(action, "Plug") == 0 && event_time > *last_plug_event) {
                    *last_plug_event = event_time;
                }
            }
        }
        if (event_log) {
            CFRelease(event_log);
        }
        IOObjectRelease(service);
    }

    IOObjectRelease(iter);
}

static void latest_crossbar_events(int64_t *last_unplug_event, int64_t *last_plug_event) {
    *last_unplug_event = -1;
    *last_plug_event = -1;

    const char *classes[] = {
        "AppleATCDPAltModePort",
        "AppleDCPDPTXRemotePortUFP",
        "AppleDisplayCrossbar",
        "AppleT8132DisplayCrossbar",
        "AppleT603XDisplayCrossbar",
        "AppleT8112DisplayCrossbar",
        "AppleT8122DisplayCrossbar",
        "AppleT8140DisplayCrossbar"
    };

    for (size_t i = 0; i < sizeof(classes) / sizeof(classes[0]); i++) {
        scan_crossbar_events_for_class(classes[i], last_unplug_event, last_plug_event);
    }
}

static void print_event_time(const char *name, int64_t value) {
    printf(" %s=", name);
    if (value >= 0) {
        printf("%lld", (long long)value);
    } else {
        printf("none");
    }
}

static CGDirectDisplayID find_builtin_display(SkyLightAPI *sky) {
    CGDirectDisplayID *displays = NULL;
    uint32_t count = 0;
    if (collect_sls_displays(sky, &displays, &count) != 0) {
        return 0;
    }

    CGDirectDisplayID found = 0;
    for (uint32_t i = 0; i < count; i++) {
        if (CGDisplayIsBuiltin(displays[i])) {
            found = displays[i];
            break;
        }
    }

    free(displays);
    if (found) {
        return found;
    }

    IOMFBAPI iomfb;
    if (!load_iomfb(&iomfb) || !iomfb.get_id) {
        return 0;
    }

    io_service_t *services = NULL;
    int service_count = 0;
    int rc = collect_iomfb_services(&services, &service_count);
    if (rc != 0) {
        return 0;
    }

    int index = find_builtin_iomfb_index(services, service_count);
    if (index < 0) {
        release_iomfb_services(services, service_count);
        return 0;
    }

    IOMobileFramebufferRef fb = NULL;
    kern_return_t kr = iomfb.open(services[index], mach_task_self(), 0, &fb);
    if (kr != KERN_SUCCESS || !fb) {
        release_iomfb_services(services, service_count);
        return 0;
    }

    uint32_t fb_id = 0;
    kr = iomfb.get_id(fb, &fb_id);
    release_iomfb_services(services, service_count);
    if (kr != KERN_SUCCESS || fb_id == 0) {
        return 0;
    }

    fprintf(stderr, "built-in display recovered from IOMobileFramebuffer id=%u\n", fb_id);
    return fb_id;
}

static CGError clear_mirroring_once(SkyLightAPI *sky, CGConfigureOption option) {
    CGDirectDisplayID *displays = NULL;
    uint32_t count = 0;
    int rc = collect_sls_displays(sky, &displays, &count);
    if (rc != 0) {
        return kCGErrorFailure;
    }

    bool has_mirror = false;
    for (uint32_t i = 0; i < count; i++) {
        if (display_has_mirror_state(displays[i])) {
            has_mirror = true;
            break;
        }
    }
    if (!has_mirror) {
        free(displays);
        printf("mirror: no mirror set detected\n");
        return kCGErrorSuccess;
    }

    CGDisplayConfigRef config = NULL;
    CGError err = CGBeginDisplayConfiguration(&config);
    if (err != kCGErrorSuccess || !config) {
        free(displays);
        fprintf(stderr, "CGBeginDisplayConfiguration failed for mirror clear %s: %d\n",
                commit_name(option),
                err);
        return err;
    }

    bool changed = false;
    for (uint32_t i = 0; i < count; i++) {
        CGDirectDisplayID display = displays[i];
        if (CGDisplayMirrorsDisplay(display) == kCGNullDirectDisplay &&
            !CGDisplayIsBuiltin(display)) {
            continue;
        }

        err = CGConfigureDisplayMirrorOfDisplay(config, display, kCGNullDirectDisplay);
        if (err != kCGErrorSuccess) {
            CGCancelDisplayConfiguration(config);
            free(displays);
            fprintf(stderr,
                    "CGConfigureDisplayMirrorOfDisplay(%u,null) failed before %s commit: %d\n",
                    display,
                    commit_name(option),
                    err);
            return err;
        }
        changed = true;
    }

    if (!changed) {
        CGCancelDisplayConfiguration(config);
        free(displays);
        printf("mirror: no configurable mirror target detected\n");
        return kCGErrorSuccess;
    }

    err = CGCompleteDisplayConfiguration(config, option);
    free(displays);
    if (err != kCGErrorSuccess) {
        fprintf(stderr, "CGCompleteDisplayConfiguration(mirror clear,%s) failed: %d\n",
                commit_name(option),
                err);
        return err;
    }

    printf("mirror: cleared using %s commit\n", commit_name(option));
    return kCGErrorSuccess;
}

static int clear_mirroring(SkyLightAPI *sky, CommitPreference preference) {
    CGConfigureOption options[3] = {0};
    int option_count = commit_options_for_preference(preference, options, 3);

    for (int i = 0; i < option_count; i++) {
        CGError err = clear_mirroring_once(sky, options[i]);
        if (err == kCGErrorSuccess) {
            return 0;
        }
        usleep(200000);
    }

    return 1;
}

static int parse_commit_preference(int argc, char **argv, CommitPreference *preference) {
    *preference = COMMIT_AUTO;
    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "--commit") != 0) {
            fprintf(stderr, "unknown option: %s\n", argv[i]);
            return 2;
        }
        if (i + 1 >= argc) {
            fprintf(stderr, "--commit requires session, permanent, app-only, or auto\n");
            return 2;
        }
        const char *value = argv[++i];
        if (strcmp(value, "auto") == 0) {
            *preference = COMMIT_AUTO;
        } else if (strcmp(value, "session") == 0) {
            *preference = COMMIT_SESSION;
        } else if (strcmp(value, "permanent") == 0) {
            *preference = COMMIT_PERMANENT;
        } else if (strcmp(value, "app-only") == 0) {
            *preference = COMMIT_APP_ONLY;
        } else {
            fprintf(stderr, "invalid --commit value: %s\n", value);
            return 2;
        }
    }
    return 0;
}

static int commit_options_for_preference(CommitPreference preference,
                                         CGConfigureOption *options,
                                         size_t max_options) {
    if (max_options < 3) {
        return 0;
    }

    switch (preference) {
        case COMMIT_SESSION:
            options[0] = kCGConfigureForSession;
            return 1;
        case COMMIT_PERMANENT:
            options[0] = kCGConfigurePermanently;
            return 1;
        case COMMIT_APP_ONLY:
            options[0] = kCGConfigureForAppOnly;
            return 1;
        case COMMIT_AUTO:
        default:
            options[0] = kCGConfigureForSession;
            options[1] = kCGConfigurePermanently;
            options[2] = kCGConfigureForAppOnly;
            return 3;
    }
}

static CGError configure_enabled_once(SkyLightAPI *sky,
                                      CGDirectDisplayID display,
                                      bool enabled,
                                      CGConfigureOption option) {
    CGDisplayConfigRef config = NULL;
    CGError err = CGBeginDisplayConfiguration(&config);
    if (err != kCGErrorSuccess || !config) {
        fprintf(stderr, "CGBeginDisplayConfiguration failed for %s: %d\n",
                commit_name(option),
                err);
        return err;
    }

    err = sky->configure_display_enabled(config, display, enabled);
    if (err != kCGErrorSuccess) {
        CGCancelDisplayConfiguration(config);
        fprintf(stderr,
                "SLSConfigureDisplayEnabled(%u,%s) failed before %s commit: %d\n",
                display,
                enabled ? "true" : "false",
                commit_name(option),
                err);
        return err;
    }

    err = CGCompleteDisplayConfiguration(config, option);
    if (err != kCGErrorSuccess) {
        fprintf(stderr, "CGCompleteDisplayConfiguration(%s) failed: %d\n",
                commit_name(option),
                err);
        return err;
    }

    return kCGErrorSuccess;
}

static int set_layout_enabled(SkyLightAPI *sky,
                              CGDirectDisplayID display,
                              bool enabled,
                              CommitPreference preference) {
    CGConfigureOption options[3] = {0};
    int option_count = commit_options_for_preference(preference, options, 3);

    for (int i = 0; i < option_count; i++) {
        CGError err = configure_enabled_once(sky, display, enabled, options[i]);
        if (err == kCGErrorSuccess) {
            printf("layout: built-in display %s using %s commit\n",
                   enabled ? "connected" : "disconnected",
                   commit_name(options[i]));
            return 0;
        }
        usleep(200000);
    }

    return 1;
}

static int request_builtin_panel_power(uint32_t value) {
    IOMFBAPI iomfb;
    if (!load_iomfb(&iomfb)) {
        return 2;
    }

    io_service_t *services = NULL;
    int count = 0;
    int rc = collect_iomfb_services(&services, &count);
    if (rc != 0) {
        return rc;
    }

    int index = find_builtin_iomfb_index(services, count);
    if (index < 0) {
        release_iomfb_services(services, count);
        fprintf(stderr, "built-in IOMobileFramebuffer service was not found\n");
        return 2;
    }

    IOMobileFramebufferRef fb = NULL;
    kern_return_t kr = iomfb.open(services[index], mach_task_self(), 0, &fb);
    if (kr != KERN_SUCCESS || !fb) {
        release_iomfb_services(services, count);
        fprintf(stderr, "IOMobileFramebufferOpen failed: 0x%x\n", kr);
        return 1;
    }

    kr = iomfb.request_power_change(fb, value);
    printf("panel: IOMobileFramebufferRequestPowerChange(%u) -> 0x%x\n", value, kr);

    release_iomfb_services(services, count);
    return kr == KERN_SUCCESS ? 0 : 1;
}

static void print_display_mode(CGDirectDisplayID display) {
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(display);
    if (!mode) {
        printf("mode=none");
        return;
    }
    printf("mode=%zux%zu@%.2f",
           CGDisplayModeGetWidth(mode),
           CGDisplayModeGetHeight(mode),
           CGDisplayModeGetRefreshRate(mode));
    CGDisplayModeRelease(mode);
}

static int command_status(void) {
    SkyLightAPI sky;
    if (!load_skylight(&sky)) {
        return 2;
    }

    CGDirectDisplayID *displays = NULL;
    uint32_t count = 0;
    int rc = collect_sls_displays(&sky, &displays, &count);
    if (rc != 0) {
        return rc;
    }

    printf("CoreGraphics/SkyLight displays:\n");
    for (uint32_t i = 0; i < count; i++) {
        CGDirectDisplayID display = displays[i];
        CGRect bounds = CGDisplayBounds(display);
        CGDirectDisplayID mirror_of = CGDisplayMirrorsDisplay(display);
        printf("  id=%u builtin=%s active=%s online=%s asleep=%s main=%s mirror_of=%u bounds=(%.0f %.0f %.0f %.0f) pixels=%zux%zu ",
               display,
               yes_no(CGDisplayIsBuiltin(display) != 0),
               yes_no(is_active_display(display)),
               yes_no(CGDisplayIsOnline(display) != 0),
               yes_no(CGDisplayIsAsleep(display) != 0),
               yes_no(display == CGMainDisplayID()),
               mirror_of,
               bounds.origin.x,
               bounds.origin.y,
               bounds.size.width,
               bounds.size.height,
               CGDisplayPixelsWide(display),
               CGDisplayPixelsHigh(display));
        print_display_mode(display);
        printf("\n");
    }

    int physical = physical_external_count();
    CGDirectDisplayID builtin = find_builtin_display(&sky);
    if (builtin) {
        printf("summary: built-in layout=%s online=%s mirror=%s active_external_count=%d physical_external_count=",
               is_active_display(builtin) ? "connected" : "disconnected",
               yes_no(CGDisplayIsOnline(builtin) != 0),
               yes_no(any_display_has_mirror_state(&sky)),
               active_external_count());
        if (physical >= 0) {
            printf("%d\n", physical);
        } else {
            printf("unknown\n");
        }
    } else {
        printf("summary: built-in display not found by CoreGraphics\n");
    }

    printf("hardware: physical_external_count=");
    if (physical >= 0) {
        printf("%d", physical);
    } else {
        printf("unknown");
    }
    print_hardware_external_keys();
    int64_t last_unplug_event = -1;
    int64_t last_plug_event = -1;
    latest_crossbar_events(&last_unplug_event, &last_plug_event);
    print_event_time("last_unplug_event", last_unplug_event);
    print_event_time("last_plug_event", last_plug_event);
    printf("\n");

    free(displays);

    IOMFBAPI iomfb;
    if (!load_iomfb(&iomfb)) {
        return 2;
    }

    io_service_t *services = NULL;
    int service_count = 0;
    rc = collect_iomfb_services(&services, &service_count);
    if (rc != 0) {
        return rc;
    }

    int index = find_builtin_iomfb_index(services, service_count);
    if (index < 0) {
        printf("framebuffer: built-in service not found\n");
    } else {
        char name_matched[256] = {0};
        get_io_name_matched(services[index], name_matched, sizeof(name_matched));
        printf("framebuffer: built-in index=%d io_name_matched=%s", index, name_matched[0] ? name_matched : "unknown");
        print_iomfb_power_props(services[index]);

        IOMobileFramebufferRef fb = NULL;
        kern_return_t kr = iomfb.open(services[index], mach_task_self(), 0, &fb);
        printf(" open=0x%x", kr);
        if (kr == KERN_SUCCESS && fb) {
            if (iomfb.get_id) {
                uint32_t fb_id = 0;
                kern_return_t id_kr = iomfb.get_id(fb, &fb_id);
                printf(" get_id=0x%x fb_id=%u", id_kr, fb_id);
            }
            if (iomfb.get_display_size) {
                IOMobileFramebufferDisplaySize size = {0};
                kern_return_t size_kr = iomfb.get_display_size(fb, &size);
                printf(" get_size=0x%x fb_size=%.0fx%.0f", size_kr, size.width, size.height);
            }
        }
        printf("\n");
    }

    release_iomfb_services(services, service_count);
    return 0;
}

static int command_layout(bool enabled, CommitPreference preference) {
    SkyLightAPI sky;
    if (!load_skylight(&sky)) {
        return 2;
    }

    CGDirectDisplayID builtin = find_builtin_display(&sky);
    if (!builtin) {
        fprintf(stderr, "built-in display was not found\n");
        return 2;
    }

    if (!enabled && active_external_count() == 0) {
        fprintf(stderr, "refusing to disconnect layout: no active external display\n");
        return 2;
    }

    bool active = is_active_display(builtin);
    if (enabled && active) {
        printf("layout: built-in display already connected\n");
        return 0;
    }
    if (!enabled && !active) {
        printf("layout: built-in display already disconnected\n");
        return 0;
    }

    return set_layout_enabled(&sky, builtin, enabled, preference);
}

static int command_off(CommitPreference preference) {
    SkyLightAPI sky;
    if (!load_skylight(&sky)) {
        return 2;
    }

    int mirror_rc = clear_mirroring(&sky, preference);
    if (mirror_rc != 0) {
        return mirror_rc;
    }
    usleep(1200000);

    int layout_rc = command_layout(false, preference);
    if (layout_rc != 0) {
        return layout_rc;
    }

    int panel_rc = request_builtin_panel_power(0);
    usleep(700000);
    return panel_rc;
}

static int command_on(CommitPreference preference) {
    int panel_rc = request_builtin_panel_power(1);
    usleep(700000);

    int layout_rc = command_layout(true, preference);
    if (layout_rc != 0) {
        fprintf(stderr,
                "layout reconnect failed; panel wake was still requested. "
                "Use macOS Display Settings, a lid close/open cycle, or cable reconnect if the layout stays disconnected.\n");
        return layout_rc;
    }

    return panel_rc;
}

static void usage(const char *argv0) {
    fprintf(stderr,
            "usage:\n"
            "  %s status\n"
            "  %s off [--commit auto|session|permanent|app-only]\n"
            "  %s on [--commit auto|session|permanent|app-only]\n"
            "  %s layout-off [--commit auto|session|permanent|app-only]\n"
            "  %s layout-on [--commit auto|session|permanent|app-only]\n"
            "  %s panel-off\n"
            "  %s panel-on\n"
            "  %s panel-request <value>\n",
            argv0, argv0, argv0, argv0, argv0, argv0, argv0, argv0);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        usage(argv[0]);
        return 2;
    }

    if (strcmp(argv[1], "status") == 0) {
        return command_status();
    }

    if (strcmp(argv[1], "panel-off") == 0) {
        return request_builtin_panel_power(0);
    }

    if (strcmp(argv[1], "panel-on") == 0) {
        return request_builtin_panel_power(1);
    }

    if (strcmp(argv[1], "panel-request") == 0) {
        if (argc != 3) {
            usage(argv[0]);
            return 2;
        }
        uint32_t value = (uint32_t)strtoul(argv[2], NULL, 0);
        return request_builtin_panel_power(value);
    }

    CommitPreference preference = COMMIT_AUTO;
    int parse_rc = parse_commit_preference(argc, argv, &preference);
    if (parse_rc != 0) {
        return parse_rc;
    }

    if (strcmp(argv[1], "off") == 0) {
        return command_off(preference);
    }

    if (strcmp(argv[1], "on") == 0) {
        return command_on(preference);
    }

    if (strcmp(argv[1], "layout-off") == 0) {
        return command_layout(false, preference);
    }

    if (strcmp(argv[1], "layout-on") == 0) {
        return command_layout(true, preference);
    }

    usage(argv[0]);
    return 2;
}
